import Foundation
import Darwin

/// Private, local transport between the command's PTY and a libghostty surface.
/// nc supplies a byte stream inside Ghostty's PTY; it does not interpret keys or
/// output. Both directions are bounded and nonblocking. Closing a view only
/// disconnects that viewer; it never restarts or cancels the approved command.
final class AgentTerminalRelay: @unchecked Sendable {
    let directory: URL
    let socketPath: String
    var ttyPathFile: String { directory.appendingPathComponent("tty").path }
    private let lock = NSLock()
    private var stopped = false
    private var history = Data()
    private var pendingOutput = Data()
    private var connected = false
    private let listener: Int32
    private let input: @Sendable (Data) -> Int

    init(input: @escaping @Sendable (Data) -> Int) throws {
        self.input = input
        directory = URL(fileURLWithPath: "/tmp/sora-" + UUID().uuidString)
        socketPath = directory.appendingPathComponent("terminal").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(.EIO)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = socketPath.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(listener)
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(.ENAMETOOLONG)
        }
        _ = withUnsafeMutableBytes(of: &address.sun_path) { target in
            bytes.withUnsafeBytes { source in memcpy(target.baseAddress!, source.baseAddress!, source.count) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(listener)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        Self.configure(listener)
        DispatchQueue.global(qos: .userInitiated).async { [self] in serve() }
    }

    private static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        history.append(data)
        if history.count > 262_144 { history.removeFirst(history.count - 262_144) }
        guard connected else { return }
        pendingOutput.append(data)
        if pendingOutput.count > 524_288 {
            // A stalled viewer cannot grow application memory without bound.
            pendingOutput = Data("\u{1b}[0m\u{1b}[2J\u{1b}[H[Terminal display caught up; earlier output omitted]\r\n".utf8) + history
        }
    }

    func close() {
        lock.lock(); stopped = true; lock.unlock()
    }

    func resize(columns: UInt16, rows: UInt16) {
        guard columns > 0, rows > 0,
              let path = try? String(contentsOfFile: ttyPathFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              path.range(of: #"^/dev/ttys[0-9]+$"#, options: .regularExpression) != nil else { return }
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, TIOCSWINSZ, &size)
    }

    private func serve() {
        var client: Int32 = -1
        var pendingInput = Data()
        defer {
            if client >= 0 { Darwin.close(client) }
            Darwin.close(listener)
            try? FileManager.default.removeItem(at: directory)
        }
        while true {
            lock.lock()
            let done = stopped
            let hasOutput = !pendingOutput.isEmpty
            lock.unlock()
            if done { return }
            var descriptors = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0)]
            if client >= 0 {
                let events = (pendingInput.count < 65_536 ? POLLIN : 0) | (hasOutput ? POLLOUT : 0)
                descriptors.append(pollfd(fd: client, events: Int16(events), revents: 0))
            }
            _ = poll(&descriptors, nfds_t(descriptors.count), 20)
            if descriptors[0].revents & Int16(POLLIN) != 0 {
                let accepted = accept(listener, nil, nil)
                if accepted >= 0 {
                    if client >= 0 { Darwin.close(accepted) }
                    else {
                        client = accepted
                        Self.configure(client)
                        lock.lock()
                        connected = true
                        pendingOutput = Data("\u{1b}[0m\u{1b}[2J\u{1b}[H".utf8) + history
                        lock.unlock()
                    }
                }
            }
            guard client >= 0 else { continue }
            var disconnected = false
            if descriptors.count > 1 {
                let events = descriptors[1].revents
                if events & Int16(POLLIN) != 0 {
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    let count = Darwin.read(client, &bytes, bytes.count)
                    if count > 0 { pendingInput.append(contentsOf: bytes.prefix(count)) }
                    else if count == 0 || (errno != EAGAIN && errno != EINTR) { disconnected = true }
                }
                if events & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { disconnected = true }
                if events & Int16(POLLOUT) != 0 {
                    lock.lock()
                    let count = pendingOutput.withUnsafeBytes { Darwin.write(client, $0.baseAddress, min($0.count, 32_768)) }
                    if count > 0 { pendingOutput.removeFirst(count) }
                    else if count < 0 && errno != EAGAIN && errno != EINTR { disconnected = true }
                    lock.unlock()
                }
            }
            if !pendingInput.isEmpty {
                let count = input(Data(pendingInput.prefix(512)))
                if count > 0 { pendingInput.removeFirst(count) }
                else if count < 0 { disconnected = true }
            }
            if disconnected {
                Darwin.close(client)
                client = -1
                pendingInput.removeAll()
                lock.lock()
                connected = false
                pendingOutput.removeAll()
                lock.unlock()
            }
        }
    }
}
