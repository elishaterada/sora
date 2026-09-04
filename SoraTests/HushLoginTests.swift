import XCTest

final class HushLoginTests: XCTestCase {
    func testCreatesEmptyHushloginWhenMissing() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sora-hush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let hush = home.appendingPathComponent(".hushlogin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: hush.path))
        try HushLogin.ensure(home: home)
        XCTAssertEqual(try Data(contentsOf: hush), Data())
        try HushLogin.ensure(home: home)
        XCTAssertEqual(try Data(contentsOf: hush), Data())
    }

    func testLeavesExistingHushloginAlone() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sora-hush-keep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let hush = home.appendingPathComponent(".hushlogin")
        try Data("keep".utf8).write(to: hush)
        try HushLogin.ensure(home: home)
        XCTAssertEqual(try String(contentsOf: hush, encoding: .utf8), "keep")
    }
}
