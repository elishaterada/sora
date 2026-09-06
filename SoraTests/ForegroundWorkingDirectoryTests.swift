import Darwin
import XCTest

final class ForegroundWorkingDirectoryTests: XCTestCase {
    func testReadsCurrentExecutableName() {
        XCTAssertNotNil(ForegroundWorkingDirectory.executableName(pid: getpid()))
    }

    func testCurrentProcessHasAWorkingDirectory() {
        let url = ForegroundWorkingDirectory.url(pid: getpid())
        XCTAssertNotNil(url)
        XCTAssertFalse(url?.path.isEmpty ?? true)
    }

    func testInvalidPidReturnsNil() {
        XCTAssertNil(ForegroundWorkingDirectory.url(pid: 0))
        XCTAssertNil(ForegroundWorkingDirectory.url(pid: -1))
    }
}
