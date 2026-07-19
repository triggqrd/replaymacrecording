import XCTest
@testable import UI

final class ClipLibraryMetadataStoreTests: XCTestCase {
    func testLoadMigratesLegacyReplayMacMetadataFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyURL = directory.appendingPathComponent(".ReplayMacClipLibrary.json")
        let metadata = [
            "/tmp/clip.mp4": ClipUserMetadata(
                displayName: "Highlight",
                isFavorite: true,
                tags: ["game"],
                notes: "Legacy metadata"
            )
        ]
        try JSONEncoder().encode(metadata).write(to: legacyURL)

        XCTAssertEqual(ClipLibraryMetadataStore.load(in: directory), metadata)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".ReplayCapClipLibrary.json").path
            )
        )
    }
}
