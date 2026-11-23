// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include <sessionlog.h>
#include <chiaki/log.h>

#include <QStandardPaths>
#include <QDir>
#include <QRegularExpression>
#include <QDateTime>
#include <QFile>
#include <QPair>
#include <QVector>
#include <QThread>

#include <chrono>
#include <utility>

#ifdef __APPLE__
#include <pthread/qos.h>
#endif

static void LogCb(ChiakiLogLevel level, const char *msg, void *user);
static QString SanitizeLogMessage(const QString &msg);

static int64_t CurrentWallTimeUs()
{
	return std::chrono::duration_cast<std::chrono::microseconds>(
		std::chrono::system_clock::now().time_since_epoch()).count();
}

static QByteArray FormatLogLine(int64_t timestamp_us, ChiakiLogLevel level, const QString &sanitized_msg)
{
	const qint64 secs_ms = static_cast<qint64>(timestamp_us / 1000);
	const int rem_us = static_cast<int>(timestamp_us >= 0 ? (timestamp_us % 1000) : 0);
	const QString ts = QDateTime::fromMSecsSinceEpoch(secs_ms).toString(QStringLiteral("yyyy-MM-dd HH:mm:ss:zzz"))
		+ QStringLiteral("%1").arg(rem_us, 3, 10, QLatin1Char('0'));
	const QString line = QStringLiteral("[%1] [%2] %3\n").arg(ts, QString(chiaki_log_level_char(level)), sanitized_msg);
	return line.toLocal8Bit();
}

SessionLog::SessionLog(StreamSession *session, uint32_t level_mask, const QString &filename, bool sanitize)
	: session(session), file(nullptr), shutdown(false), sanitize(sanitize)
{
	QString open_err;
	bool logging_disabled = filename.isEmpty();
	if(!logging_disabled)
	{
		file = new QFile(filename);
		if(!file->open(QIODevice::ReadWrite))
		{
			delete file;
			file = nullptr;
			open_err = filename;
		}
	}

	writer_thread = std::thread(&SessionLog::WriterLoop, this);
	chiaki_log_init(&log, level_mask, LogCb, this);

	if(logging_disabled)
		CHIAKI_LOGI(&log, "Logging to file disabled");
	else if(!open_err.isEmpty())
		CHIAKI_LOGI(&log, "Failed to open file %s for logging", open_err.toLocal8Bit().constData());
	else
		CHIAKI_LOGI(&log, "Logging to file %s", filename.toLocal8Bit().constData());

	CHIAKI_LOGI(&log, "Robz Play Version " ROBZPLAY_VERSION " (chiaki-ng " CHIAKI_VERSION ")");
}

SessionLog::~SessionLog()
{
	PrepareShutdown();
}

void SessionLog::PrepareShutdown()
{
	// Signal that we're shutting down - no more logging allowed
	shutdown.storeRelease(true);

	{
		std::lock_guard<std::mutex> lock(queue_mutex);
		stop_writer = true;
	}
	queue_cv.notify_all();

	if(writer_thread.joinable())
		writer_thread.join();

	// Now safe to clean up
	QMutexLocker lock(&file_mutex);
	if(file)
	{
		file->flush();
		delete file;
		file = nullptr;
	}
}

void SessionLog::Log(ChiakiLogLevel level, const char *msg)
{
	if(shutdown.loadAcquire())
	{
		QString sanitized_msg = sanitize ? SanitizeLogMessage(QString::fromUtf8(msg)) : QString::fromUtf8(msg);
		QByteArray sanitized_utf8 = sanitized_msg.toUtf8();
		chiaki_log_cb_print(level, sanitized_utf8.constData(), nullptr);
		return;
	}

	const int64_t ts_us = CurrentWallTimeUs();
	bool should_notify = false;
	{
		std::lock_guard<std::mutex> lock(queue_mutex);
		if(stop_writer)
		{
			// Writer is stopping; print directly without enqueueing
			QString sanitized_msg = sanitize ? SanitizeLogMessage(QString::fromUtf8(msg)) : QString::fromUtf8(msg);
			QByteArray sanitized_utf8 = sanitized_msg.toUtf8();
			chiaki_log_cb_print(level, sanitized_utf8.constData(), nullptr);
			return;
		}

		constexpr size_t MAX_QUEUE_ENTRIES = 4096;
		constexpr size_t MAX_HIGH_PRIO_ENTRIES = 4608;
		const bool low_prio = (level == CHIAKI_LOG_VERBOSE || level == CHIAKI_LOG_DEBUG);
		if(low_prio && queue.size() >= MAX_QUEUE_ENTRIES)
		{
			dropped_low_priority++;
			return;
		}
		if(queue.size() >= MAX_HIGH_PRIO_ENTRIES)
		{
			bool dropped = false;
			for(auto it = queue.begin(); it != queue.end(); ++it)
			{
				if(it->level == CHIAKI_LOG_VERBOSE || it->level == CHIAKI_LOG_DEBUG)
				{
					queue.erase(it);
					dropped_low_priority++;
					dropped = true;
					break;
				}
			}
			if(!dropped)
			{
				dropped_low_priority++;
				return;
			}
		}

		const bool was_empty = queue.empty();
		queue.push_back(Entry{level, ts_us, msg ? std::string(msg) : std::string()});
		should_notify = was_empty || (level & (CHIAKI_LOG_WARNING | CHIAKI_LOG_ERROR)) != 0;
	}
	if(should_notify)
		queue_cv.notify_one();
}

void SessionLog::WriterLoop()
{
#ifdef __APPLE__
	pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
#endif
	auto last_flush = std::chrono::steady_clock::now();
	bool unflushed = false;

	for(;;)
	{
		std::deque<Entry> batch;
		size_t dropped = 0;
		bool stopping = false;

		{
			std::unique_lock<std::mutex> lock(queue_mutex);
			if(queue.empty() && !stop_writer)
			{
				if(unflushed)
					queue_cv.wait_for(lock, std::chrono::milliseconds(250), [this]() { return !queue.empty() || stop_writer; });
				else
					queue_cv.wait(lock, [this]() { return !queue.empty() || stop_writer; });
			}
			if(!queue.empty())
				batch.swap(queue);
			dropped = dropped_low_priority;
			dropped_low_priority = 0;
			stopping = stop_writer && queue.empty();
		}

		if(dropped > 0)
		{
			batch.push_back(Entry{
				CHIAKI_LOG_WARNING,
				CurrentWallTimeUs(),
				std::string("Dropped ") + std::to_string(dropped) + " verbose/debug log lines under backpressure"
			});
		}

		if(!batch.empty())
		{
			QByteArray write_buf;
			write_buf.reserve(static_cast<qsizetype>(batch.size() * 128));
			bool urgent = false;

			for(const Entry &entry : batch)
			{
				QString decoded = QString::fromUtf8(entry.msg.data(), static_cast<qsizetype>(entry.msg.size()));
				QString sanitized_msg = sanitize ? SanitizeLogMessage(decoded) : decoded;
				QByteArray sanitized_utf8 = sanitized_msg.toUtf8();
				chiaki_log_cb_print(entry.level, sanitized_utf8.constData(), nullptr);
				if((entry.level & (CHIAKI_LOG_WARNING | CHIAKI_LOG_ERROR)) != 0)
					urgent = true;
				if(file)
					write_buf.append(FormatLogLine(entry.timestamp_us, entry.level, sanitized_msg));
			}

			if(file && !write_buf.isEmpty())
			{
				QMutexLocker lock(&file_mutex);
				if(file)
				{
					file->write(write_buf);
					unflushed = true;
					const auto now = std::chrono::steady_clock::now();
					if(urgent || stopping || now - last_flush >= std::chrono::milliseconds(250))
					{
						file->flush();
						last_flush = now;
						unflushed = false;
					}
				}
			}
		}
		else if(unflushed)
		{
			const auto now = std::chrono::steady_clock::now();
			if(stopping || now - last_flush >= std::chrono::milliseconds(250))
			{
				QMutexLocker lock(&file_mutex);
				if(file)
					file->flush();
				last_flush = now;
				unflushed = false;
			}
		}

		if(stopping)
			break;
	}
}

class SessionLogPrivate
{
	public:
		static void Log(SessionLog *log, ChiakiLogLevel level, const char *msg) { log->Log(level, msg); }
};

static void LogCb(ChiakiLogLevel level, const char *msg, void *user)
{
	auto log = reinterpret_cast<SessionLog *>(user);
	SessionLogPrivate::Log(log, level, msg);
}

// Heap-allocated regexes that intentionally outlive static destruction,
// preventing use-after-free when background threads (e.g. takion) log
// while the process is shutting down.
static const QRegularExpression &sanitize_ipv4_re()
{
	static const auto *re = new QRegularExpression(
		R"(\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b)");
	return *re;
}
static const QRegularExpression &sanitize_ipv6_re()
{
	static const auto *re = new QRegularExpression(
		R"((?<![0-9A-Za-z])\[?(?:(?:[0-9A-Fa-f]{1,4}:){3,7}[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{0,4}:){0,7}::(?:[0-9A-Fa-f]{0,4}:){0,7}[0-9A-Fa-f]{0,4})\]?(?![0-9A-Za-z]))");
	return *re;
}
static const QRegularExpression &sanitize_labeled_secret_re()
{
	static const auto *re = new QRegularExpression(
		R"((((?:console|host|server|session|account|psn|public|remote)\s+(?:id|ip|address)|duid)\s*:\s*)([^\s,;]+))",
		QRegularExpression::CaseInsensitiveOption);
	return *re;
}
static const QRegularExpression &sanitize_session_id_token_re()
{
	static const auto *re = new QRegularExpression(
		R"((session\s+id\s+)([A-Za-z0-9+/=_-]{8,}))",
		QRegularExpression::CaseInsensitiveOption);
	return *re;
}
static const QRegularExpression &sanitize_uuid_re()
{
	static const auto *re = new QRegularExpression(
		R"(\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\b)");
	return *re;
}
static const QRegularExpression &sanitize_long_hex_re()
{
	static const auto *re = new QRegularExpression(
		R"(\b[a-fA-F0-9]{16,}\b)");
	return *re;
}
static const QRegularExpression &sanitize_account_id_re()
{
	static const auto *re = new QRegularExpression(
		R"((account(?:_id)?\s*=\s*)([^\s,;]+))", QRegularExpression::CaseInsensitiveOption);
	return *re;
}
static const QRegularExpression &sanitize_duid_re()
{
	static const auto *re = new QRegularExpression(
		R"((duid\s*=\s*)([^\s,;]+))", QRegularExpression::CaseInsensitiveOption);
	return *re;
}
static const QRegularExpression &sanitize_session_id_eq_re()
{
	static const auto *re = new QRegularExpression(
		R"((session\s+id\s*=\s*)([^\s,;]+))", QRegularExpression::CaseInsensitiveOption);
	return *re;
}

static bool ContainsLongHexRun(const QString &s)
{
	int run = 0;
	for(QChar ch : s)
	{
		const ushort c = ch.unicode();
		const bool is_hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
		if(is_hex)
		{
			if(++run >= 16)
				return true;
		}
		else
		{
			run = 0;
		}
	}
	return false;
}

static QString SanitizeLogMessage(const QString &msg)
{
	QString sanitized = msg;

	if(sanitized.contains(QLatin1Char('.')))
		sanitized.replace(sanitize_ipv4_re(), QStringLiteral("<redacted-ipv4>"));
	if(sanitized.contains(QLatin1Char(':')))
	{
		sanitized.replace(sanitize_ipv6_re(), QStringLiteral("<redacted-ipv6>"));
		sanitized.replace(sanitize_labeled_secret_re(), QStringLiteral("\\1<redacted>"));
	}
	if(sanitized.contains(QLatin1Char('=')))
	{
		sanitized.replace(sanitize_account_id_re(), QStringLiteral("\\1<redacted>"));
		sanitized.replace(sanitize_duid_re(), QStringLiteral("\\1<redacted>"));
		sanitized.replace(sanitize_session_id_eq_re(), QStringLiteral("\\1<redacted>"));
	}
	if(sanitized.contains(QStringLiteral("session"), Qt::CaseInsensitive))
		sanitized.replace(sanitize_session_id_token_re(), QStringLiteral("\\1<redacted>"));
	if(sanitized.contains(QLatin1Char('-')))
		sanitized.replace(sanitize_uuid_re(), QStringLiteral("<redacted-uuid>"));

	// Catch unlabeled long hex identifiers, which commonly occur in console IDs and device UIDs.
	if(ContainsLongHexRun(sanitized))
		sanitized.replace(sanitize_long_hex_re(), QStringLiteral("<redacted-hex>"));

	return sanitized;
}

#define KEEP_LOG_FILES_COUNT 5

QString GetLogBaseDir()
{
	auto base_dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
	if(base_dir.isEmpty())
		return QString();

	QDir dir(base_dir);
	if(!dir.mkpath("log"))
		return QString();
	if(!dir.cd("log"))
		return QString();

	return dir.absolutePath();
}

QString CreateLogFilename()
{
	static const QString date_format = "yyyy-MM-dd_HH-mm-ss-zzzzzz";
	static const QString session_log_wildcard = "chiaki_session_*.log";
	static const QRegularExpression session_log_regex("chiaki_session_(.*).log");

	QString dir_str = GetLogBaseDir();
	if(dir_str.isEmpty())
		return QString();
	QDir dir = QDir(dir_str);

	dir.setNameFilters({ session_log_wildcard });
	auto existing_files = dir.entryList();
	QVector<QPair<QString, QDateTime>> existing_files_date;
	existing_files_date.resize(existing_files.count());
	std::transform(existing_files.begin(), existing_files.end(), existing_files_date.begin(), [](const QString &filename) {
		QDateTime date;
		auto match = session_log_regex.match(filename);
		if(match.hasMatch())
			date = QDateTime::fromString(match.captured(1), date_format);
		return QPair<QString, QDateTime>(filename, date);
	});
	std::sort(existing_files_date.begin(), existing_files_date.end(), [](const QPair<QString, QDateTime> &a, const QPair<QString, QDateTime> &b) {
		return a.second > b.second;
	});

	for(int i=KEEP_LOG_FILES_COUNT; i<existing_files_date.count(); i++)
	{
		const auto &pair = existing_files_date[i];
		if(!pair.second.isValid())
			break;
		dir.remove(pair.first);
	}

	QString filename = "chiaki_session_" + QDateTime::currentDateTime().toString(date_format) + ".log";
	return dir.absoluteFilePath(filename);
}
