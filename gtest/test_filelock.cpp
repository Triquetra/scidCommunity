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

#include "filelock.h"
#include "scidbase.h"
#include <filesystem>
#include <fstream>
#include <gtest/gtest.h>
#include <string>

namespace {

/// A pid that cannot belong to a running process on either platform.
constexpr unsigned long kDeadPid = 4294967294UL;

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

void writeRecord(const std::filesystem::path& path, std::string_view record) {
	std::ofstream file(path, std::ios::binary | std::ios::trunc);
	file << record;
}

std::string readFile(const std::filesystem::path& path) {
	std::ifstream file(path, std::ios::binary);
	return std::string((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
}

} // namespace

TEST(FileLock, acquireWritesOwnerRecordAndReleaseRemovesFile) {
	TempDir dir;
	const auto lockPath = dir / "db.si4.lock";

	ASSERT_EQ(filelock::Status::Acquired, filelock::acquire(lockPath));
	ASSERT_TRUE(std::filesystem::exists(lockPath));
	const auto record = readFile(lockPath);
	EXPECT_NE(std::string::npos, record.find("\npid=" + std::to_string(filelock::detail::currentPid())));
	EXPECT_NE(std::string::npos, record.find("\nhost=" + filelock::detail::hostname()));

	filelock::release(lockPath);
	EXPECT_FALSE(std::filesystem::exists(lockPath));
	filelock::release(lockPath); // releasing twice is not an error
}

TEST(FileLock, liveOwnerIsReportedAsInUse) {
	TempDir dir;
	const auto lockPath = dir / "db.si4.lock";

	ASSERT_EQ(filelock::Status::Acquired, filelock::acquire(lockPath));
	// This very process owns it, and it is still running: the second attempt
	// must be refused, not reclaimed.
	EXPECT_EQ(filelock::Status::InUse, filelock::acquire(lockPath));
	EXPECT_TRUE(std::filesystem::exists(lockPath));
	EXPECT_NE(std::string::npos,
	          readFile(lockPath).find("\npid=" + std::to_string(filelock::detail::currentPid())));

	filelock::release(lockPath);
}

TEST(FileLock, lockOfDeadProcessIsReclaimed) {
	if (filelock::detail::hostname().empty())
		GTEST_SKIP() << "hostname unavailable, remote owners cannot be verified";

	TempDir dir;
	const auto lockPath = dir / "db.si4.lock";
	writeRecord(lockPath, std::string(filelock::detail::kFormat) + "\npid=" +
	                          std::to_string(kDeadPid) + "\nhost=" +
	                          filelock::detail::hostname() + "\n");

	ASSERT_EQ(filelock::Status::Acquired, filelock::acquire(lockPath));
	const auto record = readFile(lockPath);
	EXPECT_NE(std::string::npos, record.find("\npid=" + std::to_string(filelock::detail::currentPid())));

	filelock::release(lockPath);
}

TEST(FileLock, lockOfLiveProcessWithReusedPidIsNotReclaimed) {
	if (filelock::detail::hostname().empty())
		GTEST_SKIP() << "hostname unavailable, remote owners cannot be verified";

	// A live pid that is not the process that wrote the record (this test's
	// own pid stands in for a recycled pid): refusing is the safe answer.
	TempDir dir;
	const auto lockPath = dir / "db.si4.lock";
	writeRecord(lockPath, std::string(filelock::detail::kFormat) + "\npid=" +
	                          std::to_string(filelock::detail::currentPid()) + "\nhost=" +
	                          filelock::detail::hostname() + "\n");

	EXPECT_EQ(filelock::Status::InUse, filelock::acquire(lockPath));
	EXPECT_EQ(filelock::Status::InUse, filelock::acquire(lockPath));
}

TEST(FileLock, lockOfAnotherHostIsNotReclaimed) {
	TempDir dir;
	const auto lockPath = dir / "db.si4.lock";
	const auto record = std::string(filelock::detail::kFormat) + "\npid=" +
	                    std::to_string(kDeadPid) + "\nhost=some-other-machine\n";
	writeRecord(lockPath, record);

	EXPECT_EQ(filelock::Status::InUse, filelock::acquire(lockPath));
	EXPECT_EQ(record, readFile(lockPath)); // the foreign lock is left untouched
}

TEST(FileLock, recordWithoutOwnerKeepsLegacyBehaviour) {
	TempDir dir;

	// Empty lock file: what older Scid versions left behind, and what a crash
	// between creating and filling the file would leave. Neither is provably
	// stale, so both keep the previous "in use" answer.
	for (const std::string_view record : {std::string_view(), std::string_view("garbage\n")}) {
		const auto lockPath = dir / ("db" + std::to_string(record.size()) + ".si4.lock");
		writeRecord(lockPath, record);
		EXPECT_EQ(filelock::Status::InUse, filelock::acquire(lockPath));
		EXPECT_EQ(std::string(record), readFile(lockPath));
	}
}

TEST(FileLock, scidBaseCreatesAndRemovesItsLock) {
	TempDir dir;
	const auto dbPath = dir / "locklifecycle.si5";
	const auto lockPath = dbPath.string() + ".lock";

	scidBaseT dbase;
	ASSERT_EQ(OK, dbase.open("SCID5", FMODE_Create, dbPath.string().c_str()));
	ASSERT_TRUE(std::filesystem::exists(lockPath));

	scidBaseT other;
	EXPECT_EQ(ERROR_FileInUse, other.open("SCID5", FMODE_Both, dbPath.string().c_str()));

	dbase.Close();
	EXPECT_FALSE(std::filesystem::exists(lockPath));

	// The lock is gone, so the database can be opened again.
	ASSERT_EQ(OK, other.open("SCID5", FMODE_Both, dbPath.string().c_str()));
	other.Close();
}
