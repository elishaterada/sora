import Foundation
import XCTest

final class AgentMarkdownTests: XCTestCase {
    func testInstructionsAskForMarkdownInNormalAnswers() {
        XCTAssertTrue(AIRequest.instructions.contains("GitHub-flavored Markdown"))
        XCTAssertTrue(AIRequest.instructions.contains("`inline code`"))
        // Envelopes must remain Markdown-free.
        XCTAssertTrue(AIRequest.instructions.contains("no Markdown or other text"))
    }

    func testRendersHeadingsListsAndInlineCode() throws {
        let source = """
        ## What it offers
        - First item
        - Second item

        Run `pwd` in the project root.
        """
        let attributed = try XCTUnwrap(AgentMarkdown.attributed(source))
        let plain = String(attributed.characters)
        XCTAssertTrue(plain.contains("What it offers"))
        XCTAssertTrue(plain.contains("First item"))
        XCTAssertTrue(plain.contains("pwd"))

        var sawCode = false
        var sawHeader = false
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                sawCode = true
            }
            if let intent = run.presentationIntent {
                for component in intent.components {
                    if case .header = component.kind {
                        sawHeader = true
                    }
                }
            }
        }
        XCTAssertTrue(sawCode)
        XCTAssertTrue(sawHeader)
    }

    func testBlocksAreSeparatedInsteadOfRunningTogether() throws {
        // Regression: Foundation emits no newline between blocks, so rendering
        // one AttributedString produced "…merged MP4.Files created in…".
        let source = """
        The download succeeded, but **not as a single merged MP4**.

        Files created in `~/Downloads`:
        - video.mp4 — video-only
        - audio.webm — audio-only
        """
        let blocks = try XCTUnwrap(AgentMarkdown.blocks(source))
        XCTAssertEqual(blocks.count, 4)

        let first = String(blocks[0].text.characters)
        XCTAssertTrue(first.hasSuffix("merged MP4."), first)
        XCTAssertFalse(first.contains("Files created"), first)

        XCTAssertEqual(blocks[2].kind, .listItem(marker: "•", depth: 1))
        XCTAssertEqual(String(blocks[2].text.characters), "video.mp4 — video-only")
    }

    func testHeadingListAndCodeBlockKinds() throws {
        let source = """
        ## Result

        1. First
        2. Second

        ```
        yt-dlp --version
        ffmpeg -version
        ```
        """
        let blocks = try XCTUnwrap(AgentMarkdown.blocks(source))
        XCTAssertEqual(blocks.first?.kind, .heading(level: 2))
        XCTAssertEqual(blocks[1].kind, .listItem(marker: "1.", depth: 1))
        XCTAssertEqual(blocks[2].kind, .listItem(marker: "2.", depth: 1))

        let code = try XCTUnwrap(blocks.last)
        XCTAssertEqual(code.kind, .codeBlock)
        // Fenced content keeps its interior newlines.
        XCTAssertEqual(String(code.text.characters), "yt-dlp --version\nffmpeg -version")
    }

    func testInlineCodeIsColoredRatherThanHighlighted() throws {
        let attributed = try XCTUnwrap(AgentMarkdown.attributed("Install `ffmpeg` first."))
        var sawInlineCode = false
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            sawInlineCode = true
            XCTAssertNil(run.backgroundColor)
            XCTAssertEqual(run.foregroundColor, SoraTheme.nsCodeInline)
        }
        XCTAssertTrue(sawInlineCode)
    }

    func testLinksMentionedPathsButNotCommandsOrFencedBlocks() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sora-markdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let clip = base.appendingPathComponent("My Clip.mp4")
        try Data().write(to: clip)

        let source = """
        Merged into `\(clip.path)`.

        Files landed in \(base.path): open it to check.

        Install `ffmpeg` first, then read the [docs](https://example.com).

        ```
        ls \(base.path)
        ```
        """
        let attributed = try XCTUnwrap(AgentMarkdown.attributed(source, relativeTo: base))

        var links: [(text: String, target: String)] = []
        for run in attributed.runs {
            guard let link = run.link else { continue }
            links.append((String(attributed[run.range].characters), link.isFileURL ? link.path : link.absoluteString))
        }

        // A code span is one token, so a path containing spaces still resolves.
        XCTAssertEqual(links.filter { $0.text == clip.path }.map(\.target), [clip.path])
        // Prose match drops the sentence colon from the link.
        XCTAssertEqual(links.filter { $0.text == base.path }.map(\.target), [base.path])
        XCTAssertFalse(links.contains { $0.text == "ffmpeg" })
        XCTAssertTrue(links.contains { $0.target == "https://example.com" })
        // Two paths plus the Markdown link: the fenced block stays plain.
        XCTAssertEqual(links.count, 3)
    }

    func testMissingPathsStayPlainTextSoLinksNeverDeadEnd() throws {
        let missing = "/Users/nobody/does-not-exist-\(UUID().uuidString)/report.md"
        let attributed = try XCTUnwrap(AgentMarkdown.attributed("Wrote `\(missing)` and \(missing)."))
        XCTAssertFalse(attributed.runs.contains { $0.link != nil })
    }

    func testOnlyBlocksWithLinksGiveUpTextSelection() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sora-markdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let source = """
        Plain paragraph with no path.

        Output landed in \(base.path).

        ```
        ls \(base.path)
        ```
        """
        let blocks = try XCTUnwrap(AgentMarkdown.blocks(source, relativeTo: base))
        XCTAssertEqual(blocks.map(\.hasLinks), [false, true, false])
    }

    func testPathLinksAreSkippedWithoutAWorkingDirectory() throws {
        let attributed = try XCTUnwrap(AgentMarkdown.attributed("See `build/output.log` for details."))
        XCTAssertFalse(attributed.runs.contains { $0.link != nil })
    }

    func testStreamingPrefersInlineParseOverBlanking() {
        // Unclosed fence should still yield visible text while streaming.
        let partial = "Here is a command:\n```\npwd"
        let attributed = AgentMarkdown.attributed(partial, streaming: true)
        XCTAssertNotNil(attributed)
        XCTAssertTrue(String(attributed!.characters).contains("pwd"))
    }
}
