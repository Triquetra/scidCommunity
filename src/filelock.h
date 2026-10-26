/*
* Copyright (C) 2026  David Crandall
* Copyright (C) 2026  Hugh Whelan

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
#include <filesystem>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else // POSIX (Linux, macOS)
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
#endif

/**
 * Exclusive lock used to keep two processes from writing the same database.
 *
 * The lock is advisory and the operating system holds it: the process opens
 * `<database>.lock` and asks the kernel to lock the file, and keeps that handle
 * open for as long as it owns the database. Because the kernel owns the lock,
 * it is released however the process ends - a clean exit, a crash, a SIGKILL,
 * Task Manager - so an unclean exit cannot leave a database unopenable, and no
 * pid or host name has to be trusted to decide whether the previous owner is
 * still there.
 *
 * The lock file is created if it is missing and deliberately never removed:
 * unlinking a file that another process may have just opened is the one step
 * that cannot be made atomic with a lock on that file. Its existence therefore
 * means nothing - only the lock does - and a leftover file from an older
 * version, a crash or a kill blocks nothing.
 *
 * Two limits are worth knowing. Only the same machine is excluded: a lock is
 * enforced by the local kernel, so it depends on the filesystem honouring
 * locks when the database lives on a network share (NFSv4 and SMB do; some
 * FUSE mounts do not). And it is advisory, like the existence check it
 * replaces: a program that does not ask for the lock can still write the file.
 */
namespace filelock {

enum class Status {
	Acquired, ///< the lock is ours; the caller owns the database
	InUse,    ///< another process owns the database
	Error,    ///< the lock file could not be opened or locked
};

/**
 * A held lock. Move-only; releasing it (or destroying it) gives the database
 * up. Keep it alive for as long as the database is open.
 */
class Lock {
public:
	Lock() = default;
	~Lock() { release(); }

	Lock(Lock&& other) noexcept { moveFrom(other); }
	Lock& operator=(Lock&& other) noexcept {
		if (this != &other) {
			release();
			moveFrom(other);
		}
		return *this;
	}
	Lock(const Lock&) = delete;
	Lock& operator=(const Lock&) = delete;

	bool held() const {
#ifdef _WIN32
		return handle_ != INVALID_HANDLE_VALUE;
#else
		return fd_ >= 0;
#endif
	}

	void release() {
#ifdef _WIN32
		if (handle_ != INVALID_HANDLE_VALUE) {
			OVERLAPPED overlapped = {};
			::UnlockFileEx(handle_, 0, 1, 0, &overlapped);
			::CloseHandle(handle_);
			handle_ = INVALID_HANDLE_VALUE;
		}
#else
		if (fd_ >= 0) {
			::flock(fd_, LOCK_UN);
			::close(fd_);
			fd_ = -1;
		}
#endif
	}

private:
	void moveFrom(Lock& other) noexcept {
#ifdef _WIN32
		handle_ = other.handle_;
		other.handle_ = INVALID_HANDLE_VALUE;
#else
		fd_ = other.fd_;
		other.fd_ = -1;
#endif
	}

#ifdef _WIN32
	HANDLE handle_ = INVALID_HANDLE_VALUE;
#else
	int fd_ = -1;
#endif

	friend Status acquire(const std::filesystem::path&, Lock&);
};

/**
 * Take the database lock.
 *
 * @param lockPath: path of the lock file (the database path plus ".lock").
 * @param lock: receives the lock on success; anything it held before is
 *              released first.
 * @returns Status::Acquired if the lock is ours, Status::InUse if another
 *          process owns the database, Status::Error if the lock file could not
 *          be opened or locked for any other reason.
 */
inline Status acquire(const std::filesystem::path& lockPath, Lock& lock) {
	lock.release();

#ifdef _WIN32
	const HANDLE handle =
	    ::CreateFileW(lockPath.c_str(), GENERIC_READ | GENERIC_WRITE,
	                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_ALWAYS,
	                  FILE_ATTRIBUTE_NORMAL, nullptr);
	if (handle == INVALID_HANDLE_VALUE)
		return Status::Error;

	OVERLAPPED overlapped = {};
	if (!::LockFileEx(handle, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0,
	                  &overlapped)) {
		const DWORD err = ::GetLastError();
		::CloseHandle(handle);
		return err == ERROR_LOCK_VIOLATION ? Status::InUse : Status::Error;
	}
	lock.handle_ = handle;
#else
	int fd = -1;
	do {
		fd = ::open(lockPath.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0666);
	} while (fd < 0 && errno == EINTR);
	if (fd < 0)
		return Status::Error;

	int err = 0;
	do {
		err = ::flock(fd, LOCK_EX | LOCK_NB) == 0 ? 0 : errno;
	} while (err == EINTR);
	if (err != 0) {
		::close(fd);
		// Both names mean "someone else holds it" on the platforms we build for.
		return (err == EWOULDBLOCK || err == EAGAIN) ? Status::InUse : Status::Error;
	}
	lock.fd_ = fd;
#endif

	return Status::Acquired;
}

} // namespace filelock
