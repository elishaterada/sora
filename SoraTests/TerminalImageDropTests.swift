import AppKit
import XCTest

final class TerminalImageDropTests: XCTestCase {
    func testQuotedPathsRoundTripThroughShellWithoutEvaluation() throws {
        let paths = ["/tmp/reference image.png", "/tmp/日本語's $HOME `echo no`;.png", "/tmp/a\\b.png"]
        for path in paths {
            let quoted = try TerminalImageDrop.quotedPath(URL(fileURLWithPath: path))
            let pipe = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-c", "printf '%s' " + quoted]
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), path)
        }
    }

    func testControlCharactersAndRemoteURLsAreRejected() {
        for path in ["/tmp/new\nline.png", "/tmp/tab\timage.png", "/tmp/escape\u{1B}.png"] {
            XCTAssertThrowsError(try TerminalImageDrop.quotedPath(URL(fileURLWithPath: path)))
        }
        XCTAssertThrowsError(try TerminalImageDrop.quotedPath(URL(string: "https://example.com/image.png")!))
    }

    func testImageDataSavedToUniqueDurableFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        let first = try TerminalImageDrop.saveImage(data, root: root)
        let second = try TerminalImageDrop.saveImage(data, root: root)
        XCTAssertNotEqual(first, second)
        try TerminalImageDrop.validate(first)
        try TerminalImageDrop.validate(second)
        XCTAssertThrowsError(try TerminalImageDrop.saveImage(Data("invalid".utf8), root: root))
        XCTAssertThrowsError(try TerminalImageDrop.validate(root.appendingPathComponent("missing.png")))
    }

    func testFinderFilesKeepOrderAndRejectMixedNonImageDrops() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let first = URL(fileURLWithPath: "/tmp/first image.png")
        let second = URL(fileURLWithPath: "/tmp/second.jpg")
        board.writeObjects([first as NSURL, second as NSURL])
        XCTAssertTrue(TerminalImageDrop.canRead(board))
        XCTAssertEqual(TerminalImageDrop.fileURLs(from: board), [first, second])
        board.clearContents()
        board.writeObjects([first as NSURL, URL(fileURLWithPath: "/tmp/note.txt") as NSURL])
        XCTAssertFalse(TerminalImageDrop.canRead(board))
        board.clearContents()
        board.setString("https://example.com/image.png", forType: .string)
        XCTAssertFalse(TerminalImageDrop.canRead(board))
    }

    func testMissingImageReportsFailureRatherThanPastingADeadPath() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([URL(fileURLWithPath: "/tmp/\(UUID().uuidString).png") as NSURL])
        var failed = false
        TerminalImageDrop.receive(board) { result in
            if case .failure = result { failed = true }
        }
        XCTAssertTrue(failed)
    }
    func testBinaryClipboardRemainsReadableWithoutTheSourceFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        let file = try TerminalImageDrop.saveImage(data, root: root)
        try GhosttyClipboard.writeImage(at: file, to: board)
        try FileManager.default.removeItem(at: root)
        XCTAssertNil(board.string(forType: .string))
        XCTAssertNil(board.string(forType: .fileURL))
        XCTAssertTrue(GhosttyClipboard.hasImage(in: board))
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            let pixels = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(board.data(forType: type))))
            XCTAssertEqual(pixels.pixelsWide, 3)
            XCTAssertEqual(pixels.pixelsHigh, 2)
        }
    }

    func testBinaryModeRejectsMultipleImagesBeforeChangingTheClipboard() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([URL(fileURLWithPath: "/tmp/one.png") as NSURL,
                            URL(fileURLWithPath: "/tmp/two.png") as NSURL])
        let changeCount = board.changeCount
        var rejected = false
        TerminalImageDrop.receive(board, allowsMultiple: false) { result in
            if case .failure(TerminalImageDrop.DropError.multipleImages) = result { rejected = true }
        }
        XCTAssertTrue(rejected)
        XCTAssertEqual(board.changeCount, changeCount)
    }

}
