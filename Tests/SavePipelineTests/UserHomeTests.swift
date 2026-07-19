import XCTest
@testable import Save

final class UserHomeTests: XCTestCase {

    func testDirectoryIsNeverTheSandboxContainer() {
        XCTAssertFalse(UserHome.directory.path.contains("/Library/Containers/"))
    }

    func testDefaultOutputDirectoryIsInsideRealMovies() {
        let dir = ClipMetadata.defaultOutputDirectory
        XCTAssertFalse(dir.path.contains("/Library/Containers/"))
        XCTAssertTrue(dir.path.hasPrefix(UserHome.directory.path))
        XCTAssertTrue(dir.path.contains("Movies/ReplayCap"))
    }

    func testAbbreviateReplacesHomeWithTilde() {
        let home = UserHome.directory.path(percentEncoded: false)
        XCTAssertEqual(
            UserHome.abbreviateForDisplay(home + "Movies/ReplayCap/"),
            "~/Movies/ReplayCap"
        )
        XCTAssertEqual(
            UserHome.abbreviateForDisplay(home + "Movies/ReplayCap"),
            "~/Movies/ReplayCap"
        )
    }

    func testAbbreviateOfHomeItselfIsTilde() {
        let home = UserHome.directory.path(percentEncoded: false)
        XCTAssertEqual(UserHome.abbreviateForDisplay(home), "~")
    }

    func testAbbreviateLeavesForeignPathsAlone() {
        XCTAssertEqual(
            UserHome.abbreviateForDisplay("/Volumes/External/Clips"),
            "/Volumes/External/Clips"
        )
    }
}
