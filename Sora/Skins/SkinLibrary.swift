import AppKit
import AVFoundation
import Combine
import ImageIO
import UniformTypeIdentifiers

struct TerminalSkin: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case photo, video }
    let id: UUID
    var name: String
    let filename: String
    let kind: Kind
    let hasAudio: Bool
    var muted = true
}

struct SkinConfiguration: Codable, Equatable, Sendable {
    var skins: [TerminalSkin] = []
    var selectedID: UUID?
    var enabled = false
    var readability = 0.65
    var extendImage = true
    var perspective = false
    var rotationSeconds: Double = 0
    var rotationAnchor = Date()

    static let intervals: [Double] = [0, 60, 300, 900, 1800, 3600, 86400]
    var selected: TerminalSkin? { skins.first { $0.id == selectedID } }
    mutating func normalize() {
        readability = readability.isFinite ? min(0.95, max(0.25, readability)) : 0.65
        if !Self.intervals.contains(rotationSeconds) { rotationSeconds = 0 }
        if selected == nil { selectedID = skins.first?.id }
        if skins.isEmpty { enabled = false }
    }
    mutating func rotate(at date: Date) {
        guard enabled, rotationSeconds > 0, skins.count > 1 else { return }
        let elapsed = date.timeIntervalSince(rotationAnchor)
        guard elapsed >= rotationSeconds, elapsed.isFinite else { return }
        let steps = floor(elapsed / rotationSeconds)
        let index = skins.firstIndex { $0.id == selectedID } ?? 0
        selectedID = skins[(index + Int(steps.truncatingRemainder(dividingBy: Double(skins.count)))) % skins.count].id
        rotationAnchor = date
    }
}

/// One app-owned library, shared by windows and agent sessions. Originals never depend on source URLs.
@MainActor
final class SkinLibrary: ObservableObject {
    @Published private(set) var configuration = SkinConfiguration()
    @Published var errorMessage: String?
    @Published private(set) var importing = false
    private(set) var loadFailed = false
    let root: URL
    private var timer: AnyCancellable?

    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.sora", isDirectory: true)
        .appendingPathComponent("Skins", isDirectory: true), startsTimer: Bool = true) {
        self.root = root
        do {
            let manifest = root.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: manifest.path) {
                var restored = try JSONDecoder().decode(SkinConfiguration.self, from: Data(contentsOf: manifest))
                guard Set(restored.skins.map(\.id)).count == restored.skins.count,
                      restored.skins.allSatisfy({ $0.filename == "original." + URL(fileURLWithPath: $0.filename).pathExtension && !$0.filename.contains("/") }) else {
                    throw Self.failure("The skin catalog contains invalid entries.")
                }
                restored.normalize()
                configuration = restored
            }
        } catch { loadFailed = true; errorMessage = "Could not open the skin library: \(error.localizedDescription)" }
        if startsTimer {
            timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect().sink { [weak self] date in
                guard let self else { return }
                var next = self.configuration
                next.rotate(at: date)
                if next != self.configuration { self.save(next) }
            }
        }
    }

    func url(for skin: TerminalSkin) -> URL { folder(for: skin.id).appendingPathComponent(skin.filename) }
    func posterURL(for skin: TerminalSkin) -> URL { folder(for: skin.id).appendingPathComponent("poster.jpg") }
    private func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func update(_ change: (inout SkinConfiguration) -> Void) {
        var next = configuration; change(&next); next.normalize(); save(next)
    }
    func select(_ id: UUID) { update { $0.selectedID = id; $0.enabled = true; $0.rotationAnchor = Date() } }
    @discardableResult private func save(_ next: SkinConfiguration) -> Bool {
        guard !loadFailed else { return false }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: root.appendingPathComponent("library.json"), options: .atomic)
            configuration = next; errorMessage = nil
            return true
        } catch { errorMessage = "Could not save skins: \(error.localizedDescription)"; return false }
    }
    func remove(_ skin: TerminalSkin) {
        var next = configuration
        next.skins.removeAll { $0.id == skin.id }; next.normalize()
        guard save(next) else { return }
        do { try FileManager.default.removeItem(at: folder(for: skin.id)) }
        catch { errorMessage = "Skin removed from the library, but its stored file could not be deleted: \(error.localizedDescription)" }
    }
    @discardableResult func add(_ source: URL) async throws -> TerminalSkin {
        guard !loadFailed, !importing else { throw Self.failure("The skin library is unavailable or already importing a file.") }
        importing = true
        defer { importing = false }
        let root = root
        let work = Task.detached(priority: .userInitiated) { try await SkinImporter.copy(source, to: root) }
        let skin = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        do {
            try Task.checkCancellation()
            var next = configuration
            next.skins.append(skin); next.selectedID = skin.id; next.enabled = true; next.rotationAnchor = Date()
            guard save(next) else { throw Self.failure(errorMessage ?? "Could not save the skin.") }
            return skin
        } catch {
            try? FileManager.default.removeItem(at: folder(for: skin.id))
            throw error
        }
    }
    nonisolated static func failure(_ message: String) -> NSError {
        NSError(domain: "Sora.Skin", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private enum SkinImporter {
    static func copy(_ source: URL, to root: URL) async throws -> TerminalSkin {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentTypeKey])
        guard source.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 2_000_000_000 else {
            throw SkinLibrary.failure("Choose a regular photo or video file smaller than 2 GB.")
        }
        let isVideo = values.contentType?.conforms(to: .movie) == true
        guard isVideo || values.contentType?.conforms(to: .image) == true else {
            throw SkinLibrary.failure("Choose a supported image or movie, such as JPEG, PNG, HEIC, MP4 or MOV.")
        }
        let id = UUID(), folder = root.appendingPathComponent(UUID().uuidString)
        // Stage outside the catalog; publish a complete folder only after decoding succeeds.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let filename = "original." + source.pathExtension.lowercased()
        let destination = folder.appendingPathComponent(filename)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            try Task.checkCancellation()
            let poster: CGImage
            var hasAudio = false
            if isVideo {
                let asset = AVURLAsset(url: destination)
                guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                    throw SkinLibrary.failure("This video cannot be played by macOS. Export it as an H.264 MP4 and try again.")
                }
                hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 2560, height: 2560)
                poster = try await generator.image(at: .zero).image
            } else {
                guard let image = CGImageSourceCreateWithURL(destination as CFURL, nil),
                      let decoded = CGImageSourceCreateThumbnailAtIndex(image, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2560
                      ] as CFDictionary) else { throw SkinLibrary.failure("This image could not be decoded.") }
                poster = decoded
            }
            guard let output = CGImageDestinationCreateWithURL(folder.appendingPathComponent("poster.jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw SkinLibrary.failure("Could not create the skin preview.")
            }
            CGImageDestinationAddImage(output, poster, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(output) else { throw SkinLibrary.failure("Could not save the skin preview.") }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent(id.uuidString))
            return TerminalSkin(id: id, name: source.deletingPathExtension().lastPathComponent, filename: filename,
                                kind: isVideo ? .video : .photo, hasAudio: hasAudio)
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
}
