import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Resolves native file, image-data, and file-promise drops into durable local
/// paths. This layer never reads or writes the user's clipboard or sends input.
enum TerminalImageDrop {
    static let draggedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    enum DropError: LocalizedError {
        case unsupportedImage
        case unsafeFilename
        case multipleImages
        case remoteTransferRequired
        var errorDescription: String? {
            switch self {
            case .remoteTransferRequired: return "This image is on your Mac. Transfer it to the remote host before using its remote path."
            case .multipleImages: return "Drop one image at a time when pasting into a running program."
            case .unsupportedImage: return "The dropped item could not be read as an image."
            case .unsafeFilename: return "Rename the image to remove control characters before dropping it."
            }
        }
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static func promises(from pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []
    }

    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        let files = fileURLs(from: pasteboard)
        if !files.isEmpty {
            return files.allSatisfy { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        }
        let receivers = promises(from: pasteboard)
        if !receivers.isEmpty {
            return receivers.allSatisfy { !$0.fileTypes.isEmpty && $0.fileTypes.allSatisfy { UTType($0)?.conforms(to: .image) == true } }
        }
        return pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    static func validate(_ url: URL) throws {
        guard url.isFileURL,
              let image = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(image) > 0 else { throw DropError.unsupportedImage }
        _ = try quotedPath(url)
    }

    /// One path per paste event lets interactive CLIs recognize each image.
    /// Single quoting preserves spaces, Unicode, quotes, and shell metacharacters.
    static func quotedPath(_ url: URL) throws -> String {
        guard url.isFileURL else { throw DropError.unsupportedImage }
        guard !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DropError.unsafeFilename
        }
        return "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "' "
    }

    static func makeDestination(root: URL? = nil) throws -> URL {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.sora.app")
            .appendingPathComponent("Dropped Images", isDirectory: true)
        let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func saveImage(_ data: Data, root: URL? = nil) throws -> URL {
        guard let image = NSBitmapImageRep(data: data),
              let png = image.representation(using: .png, properties: [:]) else { throw DropError.unsupportedImage }
        let directory = try makeDestination(root: root)
        let url = directory.appendingPathComponent("Dropped Image.png")
        do { try png.write(to: url, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        return url
    }

    /// File promises may finish after the drag ends; the caller keeps the target
    /// session fixed and receives failures rather than silently dropping them.
    static func receive(_ pasteboard: NSPasteboard, allowsMultiple: Bool = true, completion: @escaping (Result<[URL], Error>) -> Void) {
        let files = fileURLs(from: pasteboard)
        if !files.isEmpty {
            guard allowsMultiple || files.count == 1 else { completion(.failure(DropError.multipleImages)); return }
            do { try files.forEach(validate); completion(.success(files)) }
            catch { completion(.failure(error)) }
            return
        }
        let receivers = promises(from: pasteboard)
        if !receivers.isEmpty {
            guard allowsMultiple || (receivers.count == 1 && receivers[0].fileTypes.count == 1) else {
                completion(.failure(DropError.multipleImages)); return
            }
            do {
                let directory = try makeDestination()
                for receiver in receivers {
                    receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: .main) { url, error in
                        if let error { completion(.failure(error)); return }
                        do { try validate(url); completion(.success([url])) }
                        catch { completion(.failure(error)) }
                    }
                }
            } catch { completion(.failure(error)) }
            return
        }
        do {
            guard let type = pasteboard.availableType(from: [.png, .tiff]),
                  let data = pasteboard.data(forType: type) else { throw DropError.unsupportedImage }
            completion(.success([try saveImage(data)]))
        } catch { completion(.failure(error)) }
    }
}
