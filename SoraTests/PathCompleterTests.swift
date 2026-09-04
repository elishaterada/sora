import XCTest

final class PathCompleterTests: XCTestCase {
    func testLastTokenAndLooksLikePath() {
        XCTAssertEqual(PathCompleter.lastToken(in: "git st").token, "st")
        XCTAssertEqual(PathCompleter.lastToken(in: "ls").token, "ls")
        XCTAssertTrue(PathCompleter.looksLikePath("./src"))
        XCTAssertTrue(PathCompleter.looksLikePath("~/Documents"))
        XCTAssertTrue(PathCompleter.looksLikePath("src/"))
        XCTAssertFalse(PathCompleter.looksLikePath("git"))
    }

    func testMatchesDirectoriesFirstAndAddsSlash() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sora-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("scripts", isDirectory: true),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("README.md").path,
            contents: Data("hi".utf8)
        )
        FileManager.default.createFile(
            atPath: root.appendingPathComponent(".hidden").path,
            contents: Data()
        )

        let srcMatches = PathCompleter.matches(token: "s", cwd: root)
        XCTAssertEqual(srcMatches.first?.token, "src/")
        XCTAssertEqual(srcMatches.first?.isDirectory, true)
        XCTAssertTrue(srcMatches.contains { $0.token == "scripts/" })
        XCTAssertFalse(srcMatches.contains { $0.token == "README.md" })

        let readme = PathCompleter.matches(token: "RE", cwd: root)
        XCTAssertEqual(readme.map(\.token), ["README.md"])

        let nested = PathCompleter.matches(token: "src/", cwd: root)
        XCTAssertEqual(nested, [])

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src/app", isDirectory: true),
            withIntermediateDirectories: true
        )
        let afterSlash = PathCompleter.matches(token: "src/", cwd: root)
        XCTAssertEqual(afterSlash.map(\.token), ["src/app/"])

        let hidden = PathCompleter.matches(token: ".", cwd: root)
        XCTAssertTrue(hidden.contains { $0.token == ".hidden" })
        XCTAssertEqual(PathCompleter.matches(token: "~", cwd: root).map(\.token), ["~/"])
    }
}
