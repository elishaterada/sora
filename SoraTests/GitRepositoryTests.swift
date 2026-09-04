import XCTest

final class GitRepositoryTests: XCTestCase {
    func testFindsGitRootFromNestedDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sora-git-\(UUID().uuidString)", isDirectory: true)
        let nested = root
            .appendingPathComponent("src", isDirectory: true)
            .appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(GitRepository.root(containing: nested))
        FileManager.default.createFile(atPath: root.appendingPathComponent(".git").path, contents: Data())
        XCTAssertEqual(GitRepository.root(containing: nested)?.path, root.path)
        XCTAssertTrue(GitRepository.isInside(nested, root: root))
        XCTAssertFalse(GitRepository.isInside(root.deletingLastPathComponent(), root: root))
    }

    func testDirectoryURLDoesNotWalkPastRoot() {
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("sora-git-noroot-\(UUID().uuidString)", isDirectory: true)
        XCTAssertNil(GitRepository.root(containing: cwd))
    }

    func testReadsBranchNameFromHeadRef() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sora-git-branch-\(UUID().uuidString)", isDirectory: true)
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "ref: refs/heads/lantern\n".write(
            to: git.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(GitRepository.branchName(containing: root), "lantern")
        XCTAssertNil(GitRepository.branchName(containing: nil as URL?))
    }
}
