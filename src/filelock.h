/*
* Copyright (C) 2026  David Crandall

* This file is part of Scid (Shane's Chess Information Database).
*
* Scid is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation.
*
* Scid is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with Scid.  If not, see <http://www.gnu.org/licenses/>.
*/

#pragma once

#include <cerrno>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>
#include <string>
#include <string_view>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else // POSIX (Linux, macOS)
#include <csignal>
#include <unistd.h>
#endif

/**
 * Exclusive lock used to keep two processes from writing the same database.
 *
 * The lock is an advisory file next to the database (`<database>.lock`): the
 * process that creates it owns the database and removes it on close. A plain
 * "does the file exist?" test is not enough, because the file survives every
 * close path that never runs - a crash, a SIGKILL or Task Manager kill, a lost
 * session - and from then on every open fails until someone deletes it by
 * hand. The lock file therefore records who created it (pid + hostname), so a
 * leftover lock whose owner no longer exists on this machine can be detected
 * and reclaimed.
 *
 * The rule is deliberately conservative: anything that cannot be *proven*
 * stale counts as in use. A lock owned by another machine, a lock written by a
 * version that recorded no owner, and a lock whose file cannot be read all
 * keep the old behaviour (refuse to open), so this can never hand the same
 * database to two writers.
 */
namespace filelock {

enum class Status {
	Acquired, ///< the lock file is ours; the caller owns the database
	InUse,    ///< another process owns the database
	Error,    ///< the lock file could not be created
};

namespace detail {

constexpr std::string_view kFormat = "scid-lock v1";
constexpr size_t kMaxRecordSize = 4096;

/// Name of this machine; empty if it cannot be determined.
inline std::string hostname() {
#ifdef _WIN32
	char buf[MAX_COMPUTERNAME_LENGTH + 1] = {0};
	DWORD len = static_cast<DWORD>(sizeof(buf));
	return ::GetComputerNameA(buf, &len) ? std::string(buf, len) : std::string();
#else
	char buf[256] = {0};
	return (::gethostname(buf, sizeof(buf) - 1) == 0) ? std::string(buf) : std::string();
#endif
}

/// Pid of this process.
inline unsigned long currentPid() {
#ifdef _WIN32
	return static_cast<unsigned long>(::GetCurrentProcessId());
#else
	return static_cast<unsigned long>(::getpid());
#endif
}

/// True if the process may still be running; unknown pids and pids owned by
/// another user (EPERM / access denied) count as alive.
inline bool processIsAlive(unsigned long pid) {
	if (pid == 0)
		return true;
#ifdef _WIN32
	const HANDLE handle = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
	if (handle == nullptr) {
		// The only failure that proves the process is gone is "no such pid".
		return ::GetLastError() != ERROR_INVALID_PARAMETER;
	}
	DWORD exitCode = 0;
	const bool alive =
	    (::GetExitCodeProcess(handle, &exitCode) != 0) && (exitCode == STILL_ACTIVE);
	::CloseHandle(handle);
	return alive;
#else
	// A pid outside pid_t's range cannot exist on this platform, and casting a
	// negative value to pid_t would turn kill() into a process-group check.
	if (pid > static_cast<unsigned long>(std::numeric_limits<pid_t>::max()))
		return false;
	if (::kill(static_cast<pid_t>(pid), 0) == 0)
		return true;
	return errno != ESRCH;
#endif
}

struct Owner {
	std::string host;
	unsigned long pid = 0;
};

/// Parse a lock record. Returns false for a record this version did not write
/// (empty file, older Scid, foreign content).
inline bool parseOwner(std::string_view record, Owner& owner) {
	if (record.substr(0, kFormat.size()) != kFormat)
		return false;

	auto valueOf = [&record](std::string_view key) {
		const auto pos = record.find(key);
		if (pos == std::string_view::npos)
			return std::string();
		const auto start = pos + key.size();
		auto end = record.find('\n', start);
		if (end == std::string_view::npos)
			end = record.size();
		std::string value(record.substr(start, end - start));
		while (!value.empty() && (value.back() == '\r' || value.back() == ' '))
			value.pop_back();
		return value;
	};

	const auto pid = valueOf("\npid=");
	const auto host = valueOf("\nhost=");
	if (pid.empty() || host.empty())
		return false;

	unsigned long value = 0;
	for (const char c : pid) {
		if (c < '0' || c > '9')
			return false;
		value = value * 10 + static_cast<unsigned long>(c - '0');
	}
	if (value == 0)
		return false;

	owner.pid = value;
	owner.host = host;
	return true;
}

enum class Create { Created, Exists, Failed };

/// Create the lock file only if it does not exist, then write the owner record
/// into it. "x" is C11's exclusive-create mode: two processes racing here can
/// never both succeed.
inline Create writeExclusive(const std::filesystem::path& lockPath, std::string_view record) {
	std::FILE* file = nullptr;
#ifdef _WIN32
	if (::_wfopen_s(&file, lockPath.c_str(), L"wx") != 0)
		file = nullptr;
#else
	file = std::fopen(lockPath.c_str(), "wx");
#endif
	if (file == nullptr) {
		std::error_code ec;
		return std::filesystem::exists(lockPath, ec) ? Create::Exists : Create::Failed;
	}

	const bool ok = std::fwrite(record.data(), 1, record.size(), file) == record.size();
	std::fclose(file);
	if (!ok) {
		// Do not leave a record-less lock behind: that would look like a lock
		// of an older Scid version and block every later open.
		std::error_code ec;
		std::filesystem::remove(lockPath, ec);
		return Create::Failed;
	}
	return Create::Created;
}

/// Read the owner record of an existing lock file.
inline bool readOwner(const std::filesystem::path& lockPath, Owner& owner) {
	std::ifstream file(lockPath, std::ios::binary);
	if (!file)
		return false;

	std::string record(kMaxRecordSize, '\0');
	file.read(record.data(), static_cast<std::streamsize>(record.size()));
	record.resize(static_cast<size_t>(file.gcount()));
	return parseOwner(record, owner);
}

} // namespace detail

/**
 * Take the database lock.
 *
 * @param lockPath: path of the lock file (the database path plus ".lock").
 * @returns Status::Acquired if the lock is ours, Status::InUse if another
 *          process owns the database, Status::Error if the lock file could not
 *          be written.
 */
inline Status acquire(const std::filesystem::path& lockPath) {
	const auto me = detail::Owner{detail::hostname(), detail::currentPid()};
	const auto record = std::string(detail::kFormat) + "\npid=" + std::to_string(me.pid) +
	                    "\nhost=" + me.host + "\n";

	// Three attempts: one to win the lock, one to reclaim a stale lock, one to
	// retry if the stale lock was removed by a competing process in between.
	for (int attempt = 0; attempt < 3; ++attempt) {
		switch (detail::writeExclusive(lockPath, record)) {
		case detail::Create::Created:
			return Status::Acquired;
		case detail::Create::Failed:
			return Status::Error;
		case detail::Create::Exists:
			break;
		}

		// The lock exists. Reclaim it only if its owner provably no longer
		// exists on this machine; everything else stays "in use".
		detail::Owner owner;
		if (!detail::readOwner(lockPath, owner))
			return Status::InUse;
		if (me.host.empty() || owner.host != me.host)
			return Status::InUse;
		if (detail::processIsAlive(owner.pid))
			return Status::InUse;

		std::error_code ec;
		std::filesystem::remove(lockPath, ec);
		if (ec)
			return Status::InUse;
	}
	return Status::InUse;
}

/// Remove the database lock. Safe to call when the file is already gone.
inline void release(const std::filesystem::path& lockPath) {
	std::error_code ec;
	std::filesystem::remove(lockPath, ec);
}

} // namespace filelock
