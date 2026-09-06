import XCTest

final class ShellCommandResolverTests: XCTestCase {
    func testPrimaryCommandSkipsAssignmentsAndWrappers() {
        XCTAssertEqual(ShellCommandResolver.primaryCommand(in: "ls -la"), "ls")
        XCTAssertEqual(ShellCommandResolver.primaryCommand(in: "FOO=1 BAR=2 make test"), "make")
        XCTAssertEqual(ShellCommandResolver.primaryCommand(in: "sudo -u root cat /etc/hosts"), "sudo")
        XCTAssertEqual(ShellCommandResolver.primaryCommand(in: "command -v git"), "git")
        XCTAssertNil(ShellCommandResolver.primaryCommand(in: "   "))
        XCTAssertNil(ShellCommandResolver.primaryCommand(in: "FOO=bar"))
    }

    func testBuiltinsAreResolvableWithoutPATH() {
        XCTAssertTrue(ShellCommandResolver.isResolvable("cd ~/repos", path: ""))
        XCTAssertTrue(ShellCommandResolver.isResolvable("export PATH=/usr/bin", path: ""))
        XCTAssertTrue(ShellCommandResolver.isResolvable("echo hello", path: ""))
    }

    func testMissingBinaryIsNotResolvable() {
        XCTAssertFalse(
            ShellCommandResolver.isResolvable(
                "definitely-not-a-real-sora-binary-xyz --help",
                path: "/usr/bin:/bin"
            )
        )
    }

    func testSystemBinariesResolveOnStandardPATH() {
        XCTAssertTrue(ShellCommandResolver.isResolvable("ls -la", path: "/usr/bin:/bin"))
        XCTAssertTrue(ShellCommandResolver.isResolvable("/bin/ls -la", path: ""))
    }
}
