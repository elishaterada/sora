import Combine
import Foundation

enum WebpageError: LocalizedError {
    case invalidURL, http(Int), unsupported, tooLarge, empty, encoding
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter an HTTPS webpage address without a username or password."
        case .http(let code): return "The website returned HTTP \(code). Try another page."
        case .unsupported: return "This link is not an HTML or text page. Try a webpage instead."
        case .tooLarge: return "This page is too large to attach. Try a smaller page."
        case .empty: return "No readable text was found. This site may need JavaScript or a sign-in."
        case .encoding: return "This page uses an unsupported text encoding. Paste its text into Ask instead."
        }
    }
}

protocol WebpageFetching: Sendable {
    func fetch(_ address: String) async throws -> WebpageAttachment
}

struct WebpageFetcher: WebpageFetching {
    static let maxDownloadBytes = 2_000_000
    let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) { self.configuration = configuration }

    static func url(_ address: String) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var components = URLComponents(string: normalized),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              !trimmed.contains(where: { $0.isWhitespace }),
              isPublicHost(host),
              let url = components.url, url.host != nil else { throw WebpageError.invalidURL }
        components.fragment = nil
        return components.url ?? url
    }

    private static func isPublicHost(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"),
              host != "::1", !host.hasPrefix("fe80:"), !host.hasPrefix("fc"), !host.hasPrefix("fd") else {
            return false
        }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return true }
        switch (parts[0], parts[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): return false
        case (100, 64...127), (172, 16...31): return false
        default: return true
        }
    }

    func fetch(_ address: String) async throws -> WebpageAttachment {
        let url = try Self.url(address)
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: WebpageRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("text/html, text/plain;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("Sora/0.1 WebpagePreview", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebpageError.unsupported }
        guard (200..<300).contains(http.statusCode) else { throw WebpageError.http(http.statusCode) }
        let mime = http.mimeType?.lowercased()
        guard mime == "text/html" || mime == "application/xhtml+xml" || mime == "text/plain" else {
            throw WebpageError.unsupported
        }
        guard response.expectedContentLength <= Self.maxDownloadBytes else { throw WebpageError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maxDownloadBytes else { throw WebpageError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        let encoding: String.Encoding
        switch response.textEncodingName?.lowercased() {
        case nil, "utf-8", "utf8": encoding = .utf8
        case "iso-8859-1", "latin1": encoding = .isoLatin1
        case "windows-1252": encoding = .windowsCP1252
        case "us-ascii": encoding = .ascii
        default: throw WebpageError.encoding
        }
        guard let text = String(data: data, encoding: encoding) else { throw WebpageError.encoding }
        let finalURL = try Self.url((response.url ?? url).absoluteString)
        return try WebpageText.extract(text, url: finalURL, isHTML: mime != "text/plain")
    }
}

private final class WebpageRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? WebpageFetcher.url(url.absoluteString)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

@MainActor
final class WebpageLoader: ObservableObject {
    @Published private(set) var page: WebpageAttachment?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private let fetcher: any WebpageFetching
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(page: WebpageAttachment? = nil, fetcher: any WebpageFetching = WebpageFetcher()) {
        self.page = page
        self.fetcher = fetcher
    }

    func fetch(_ address: String) {
        reset()
        let token = generation
        isLoading = true
        let fetcher = fetcher
        task = Task { [weak self] in
            do {
                let page = try await fetcher.fetch(address)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.page = page
                self.isLoading = false
                self.task = nil
            } catch {
                guard let self, self.generation == token else { return }
                self.error = error.localizedDescription
                self.isLoading = false
                self.task = nil
            }
        }
    }

    func reset() {
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
        page = nil
        error = nil
    }

    deinit { task?.cancel() }
}
