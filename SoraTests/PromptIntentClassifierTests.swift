import XCTest

final class PromptIntentClassifierTests: XCTestCase {
    /// Deterministic PATH for classifier tests — never depend on the host.
    private let known: (String) -> Bool = { line in
        let command = ShellCommandResolver.primaryCommand(in: line) ?? ""
        return ["ls", "git", "find", "echo", "kubectl", "make", "cd"].contains(command)
            || ShellCommandResolver.builtins.contains(command)
    }

    private let none: (String) -> Bool = { _ in false }

    func testDetectsClearlyConversationalInput() {
        for line in [
            "Help me find a large files",
            "how can I find the largest files?",
            "how many swift files are in this repo",
            "How much disk space is free",
            "how long does a clean build take",
            "Summarize what this website is about",
            "Could you explain this error message",
            "What does git rebase do?",
            "¿how can I inspect this log?"
        ] {
            XCTAssertEqual(
                PromptIntentClassifier.intent(for: line, commandExists: known),
                .agent,
                line
            )
            XCTAssertEqual(
                PromptIntentClassifier.submission(for: line, commandExists: known),
                .agent(line),
                line
            )
        }
    }

    func testUnknownCommandsRouteToAgentAsCatchAll() {
        for line in [
            "two words",
            "release production today",
            "yt-dlp https://example.com",
            "npm install",
            "how many swift files are in this repo"
        ] {
            XCTAssertEqual(
                PromptIntentClassifier.intent(for: line, commandExists: none),
                .agent,
                line
            )
            XCTAssertEqual(
                PromptIntentClassifier.submission(for: line, commandExists: none),
                .agent(line),
                line
            )
        }
    }

    func testKnownCommandsAndShellSyntaxStayOnShell() {
        for line in [
            "ls -la",
            "git status?",
            "find . -type f | head",
            "FOO=bar make test",
            "./deploy production now",
            "~/bin/tool with arguments",
            "kubectl get pods in production",
            "echo 'how can I help?'",
            "cd ~/repos/sora"
        ] {
            XCTAssertEqual(
                PromptIntentClassifier.intent(for: line, commandExists: known),
                .shell,
                line
            )
            XCTAssertEqual(
                PromptIntentClassifier.submission(for: line, commandExists: known),
                .shell,
                line
            )
        }
    }

    func testEmptyAndBareAgentPrefixStayShell() {
        XCTAssertEqual(PromptIntentClassifier.intent(for: "", commandExists: known), .shell)
        XCTAssertEqual(PromptIntentClassifier.submission(for: "/agent", commandExists: known), .shell)
    }

    func testAgentPrefixForcesCommandLikeQuestionsToAIAndIsStripped() {
        XCTAssertEqual(
            PromptIntentClassifier.submission(for: "/agent git status", commandExists: known),
            .agent("git status")
        )
        XCTAssertEqual(
            PromptIntentClassifier.submission(for: " /AGENT   ls -la ", commandExists: known),
            .agent("ls -la")
        )
    }

    func testCommandReturnOverridesAIDetection() {
        XCTAssertEqual(
            PromptIntentClassifier.submission(
                for: "Help me find files",
                forceShell: true,
                commandExists: none
            ),
            .shell
        )
        XCTAssertEqual(
            PromptIntentClassifier.submission(
                for: "/agent explain pwd",
                forceShell: true,
                commandExists: none
            ),
            .shell
        )
    }

    func testExplicitAgentSurvivesStalePromptReadiness() {
        XCTAssertEqual(
            PromptIntentClassifier.submission(
                for: "/agent Help me download this URL",
                allowImplicitAgent: false,
                commandExists: none
            ),
            .agent("Help me download this URL")
        )
        XCTAssertEqual(
            PromptIntentClassifier.submission(
                for: "Help me download this URL",
                allowImplicitAgent: false,
                commandExists: none
            ),
            .shell
        )
        // Catch-all must not fire when implicit agent is disabled.
        XCTAssertEqual(
            PromptIntentClassifier.submission(
                for: "missing-tool --help",
                allowImplicitAgent: false,
                commandExists: none
            ),
            .shell
        )
    }
}
