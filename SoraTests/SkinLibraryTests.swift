import AppKit
import AVFoundation
import XCTest

final class SkinLibraryTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sora-skins-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func photo(at url: URL) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 60,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
    @MainActor func testCopiesPhotoSurvivesSourceDeletionAndRelaunchThenRemovesOwnedCopy() async throws {
        let root = try fixture(), source = root.appendingPathComponent("photo.png")
        try photo(at: source)
        let original = try Data(contentsOf: source)
        let library = SkinLibrary(root: root.appendingPathComponent("library"), startsTimer: false)
        let skin = try await library.add(source)
        XCTAssertEqual(skin.kind, .photo)
        XCTAssertEqual(library.configuration.selectedID, skin.id)
        XCTAssertTrue(library.configuration.enabled)
        XCTAssertNotEqual(source, library.url(for: skin))
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: library.url(for: skin)), original)
        XCTAssertNotNil(NSImage(contentsOf: library.posterURL(for: skin)))
        library.update { $0.readability = 0.85; $0.perspective = true; $0.rotationSeconds = 60 }
        let reopened = SkinLibrary(root: library.root, startsTimer: false)
        XCTAssertEqual(reopened.configuration, library.configuration)
        reopened.remove(skin)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.url(for: skin).path))
        XCTAssertTrue(reopened.configuration.skins.isEmpty)
        XCTAssertFalse(reopened.configuration.enabled)
    }
    @MainActor func testRejectsCorruptAndSymlinkMediaWithoutPublishingOrLeavingStagingFiles() async throws {
        let root = try fixture(), source = root.appendingPathComponent("bad.png")
        try Data("not an image".utf8).write(to: source)
        let library = SkinLibrary(root: root.appendingPathComponent("library"), startsTimer: false)
        do { try await library.add(source); XCTFail("Accepted corrupt media") } catch { }
        XCTAssertTrue(library.configuration.skins.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.root.path), [])
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        do { try await library.add(link); XCTFail("Accepted symlink") } catch { }
    }
    @MainActor func testCorruptCatalogIsPreservedAndSaveFailureDoesNotPublishChanges() throws {
        let root = try fixture(), manifest = root.appendingPathComponent("library.json")
        let invalid = Data("invalid catalog".utf8)
        try invalid.write(to: manifest)
        let library = SkinLibrary(root: root, startsTimer: false)
        XCTAssertTrue(library.loadFailed)
        library.update { $0.readability = 0.9 }
        XCTAssertEqual(try Data(contentsOf: manifest), invalid)
        let blocker = root.appendingPathComponent("file")
        try Data().write(to: blocker)
        let unavailable = SkinLibrary(root: blocker, startsTimer: false)
        unavailable.update { $0.readability = 0.9 }
        XCTAssertEqual(unavailable.configuration.readability, 0.65)
        XCTAssertNotNil(unavailable.errorMessage)
    }
    @MainActor func testInvalidCatalogCannotActivateUnvalidatedMedia() throws {
        let root = try fixture()
        let invalid = TerminalSkin(id: UUID(), name: "Invalid", filename: "../../outside.mp4", kind: .video, hasAudio: true)
        let config = SkinConfiguration(skins: [invalid, invalid], selectedID: invalid.id, enabled: true)
        try JSONEncoder().encode(config).write(to: root.appendingPathComponent("library.json"))
        let library = SkinLibrary(root: root, startsTimer: false)
        XCTAssertTrue(library.loadFailed)
        XCTAssertTrue(library.configuration.skins.isEmpty)
        XCTAssertFalse(library.configuration.enabled)
    }

    func testRotationSkipsElapsedIntervalsAndPreservesDisabledSelection() {
        let a = TerminalSkin(id: UUID(), name: "A", filename: "original.png", kind: .photo, hasAudio: false)
        let b = TerminalSkin(id: UUID(), name: "B", filename: "original.mp4", kind: .video, hasAudio: true)
        let anchor = Date(timeIntervalSince1970: 1000)
        var config = SkinConfiguration(skins: [a, b], selectedID: a.id, enabled: true, rotationSeconds: 60, rotationAnchor: anchor)
        config.rotate(at: anchor.addingTimeInterval(59)); XCTAssertEqual(config.selectedID, a.id)
        config.rotate(at: anchor.addingTimeInterval(180)); XCTAssertEqual(config.selectedID, b.id)
        config.enabled = false
        config.rotate(at: anchor.addingTimeInterval(240)); XCTAssertEqual(config.selectedID, b.id)
        config.readability = .nan; config.rotationSeconds = -1; config.normalize()
        XCTAssertEqual(config.readability, 0.65); XCTAssertEqual(config.rotationSeconds, 0)
    }
    func testClipRequestValidatesTimeRangeAndRequiresHTTPS() throws {
        let prompt = try XCTUnwrap(SkinClipRequest.prompt(source: "https://www.youtube.com/watch?v=sample", start: "12.5", end: "27"))
        XCTAssertTrue(prompt.contains("12.5 through 27.0")); XCTAssertTrue(prompt.contains("importSkin"))
        for range in [("-1", "10"), ("10", "5"), ("0", "301"), ("nan", "10"), ("1:00", "2:00")] {
            XCTAssertNil(SkinClipRequest.prompt(source: "https://example.com/v", start: range.0, end: range.1))
        }
        XCTAssertNil(SkinClipRequest.prompt(source: "file:///etc/passwd", start: "0", end: "10"))
        XCTAssertEqual(SkinClipRequest.validationError(source: "https://example.com", start: "10", end: "5"), "End must be later than start.")
        XCTAssertTrue(SkinClipRequest.validationError(source: "https://example.com", start: "0", end: "301")!.contains("300 seconds"))
    }
    func testAgentImportIsMutatingAndNeverAutoApproved() throws {
        let call = try XCTUnwrap(AgentToolCall.parse("<SORA_TOOL>{\"tool\":\"importSkin\",\"summary\":\"Use clip\",\"path\":\"clip.mp4\"}</SORA_TOOL>"))
        let directory = URL(fileURLWithPath: "/tmp")
        XCTAssertEqual(call.tool.replaySafety, .potentiallyMutating)
        for mode in [AgentPermissionMode.askForApproval, .approveForMe, .fullAccess] {
            XCTAssertFalse(call.canRunAutomatically(mode: mode, directory: directory, grants: [call.identity(directory: directory)]))
        }
    }
}
