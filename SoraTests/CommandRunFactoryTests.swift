import XCTest

final class CommandRunFactoryTests: XCTestCase {
    func testSuccessfulCommand() throws {
        let cwd = URL(fileURLWithPath: "/tmp")
        let run = try XCTUnwrap(CommandRunFactory.make(
            command: "  pwd  ",
            cwd: cwd,
            exitCode: 0,
            durationNanos: 1_500_000_000,
            now: Date(timeIntervalSince1970: 100)
        ))
        XCTAssertEqual(run.command, "pwd")
        XCTAssertEqual(run.cwd, cwd)
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertEqual(run.finishedAt.timeIntervalSince1970, 100)
        XCTAssertEqual(run.startedAt.timeIntervalSince1970, 98.5, accuracy: 0.000_001)
    }

    func testSkipsUnmatchedPromptMark() {
        XCTAssertNil(CommandRunFactory.make(
            command: "pwd",
            cwd: URL(fileURLWithPath: "/tmp"),
            exitCode: -1,
            durationNanos: 0
        ))
    }

    func testSkipsEmptyCommand() {
        XCTAssertNil(CommandRunFactory.make(
            command: "   ",
            cwd: URL(fileURLWithPath: "/tmp"),
            exitCode: 0,
            durationNanos: 1
        ))
    }

    func testSkipsWorkingDirectoryTitles() {
        let cwd = URL(fileURLWithPath: "/Users/elisha/repos/sora")
        XCTAssertTrue(CommandRunFactory.isWorkingDirectoryTitle("~/repos/sora", cwd: cwd))
        XCTAssertTrue(CommandRunFactory.isWorkingDirectoryTitle("…/elisha/repos/sora", cwd: cwd))
        XCTAssertTrue(CommandRunFactory.isWorkingDirectoryTitle(cwd.path, cwd: cwd))
        XCTAssertFalse(CommandRunFactory.isWorkingDirectoryTitle("ls", cwd: cwd))
        XCTAssertFalse(CommandRunFactory.isWorkingDirectoryTitle("./script", cwd: cwd))
        XCTAssertNil(CommandRunFactory.make(
            command: "~/repos/sora",
            cwd: cwd,
            exitCode: 0,
            durationNanos: 1
        ))
    }
}
