import XCTest

final class PromptIntentClassifierTests: XCTestCase {
    func testDetectsClearlyConversationalInput() {
        for line in [
            "Help me find a large files",
            "how can I find the largest files?",
            "Summarize what this website is about",
            "Could you explain this error message",
            "What does git rebase do?",
            "¿how can I inspect this log?"
        ] {
            XCTAssertEqual(PromptIntentClassifier.intent(for: line), .agent, line)
            XCTAssertEqual(PromptIntentClassifier.submission(for: line), .agent(line), line)
        }
    }

    func testRoutesCommandsAndAmbiguousInputToShell() {
        for line in [
            "ls -la", "git status?", "find . -type f | head", "FOO=bar make test",
            "./deploy production now", "~/bin/tool with arguments", "kubectl get pods in production",
            "echo 'how can I help?'", "release production today", "two words", "/agent"
        ] {
            XCTAssertEqual(PromptIntentClassifier.intent(for: line), .shell, line)
            XCTAssertEqual(PromptIntentClassifier.submission(for: line), .shell, line)
        }
    }

    func testAgentPrefixForcesCommandLikeQuestionsToAIAndIsStripped() {
        XCTAssertEqual(PromptIntentClassifier.submission(for: "/agent git status"), .agent("git status"))
        XCTAssertEqual(PromptIntentClassifier.submission(for: " /AGENT   ls -la "), .agent("ls -la"))
    }

    func testCommandReturnOverridesAIDetection() {
        XCTAssertEqual(PromptIntentClassifier.submission(for: "Help me find files", forceShell: true), .shell)
        XCTAssertEqual(PromptIntentClassifier.submission(for: "/agent explain pwd", forceShell: true), .shell)
    }
}
