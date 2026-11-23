// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include <updatechecker.h>
#include <settings.h>

#include <QCoreApplication>
#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QUrl>

namespace
{
const char *const DEFAULT_FEED = "https://api.github.com/repos/kutsalkiremitci/robz-play/releases/latest";
#ifdef Q_OS_MACOS
const char *const INSTALLER_NAME = "RobzPlay.dmg";
#else
const char *const INSTALLER_NAME = "RobzPlay-Setup.exe";
#endif
const int FIRST_CHECK_MS = 5 * 1000;
const int CHECK_INTERVAL_MS = 3 * 60 * 60 * 1000;

QList<int> versionParts(const QString &version)
{
	QList<int> parts;
	static const QRegularExpression number(QStringLiteral("\\d+"));
	auto it = number.globalMatch(version);
	while(it.hasNext() && parts.size() < 3)
		parts.append(it.next().captured(0).toInt());
	while(parts.size() < 3)
		parts.append(0);
	return parts;
}
}

UpdateChecker::UpdateChecker(Settings *settings, QObject *parent)
	: QObject(parent)
	, settings(settings)
	, network(new QNetworkAccessManager(this))
	, current_version(qEnvironmentVariableIsEmpty("ROBZPLAY_VERSION_OVERRIDE")
		? QStringLiteral(ROBZPLAY_VERSION) : qEnvironmentVariable("ROBZPLAY_VERSION_OVERRIDE"))
	, feed_url(qEnvironmentVariableIsEmpty("ROBZPLAY_UPDATE_URL")
		? QString::fromLatin1(DEFAULT_FEED) : qEnvironmentVariable("ROBZPLAY_UPDATE_URL"))
{
	periodic.setInterval(CHECK_INTERVAL_MS);
	connect(&periodic, &QTimer::timeout, this, &UpdateChecker::check);
	if(autoCheck())
	{
		QTimer::singleShot(FIRST_CHECK_MS, this, &UpdateChecker::check);
		periodic.start();
	}
}

int UpdateChecker::compareVersions(const QString &a, const QString &b)
{
	const QList<int> x = versionParts(a), y = versionParts(b);
	for(int i = 0; i < 3; i++)
		if(x[i] != y[i])
			return x[i] < y[i] ? -1 : 1;
	return 0;
}

QString UpdateChecker::notesFor(const QString &body, const QString &language)
{
	static const QRegularExpression marker(QStringLiteral("<!--\\s*robzplay:(\\w+)\\s*-->"));
	QString text = body;
	bool marked = false;
	for(const QString &wanted : { language, QStringLiteral("tr"), QStringLiteral("en") })
	{
		auto it = marker.globalMatch(body);
		while(it.hasNext())
		{
			const auto match = it.next();
			if(match.captured(1) != wanted)
				continue;
			const auto next = marker.match(body, match.capturedEnd());
			text = body.mid(match.capturedEnd(), next.hasMatch() ? next.capturedStart() - match.capturedEnd() : -1);
			marked = true;
			break;
		}
		if(marked)
			break;
	}
	// collapsible blocks GitHub draws but plain Markdown does not know
	static const QRegularExpression html(QStringLiteral("</?details>|<summary>.*?</summary>"));
	text.remove(html);
	return text.trimmed();
}

bool UpdateChecker::available() const
{
	return !latest_version.isEmpty()
		&& compareVersions(latest_version, current_version) > 0
		&& compareVersions(latest_version, settings->GetUpdateSkipVersion()) != 0;
}

QString UpdateChecker::notes() const
{
	return notesFor(body, settings->GetLanguage());
}

bool UpdateChecker::autoCheck() const
{
	return settings->GetUpdateCheck();
}

void UpdateChecker::setAutoCheck(bool enabled)
{
	if(enabled == autoCheck())
		return;
	settings->SetUpdateCheck(enabled);
	if(enabled)
	{
		periodic.start();
		check();
	}
	else
		periodic.stop();
	emit autoCheckChanged();
}

void UpdateChecker::setState(const QString &state, const QString &error)
{
	state_name = state;
	error_text = error;
	emit changed();
}

void UpdateChecker::check()
{
	if(check_reply || download_reply)
		return;
	QNetworkRequest request{QUrl(feed_url)};
	request.setHeader(QNetworkRequest::UserAgentHeader, QStringLiteral("RobzPlay/%1").arg(QStringLiteral(ROBZPLAY_VERSION)));
	request.setRawHeader("Accept", "application/vnd.github+json");
	request.setTransferTimeout(20000);
	check_reply = network->get(request);
	connect(check_reply, &QNetworkReply::finished, this, &UpdateChecker::checkFinished);
	if(state_name == QLatin1String("idle") || state_name == QLatin1String("error"))
		setState(QStringLiteral("checking"));
}

void UpdateChecker::checkNow()
{
	if(download_reply)
		return;
	manual_check = true;
	if(!check_reply)
		check();
	else
		setState(QStringLiteral("checking"));
}

void UpdateChecker::checkFinished()
{
	QNetworkReply *reply = check_reply;
	check_reply = nullptr;
	if(!reply)
		return;
	reply->deleteLater();
	const bool was_available = available();
	const QString previous_version = latest_version;
	if(reply->error() != QNetworkReply::NoError)
	{
		// offline, or GitHub's limit for anonymous requests: try again at the next check
		qWarning("Robz Play update check failed: %s", qPrintable(reply->errorString()));
		setState(QStringLiteral("idle"));
		if(manual_check)
		{
			manual_check = false;
			emit manualResult(QStringLiteral("failed"));
		}
		return;
	}
	const QJsonObject release = QJsonDocument::fromJson(reply->readAll()).object();
	const QString tag = release.value(QStringLiteral("tag_name")).toString();
	if(tag.isEmpty())
	{
		setState(QStringLiteral("idle"));
		if(manual_check)
		{
			manual_check = false;
			emit manualResult(QStringLiteral("failed"));
		}
		return;
	}
	latest_version = tag.startsWith(QLatin1Char('v')) ? tag.mid(1) : tag;
	release_url = release.value(QStringLiteral("html_url")).toString();
	body = release.value(QStringLiteral("body")).toString();
	asset_url.clear();
	asset_digest.clear();
	size = 0;
	for(const QJsonValue &value : release.value(QStringLiteral("assets")).toArray())
	{
		const QJsonObject asset = value.toObject();
		if(asset.value(QStringLiteral("name")).toString() != QLatin1String(INSTALLER_NAME))
			continue;
		asset_url = asset.value(QStringLiteral("browser_download_url")).toString();
		asset_digest = asset.value(QStringLiteral("digest")).toString();
		size = static_cast<qint64>(asset.value(QStringLiteral("size")).toDouble());
	}
	qInfo("Robz Play update check: this build %s, latest release %s%s", qPrintable(current_version), qPrintable(latest_version),
		available() ? " - offered" : "");
	if(manual_check)
	{
		// asked for by the user: a newer version is shown even if it was skipped before
		manual_check = false;
		const bool newer = compareVersions(latest_version, current_version) > 0;
		if(newer && compareVersions(latest_version, settings->GetUpdateSkipVersion()) == 0)
			settings->SetUpdateSkipVersion(QString());
		setState(QStringLiteral("idle"));
		emit manualResult(newer ? QStringLiteral("available") : QStringLiteral("uptodate"));
		return;
	}
	setState(QStringLiteral("idle"));
	if(available() && (!was_available || latest_version != previous_version))
		emit offered();
}

void UpdateChecker::install()
{
	if(download_reply || !available())
		return;
	if(asset_url.isEmpty())
	{
		setState(QStringLiteral("error"), tr("This release has no installer to download. Open the release page to get it."));
		return;
	}
	const QString dir = QDir(QStandardPaths::writableLocation(QStandardPaths::TempLocation)).filePath(QStringLiteral("RobzPlay-Update"));
	QDir().mkpath(dir);
	download_file.setFileName(QDir(dir).filePath(QStringLiteral("RobzPlay-Setup-%1.exe").arg(latest_version)));
	if(!download_file.open(QIODevice::WriteOnly | QIODevice::Truncate))
	{
		setState(QStringLiteral("error"), tr("The update cannot be saved: %1").arg(download_file.errorString()));
		return;
	}
	download_hash.reset();
	received = 0;
	QNetworkRequest request{QUrl(asset_url)};
	request.setHeader(QNetworkRequest::UserAgentHeader, QStringLiteral("RobzPlay/%1").arg(QStringLiteral(ROBZPLAY_VERSION)));
	request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
	request.setTransferTimeout(60000);
	download_reply = network->get(request);
	connect(download_reply, &QNetworkReply::readyRead, this, [this]() {
		if(!download_reply)
			return;
		const QByteArray chunk = download_reply->readAll();
		download_file.write(chunk);
		download_hash.addData(chunk);
		received += chunk.size();
		emit progressChanged();
	});
	connect(download_reply, &QNetworkReply::downloadProgress, this, [this](qint64, qint64 total) {
		if(total > 0 && total != size)
		{
			size = total;
			emit changed();
		}
	});
	connect(download_reply, &QNetworkReply::finished, this, &UpdateChecker::downloadFinished);
	emit progressChanged();
	setState(QStringLiteral("downloading"));
}

void UpdateChecker::downloadFinished()
{
	QNetworkReply *reply = download_reply;
	download_reply = nullptr;
	if(!reply)
		return;
	reply->deleteLater();
	if(reply->bytesAvailable() > 0)
	{
		const QByteArray rest = reply->readAll();
		download_file.write(rest);
		download_hash.addData(rest);
		received += rest.size();
	}
	download_file.close();
	if(reply->error() != QNetworkReply::NoError)
	{
		const bool cancelled = reply->error() == QNetworkReply::OperationCanceledError;
		download_file.remove();
		if(cancelled)
			setState(QStringLiteral("idle"));
		else
			setState(QStringLiteral("error"), tr("The download failed: %1").arg(reply->errorString()));
		return;
	}

	// the file must be exactly the one GitHub lists, or it is not run
	const QString expected = asset_digest.startsWith(QLatin1String("sha256:")) ? asset_digest.mid(7).toLower() : QString();
	const QString actual = QString::fromLatin1(download_hash.result().toHex());
	if((!expected.isEmpty() && expected != actual) || (expected.isEmpty() && size > 0 && received != size))
	{
		download_file.remove();
		setState(QStringLiteral("error"), tr("The downloaded file is damaged. Please try again."));
		return;
	}
	qInfo("Robz Play update: %s downloaded (%lld bytes, sha256 %s), starting it", qPrintable(download_file.fileName()), received, qPrintable(actual));

	if(!QProcess::startDetached(download_file.fileName(), { QStringLiteral("/UPDATE") }))
	{
		setState(QStringLiteral("error"), tr("The installer could not be started. It is saved at %1").arg(QDir::toNativeSeparators(download_file.fileName())));
		return;
	}
	setState(QStringLiteral("starting"));
	// the installer waits until this copy has closed, then replaces it and starts the new one
	QTimer::singleShot(400, qApp, &QCoreApplication::quit);
}

void UpdateChecker::cancel()
{
	if(download_reply)
		download_reply->abort();
}

void UpdateChecker::skip()
{
	if(latest_version.isEmpty())
		return;
	settings->SetUpdateSkipVersion(latest_version);
	emit changed();
}
