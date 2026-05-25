import XCTest
@testable import UI

final class SavePreflightTests: XCTestCase {
    func testBlocksWhenNotRecording() {
        let failure = SavePreflight.failure(
            isRecording: false,
            bufferedSeconds: 30,
            saveInProgress: false
        )

        XCTAssertEqual(failure, .notRecording)
    }

    func testBlocksWhenBufferEmpty() {
        let failure = SavePreflight.failure(
            isRecording: true,
            bufferedSeconds: 0.5,
            saveInProgress: false
        )

        XCTAssertEqual(failure, .bufferEmpty)
    }

    func testBlocksWhenSaveInProgress() {
        let failure = SavePreflight.failure(
            isRecording: true,
            bufferedSeconds: 30,
            saveInProgress: true
        )

        XCTAssertEqual(failure, .saveInProgress)
    }

    func testAllowsSaveWhenReady() {
        let failure = SavePreflight.failure(
            isRecording: true,
            bufferedSeconds: 5,
            saveInProgress: false
        )

        XCTAssertNil(failure)
    }
}
