import XCTest

final class SoraZshBootstrapTests: XCTestCase {
    func testInstallsDotZshenvFromSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sora-zsh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("zshenv")
        try "# sora\n".write(to: source, atomically: true, encoding: .utf8)
        let zdot = root.appendingPathComponent("zdot", isDirectory: true)
        let installed = try SoraZshBootstrap.install(into: zdot, source: source)
        let dest = installed.appendingPathComponent(".zshenv")
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "# sora\n")

        try "# sora-2\n".write(to: source, atomically: true, encoding: .utf8)
        _ = try SoraZshBootstrap.install(into: zdot, source: source)
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "# sora-2\n")
    }
}
