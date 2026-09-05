import XCTest

final class PathLinkParserTests: XCTestCase {
    func testDetectsAbsoluteHomeAndRelativePaths() {
        let base = URL(fileURLWithPath: "/tmp")
        let text = "see /tmp/sora-test and ~/Downloads/file.txt plus Vendor/ghostty/README.md"
        // Relative path only links when it exists under base — create one.
        let relative = base.appendingPathComponent("Vendor/ghostty/README.md")
        try? FileManager.default.createDirectory(
            at: relative.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: relative.path, contents: Data("x".utf8))
        defer {
            try? FileManager.default.removeItem(at: base.appendingPathComponent("Vendor"))
        }

        let segments = PathLinkParser.segments(in: text, relativeTo: base)
        let paths = segments.compactMap { segment -> String? in
            if case .path(let label, _) = segment { return label }
            return nil
        }
        XCTAssertTrue(paths.contains("/tmp/sora-test") || paths.contains { $0.hasPrefix("/tmp") })
        XCTAssertTrue(paths.contains("~/Downloads/file.txt"))
        XCTAssertTrue(paths.contains("Vendor/ghostty/README.md"))
    }

    func testSkipsHTTPURLs() {
        let segments = PathLinkParser.segments(
            in: "open https://example.com/path and /usr/bin/true",
            relativeTo: nil
        )
        let labels = segments.compactMap { segment -> String? in
            if case .path(let label, _) = segment { return label }
            return nil
        }
        XCTAssertFalse(labels.contains(where: { $0.contains("https://") }))
        XCTAssertTrue(labels.contains("/usr/bin/true"))
    }

    func testResolveExpandsTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = PathActions.resolve("~/Library", relativeTo: nil)
        XCTAssertEqual(url?.path, home.appendingPathComponent("Library").path)
    }
}
