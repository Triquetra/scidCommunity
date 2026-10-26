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

#include "filelock.h"
#include "scidbase.h"
#include <filesystem>
#include <fstream>
#include <gtest/gtest.h>
#include <iterator>
#include <string>

#ifndef _WIN32
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace {

class TempDir {
	std::filesystem::path path_;

public:
	TempDir() {
		const auto stamp =
		    std::to_string(std::filesystem::file_time_type::clock::now().time_since_epoch().count());
		path_ = std::filesystem::temp_directory_path() / ("scid_filelock_" + stamp);
		std::filesystem::create_directories(path_);
	}
	~TempDir() {
		std::error_code ec;
		std::filesystem::remove_all(path_, ec);
	}
	TempDir(const TempDir&) = delete;
	TempDir& operator=(const TempDir&) = delete;

	std::filesystem::path operator/(std::string_view name) const { return path_ / name; }
};

void writeFile(const std::filesystem::path& path, std::string_view text) {
	std::ofstream file(path, std::ios::binary | std::ios::trunc);
	file << text;
}

std::string readFile(const std::filesystem::path& path) {
	std::ifstream file(path, std::ios::binary);
	return std::string((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
}

} // namespace

TEST(FileLock, acquireTakesTheLockAndReleaseFreesIt) {
	TempDir dir;
	const auto lockPath = dir / "db.si4.lock";

	filelock::Lock first;
	ASSERT_EQ(filelock::Status::Acquired, filelock::acquire(lockPath, first));
	EXPECT_TRUE(first.held());
	EXPECT_TRUE(std::filesystem::exists(lockPath));

	// A second holder, even in the same process, is refused: that is the
	// second-instance case the lock exists for.
	filelock::Lock second;
	EXPECT_EQ(filelock::Status::InUse, filelock::acquire(lockPath, second));
	EXPECT_FALSE(second.held());

	first.release();
	EXPECT_FALSE(first.held());
	// Giving the database up removes the file, so an older Scid - which treats
	// the file's existence as the lock - can open it again.
	EXPECT_FALSE(std::filesystem::exists(lockPath));

	EXPECT_EQ(filelock::Status::Acquired, filelock::acquire(lockPath, second));
	EXPECT_TRUE(second.held());
}

TEST(FileLock, movingTheLockKeepsIt) {
	TempDir dir;
	const auto lockPath = dir / "db.si4.lock";

	filelock::Lock original;
	ASSERT_EQ(filelock::Status::Acquired, filelock::acquire(lockPath, original));

	filelock::Lock moved = std::move(original);
	EXPECT_FALSE(original.held());
	EXPECT_TRUE(moved.held());

	filelock::Lock other;
	EXPECT_EQ(filelock::Status::InUse, filelock::acquire(lockPath, other));

	filelock::Lock assigned;
	assigned = std::move(moved);
	EXPECT_FALSE(moved.held());
	EXPECT_TRUE(assigned.held());
	EXPECT_EQ(filelock::Status::InUse, filelock::acquire(lockPath, other));

	assigned.release();
	EXPECT_EQ(filelock::Status::Acquired, filelock::acquire(lockPath, other));
}

TEST(FileLock, aCrashedLockFileIsReclaimed) {
	TempDir dir;
	const auto lockPath = dir / "db.si4.lock";

	// What a crash or a kill leaves behind: this version's marker, and nobody
	// holding it. The kernel lock is free, so the database can be opened.
	writeFile(lockPath, filelock::detail::kMarker);

	filelock::Lock lock;
	EXPECT_EQ(filelock::Status::Acquired, filelock::acquire(lockPath, lock));
	EXPECT_TRUE(lock.held());

	lock.release();
	EXPECT_FALSE(std::filesystem::exists(lockPath));
}

TEST(FileLock, anOlderVersionsLockFileIsRespected) {
	TempDir dir;
	const std::string_view old[] = {
	    std::string_view(),          // what an older Scid creates: empty
	    std::string_view("garbage"), // something that is not our marker
	};
	int n = 0;
	for (const auto content : old) {
		const auto lockPath = dir / ("old" + std::to_string(n++) + ".si4.lock");
		writeFile(lockPath, content);

		// An older Scid holds a database by leaving the file there, so the
		// file could mean a running old version; nothing here can tell that
		// apart from one that crashed, so the old answer stands.
		filelock::Lock lock;
		EXPECT_EQ(filelock::Status::InUse, filelock::acquire(lockPath, lock));
		EXPECT_FALSE(lock.held());
		EXPECT_EQ(std::string(content), readFile(lockPath)); // left untouched
	}
}

#ifndef _WIN32
TEST(FileLock, theLockIsFreedWhenTheHolderDies) {
	TempDir dir;
	const auto lockPath = dir / "db.si4.lock";

	// The child takes the lock and then dies without releasing it, the way a
	// crash or a kill leaves things. The kernel must free it.
	int acquiredPipe[2] = {-1, -1};
	int diePipe[2] = {-1, -1};
	ASSERT_EQ(0, ::pipe(acquiredPipe));
	ASSERT_EQ(0, ::pipe(diePipe));

	const pid_t pid = ::fork();
	ASSERT_GE(pid, 0);
	if (pid == 0) {
		::close(acquiredPipe[0]);
		::close(diePipe[1]);
		filelock::Lock lock;
		const char acquired = (filelock::acquire(lockPath, lock) == filelock::Status::Acquired) ? 1 : 0;
		(void)!::write(acquiredPipe[1], &acquired, 1);
		char go = 0;
		(void)!::read(diePipe[0], &go, 1);
		::_exit(0); // no release, no destructor: this is the crash
	}

	::close(acquiredPipe[1]);
	::close(diePipe[0]);

	char acquired = 0;
	ASSERT_EQ(1, static_cast<int>(::read(acquiredPipe[0], &acquired, 1)));
	ASSERT_EQ(1, acquired);

	filelock::Lock lock;
	EXPECT_EQ(filelock::Status::InUse, filelock::acquire(lockPath, lock));

	(void)!::write(diePipe[1], "x", 1);
	int status = 0;
	::waitpid(pid, &status, 0);
	EXPECT_TRUE(WIFEXITED(status));

	EXPECT_EQ(filelock::Status::Acquired, filelock::acquire(lockPath, lock));
}
#endif

TEST(FileLock, oneDatabaseInTwoSpellingsSharesOneLock) {
	TempDir dir;

	// CodecSCID5 adds .si5 to a bare name, so these are the same database.
	const auto dbPath = dir / "alias.si5";
	scidBaseT dbase;
	ASSERT_EQ(OK, dbase.open("SCID5", FMODE_Create, dbPath.string().c_str()));

	auto bare = dbPath;
	bare.replace_extension();
	scidBaseT other;
	EXPECT_EQ(ERROR_FileInUse, other.open("SCID5", FMODE_Both, bare.string().c_str()));

	// The same file reached through a . in the middle is the same database too.
	const auto dotted = (dbPath.parent_path() / "." / dbPath.filename()).string();
	EXPECT_EQ(ERROR_FileInUse, other.open("SCID5", FMODE_Both, dotted.c_str()));

	// CodecSCID4 strips .si4 before adding it back, so the bare name is the
	// same database there as well.
	const auto db4Path = dir / "alias4.si4";
	scidBaseT base4;
	ASSERT_EQ(OK, base4.open("SCID4", FMODE_Create, db4Path.string().c_str()));
	auto bare4 = db4Path;
	bare4.replace_extension();
	EXPECT_EQ(ERROR_FileInUse, other.open("SCID4", FMODE_Both, bare4.string().c_str()));
}

TEST(FileLock, scidBaseHoldsTheLockWhileTheDatabaseIsOpen) {
	TempDir dir;
	const auto dbPath = dir / "locklifecycle.si5";
	const auto lockPath = dbPath.string() + ".lock";

	scidBaseT dbase;
	ASSERT_EQ(OK, dbase.open("SCID5", FMODE_Create, dbPath.string().c_str()));
	ASSERT_TRUE(std::filesystem::exists(lockPath));

	scidBaseT other;
	EXPECT_EQ(ERROR_FileInUse, other.open("SCID5", FMODE_Both, dbPath.string().c_str()));

	dbase.Close();
	// Closing removes the file, which is what keeps a downgrade working.
	EXPECT_FALSE(std::filesystem::exists(lockPath));

	ASSERT_EQ(OK, other.open("SCID5", FMODE_Both, dbPath.string().c_str()));
	other.Close();
}
