import XCTest

final class ShellEditLineTests: XCTestCase {
    private func mirror(_ line: String) -> String {
        ShellEditLine.sentinel + line
    }

    func testParsesMirroredBufferIncludingURLsWithQueryStrings() {
        let line = "Help me download youtube video https://www.youtube.com/watch?v=bOC3DisEOfg as mp4 into ~/Downloads"
        XCTAssertEqual(ShellEditLine.parse(title: mirror(line)), line)
        XCTAssertEqual(PromptIntentClassifier.submission(for: line), .agent(line))
    }

    func testEmptyBufferParsesAsEmptyNotNil() {
        XCTAssertEqual(ShellEditLine.parse(title: mirror("")), "")
        XCTAssertEqual(PromptIntentClassifier.submission(for: ""), .shell)
    }

    func testOrdinaryTitlesAreNotMirrors() {
        for title in ["sora", "git status", "~/repos/sora", ""] {
            XCTAssertNil(ShellEditLine.parse(title: title), title)
            XCTAssertFalse(ShellEditLine.isMirror(title: title), title)
        }
    }

    func testMirroredLineIsNotPollutedByPreviousScreenText() {
        // Regression: scraping the grid glued the previous (cancelled) line onto
        // the current one, producing "/agent " prefixes the user never typed.
        let previous = "/agent Help me download youtube video"
        let current = "Can you show me the largest files in this folder"
        XCTAssertEqual(ShellEditLine.parse(title: mirror(current)), current)
        XCTAssertNotEqual(ShellEditLine.parse(title: mirror(current)), previous + current)
    }

    func testMirroredCommandsStillRouteToShell() {
        for line in ["ls -la", "git status", "cd ~/repos/sora"] {
            let parsed = ShellEditLine.parse(title: mirror(line))
            XCTAssertEqual(parsed, line)
            XCTAssertEqual(PromptIntentClassifier.submission(for: parsed!), .shell, line)
        }
    }
}
