import XCTest

final class CommandHistoryStoreTests: XCTestCase {
    func testInsertAndRecentOrder() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sora-history-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try CommandHistoryStore(url: url)
        let first = try XCTUnwrap(CommandRunFactory.make(
            command: "echo one",
            cwd: URL(fileURLWithPath: "/tmp"),
            exitCode: 0,
            durationNanos: 1,
            now: Date(timeIntervalSince1970: 10)
        ))
        let second = try XCTUnwrap(CommandRunFactory.make(
            command: "false",
            cwd: URL(fileURLWithPath: "/usr"),
            exitCode: 1,
            durationNanos: 2,
            now: Date(timeIntervalSince1970: 20)
        ))
        try store.record(first)
        try store.record(second)

        XCTAssertEqual(store.recent.map(\.command), ["false", "echo one"])
        XCTAssertEqual(store.recent.map(\.exitCode), [1, 0])

        let reopened = try CommandHistoryStore(url: url)
        XCTAssertEqual(reopened.recent.map(\.command), ["false", "echo one"])
        XCTAssertEqual(reopened.recent.first?.cwd.path, "/usr")
    }
}
