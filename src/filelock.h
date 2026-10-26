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
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
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
 * The file is created when the database is claimed and removed when it is
 * given up, so the previous release - which treats the file's mere existence
 * as the lock - keeps working across a downgrade. A crash leaves the file
 * behind; the next open of a database checks it for this version's marker and
 * reclaims it. A lock file without the marker was written by an older Scid
 * which may still be running, and keeping the old "in use" answer for it is
 * the only safe reading: the file an old version leaves when it crashes is
 * indistinguishable from the one it holds while running. Such a leftover needs
 * one manual delete, exactly as before; a build with this change never leaves
 * one.
 *
 * Two limits are worth knowing. The lock only excludes processes on the same
 * machine, and it is advisory, like the existence check it replaces: a program
 * that does not ask for the lock can still write the file. It also depends on
 * the filesystem honouring advisory locks when a database lives on a network
 * share - local filesystems do, network filesystems vary by protocol and by
 * how the mount is configured.
 */
namespace filelock {

enum class Status {
	Acquired, ///< the lock is ours; the caller owns the database
	InUse,    ///< another process owns the database
	Error,    ///< the lock file could not be opened, created or locked
};

namespace detail {

/// Written into a lock file this version creates. Its absence means the file
/// came from an older Scid, whose lock was the file's existence.
constexpr std::string_view kMarker = "scid-lock v1\n";

#ifdef _WIN32

inline HANDLE openExisting(const std::filesystem::path& path) {
	return ::CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE,
	                     FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
	                     OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
}

/// Create the lock file with its marker already in it, or return
/// INVALID_HANDLE_VALUE (GetLastError() == ERROR_FILE_EXISTS if it is there).
inline HANDLE create(const std::filesystem::path& path) {
	const HANDLE handle =
	    ::CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE,
	                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, CREATE_NEW,
	                  FILE_ATTRIBUTE_NORMAL, nullptr);
	if (handle == INVALID_HANDLE_VALUE)
		return handle;

	DWORD written = 0;
	if (::WriteFile(handle, kMarker.data(), static_cast<DWORD>(kMarker.size()), &written,
	                nullptr) &&
	    written == kMarker.size()) {
		return handle;
	}
	::CloseHandle(handle);
	::DeleteFileW(path.c_str());
	return INVALID_HANDLE_VALUE;
}

inline bool isSameFile(const std::filesystem::path& path, HANDLE handle) {
	BY_HANDLE_FILE_INFORMATION mine = {};
	if (!::GetFileInformationByHandle(handle, &mine))
		return false;

	const HANDLE other = openExisting(path);
	if (other == INVALID_HANDLE_VALUE)
		return false;
	BY_HANDLE_FILE_INFORMATION theirs = {};
	const bool ok = ::GetFileInformationByHandle(other, &theirs) != 0;
	::CloseHandle(other);

	return ok && mine.dwVolumeSerialNumber == theirs.dwVolumeSerialNumber &&
	       mine.nFileIndexHigh == theirs.nFileIndexHigh &&
	       mine.nFileIndexLow == theirs.nFileIndexLow;
}

inline bool hasMarker(HANDLE handle) {
	LARGE_INTEGER start = {};
	if (!::SetFilePointerEx(handle, start, nullptr, FILE_BEGIN))
		return false;
	char buf[kMarker.size()] = {};
	DWORD read = 0;
	if (!::ReadFile(handle, buf, static_cast<DWORD>(sizeof(buf)), &read, nullptr))
		return false;
	return read == sizeof(buf) && std::string_view(buf, sizeof(buf)) == kMarker;
}

#else // POSIX

inline bool isSameFile(const std::filesystem::path& path, int fd) {
	struct stat onDisk = {};
	struct stat held = {};
	return ::stat(path.c_str(), &onDisk) == 0 && ::fstat(fd, &held) == 0 &&
	       onDisk.st_dev == held.st_dev && onDisk.st_ino == held.st_ino;
}

inline bool hasMarker(int fd) {
	char buf[kMarker.size()] = {};
	const auto n = ::pread(fd, buf, sizeof(buf), 0);
	return n == static_cast<ssize_t>(sizeof(buf)) && std::string_view(buf, sizeof(buf)) == kMarker;
}

#endif

} // namespace detail

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
		if (!held())
			return;
#ifdef _WIN32
		// While the lock is held nobody else can release it, so the file at the
		// path is ours; removing it is what keeps the next open from seeing a
		// lock nobody holds - and what lets an older Scid open the database.
		if (detail::isSameFile(path_, handle_))
			::DeleteFileW(path_.c_str());
		OVERLAPPED overlapped = {};
		::UnlockFileEx(handle_, 0, 1, 0, &overlapped);
		::CloseHandle(handle_);
		handle_ = INVALID_HANDLE_VALUE;
#else
		if (detail::isSameFile(path_, fd_))
			::unlink(path_.c_str());
		::flock(fd_, LOCK_UN);
		::close(fd_);
		fd_ = -1;
#endif
		path_.clear();
	}

private:
	void moveFrom(Lock& other) noexcept {
		path_ = std::move(other.path_);
		other.path_.clear();
#ifdef _WIN32
		handle_ = other.handle_;
		other.handle_ = INVALID_HANDLE_VALUE;
#else
		fd_ = other.fd_;
		other.fd_ = -1;
#endif
	}

	std::filesystem::path path_;
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
 * @param lockPath: path of the lock file (the database file's path plus ".lock").
 * @param lock: receives the lock on success; anything it held before is
 *              released first.
 * @returns Status::Acquired if the lock is ours, Status::InUse if another
 *          process owns the database, Status::Error if the lock file could not
 *          be opened or locked for any other reason.
 */
inline Status acquire(const std::filesystem::path& lockPath, Lock& lock) {
	lock.release();

#ifdef _WIN32
	for (int attempt = 0; attempt < 3; ++attempt) {
		HANDLE handle = detail::create(lockPath);
		const bool created = handle != INVALID_HANDLE_VALUE;
		if (!created) {
			if (::GetLastError() != ERROR_FILE_EXISTS)
				return Status::Error;
			handle = detail::openExisting(lockPath);
			if (handle == INVALID_HANDLE_VALUE)
				return Status::Error;
		}

		OVERLAPPED overlapped = {};
		if (!::LockFileEx(handle, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0,
		                  &overlapped)) {
			const DWORD err = ::GetLastError();
			::CloseHandle(handle);
			return err == ERROR_LOCK_VIOLATION ? Status::InUse : Status::Error;
		}

		// The owner that gave the database up removes the file, so the file at
		// the path may no longer be the one this handle locked.
		if (!detail::isSameFile(lockPath, handle)) {
			::UnlockFileEx(handle, 0, 1, 0, &overlapped);
			::CloseHandle(handle);
			continue;
		}

		// A lock file this version did not write belongs to an older Scid,
		// which may be holding the database right now.
		if (!created && !detail::hasMarker(handle)) {
			::UnlockFileEx(handle, 0, 1, 0, &overlapped);
			::CloseHandle(handle);
			return Status::InUse;
		}

		lock.handle_ = handle;
		lock.path_ = lockPath;
		return Status::Acquired;
	}
#else
	for (int attempt = 0; attempt < 3; ++attempt) {
		int fd = ::open(lockPath.c_str(), O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0666);
		const bool created = fd >= 0;
		if (created) {
			// The marker goes in before anyone else can look at the file, so a
			// file without it is never this version's.
			const auto n = ::write(fd, detail::kMarker.data(), detail::kMarker.size());
			if (n != static_cast<ssize_t>(detail::kMarker.size())) {
				::close(fd);
				::unlink(lockPath.c_str());
				return Status::Error;
			}
		} else if (errno == EEXIST) {
			do {
				fd = ::open(lockPath.c_str(), O_RDWR | O_CLOEXEC);
			} while (fd < 0 && errno == EINTR);
			if (fd < 0)
				return Status::Error;
		} else {
			return Status::Error;
		}

		int err = 0;
		do {
			err = ::flock(fd, LOCK_EX | LOCK_NB) == 0 ? 0 : errno;
		} while (err == EINTR);
		if (err != 0) {
			::close(fd);
			return (err == EWOULDBLOCK || err == EAGAIN) ? Status::InUse : Status::Error;
		}

		// Same as on Windows: only a lock on the file that is actually at the
		// path counts.
		if (!detail::isSameFile(lockPath, fd)) {
			::flock(fd, LOCK_UN);
			::close(fd);
			continue;
		}

		if (!created && !detail::hasMarker(fd)) {
			::flock(fd, LOCK_UN);
			::close(fd);
			return Status::InUse;
		}

		lock.fd_ = fd;
		lock.path_ = lockPath;
		return Status::Acquired;
	}
#endif

	return Status::InUse;
}

} // namespace filelock
