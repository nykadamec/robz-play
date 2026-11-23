// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef CHIAKI_SESSIONLOG_H
#define CHIAKI_SESSIONLOG_H

#include <chiaki/log.h>

#include <QString>
#include <QDir>
#include <QMutex>
#include <QAtomicInteger>

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

class QFile;
class StreamSession;

class SessionLog
{
	friend class SessionLogPrivate;

	private:
		struct Entry
		{
			ChiakiLogLevel level;
			int64_t timestamp_us;
			std::string msg;
		};

		StreamSession *session;
		ChiakiLog log;
		QFile *file;
		QMutex file_mutex;
		QAtomicInteger<bool> shutdown;
		bool sanitize;
		std::mutex queue_mutex;
		std::condition_variable queue_cv;
		std::deque<Entry> queue;
		std::thread writer_thread;
		bool stop_writer = false;
		size_t dropped_low_priority = 0;

		void Log(ChiakiLogLevel level, const char *msg);
		void WriterLoop();

	public:
		SessionLog(StreamSession *session, uint32_t level_mask, const QString &filename, bool sanitize);
		~SessionLog();

		ChiakiLog *GetChiakiLog()	{ return &log; }
		void PrepareShutdown();
};

QString GetLogBaseDir();
QString CreateLogFilename();

#endif //CHIAKI_SESSIONLOG_H
