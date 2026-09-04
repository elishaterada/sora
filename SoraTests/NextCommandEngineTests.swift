import XCTest

final class NextCommandEngineTests: XCTestCase {
    func testPrefersSameCwdTransitionOverFrequency() {
        let cwd = URL(fileURLWithPath: "/tmp/project")
        let other = URL(fileURLWithPath: "/tmp/other")
        let now = Date(timeIntervalSince1970: 1_000)
        let suggestion = NextCommandEngine.suggest(
            previous: "git status",
            cwd: cwd,
            now: now,
            transitions: [
                TransitionStat(
                    next: "git push",
                    lastCwd: other,
                    frequency: 20,
                    lastUsed: now,
                    sameCwdCount: 0
                ),
                TransitionStat(
                    next: "git add -A",
                    lastCwd: cwd,
                    frequency: 2,
                    lastUsed: now.addingTimeInterval(-100),
                    sameCwdCount: 2
                ),
            ]
        )
        XCTAssertEqual(suggestion?.insertSuffix, "git add -A")
        XCTAssertEqual(suggestion?.source, .prediction)
        XCTAssertEqual(suggestion?.displayText, "→ git add -A")
    }

    func testEmptyPreviousYieldsNothing() {
        XCTAssertNil(
            NextCommandEngine.suggest(
                previous: "",
                cwd: URL(fileURLWithPath: "/tmp"),
                now: Date(),
                transitions: [
                    TransitionStat(
                        next: "ls",
                        lastCwd: URL(fileURLWithPath: "/tmp"),
                        frequency: 1,
                        lastUsed: Date(),
                        sameCwdCount: 1
                    ),
                ]
            )
        )
    }
}
