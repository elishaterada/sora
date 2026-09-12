import Foundation

enum SkinClipRequest {
    static func validationError(source: String, start: String, end: String) -> String? {
        guard let url = URL(string: source.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil else {
            return "Enter a complete HTTPS video link."
        }
        guard let from = Double(start), let to = Double(end), from.isFinite, to.isFinite, from >= 0 else {
            return "Enter times in seconds, such as 12.5 and 30."
        }
        guard to > from else { return "End must be later than start." }
        guard to - from <= 300 else { return "Choose a clip of five minutes (300 seconds) or less." }
        return nil
    }
    static func prompt(source: String, start: String, end: String) -> String? {
        guard validationError(source: source, start: start, end: end) == nil,
              let url = URL(string: source.trimmingCharacters(in: .whitespacesAndNewlines)),
              let from = Double(start), let to = Double(end) else { return nil }
        return """
        Create a terminal video skin from \(url.absoluteString), keeping seconds \(from) through \(to) (duration \(to - from) seconds). Keep any audio track but import it muted. Use a unique working folder so no existing files are overwritten. Check available tools, download and trim the clip with accurate cuts, verify the resulting duration and playable video, then use the native importSkin tool to copy it into Sora's library and select it. Ask for approval for downloads, installs, and file changes. Do not change my skin catalog with shell commands.
        """
    }
}
