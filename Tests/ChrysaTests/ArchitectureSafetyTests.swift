import XCTest
@testable import Chrysa

final class ArchitectureSafetyTests: XCTestCase {
    func testSettingsDecodeUsesDefaultsForMissingFields() throws {
        let data = Data(#"{"autoRelay":false}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertFalse(settings.autoRelay)
        XCTAssertEqual(settings.maxConcurrentConnections, AppSettings.default.maxConcurrentConnections)
        XCTAssertEqual(settings.downloadDirectory, AppSettings.default.downloadDirectory)
        XCTAssertEqual(settings.passwords, AppSettings.default.passwords)
    }

    func testTaskDecodeUsesDefaultsForMissingFields() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id.uuidString)\"}".utf8)
        let task = try JSONDecoder().decode(StudioTask.self, from: data)

        XCTAssertEqual(task.id, id)
        XCTAssertEqual(task.status, .failed)
        XCTAssertEqual(task.rightText, "")
        XCTAssertFalse(task.isArchived)
        XCTAssertTrue(task.checklist.isEmpty)
    }

    func testPathSafetyRejectsTraversalAndUnsafeNames() {
        XCTAssertNil(PathSafety.safeFilename("../outside.7z"))
        XCTAssertNil(PathSafety.safeFilename("nested/file.7z"))
        XCTAssertNil(PathSafety.safeRelativeDirectory("../outside"))
        XCTAssertNil(PathSafety.safeRelativeDirectory("/absolute/path"))
        XCTAssertEqual(PathSafety.safeRelativeDirectory("folder/part-01"), "folder/part-01")
    }

    func testUnpackDirectoryNeverUsesEmptyCleanTitle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-safety-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let result = try PathSafety.uniqueChildDirectory(parent: root, proposedName: "v1.2.7z")
        XCTAssertNotEqual(result.name, "")
        XCTAssertTrue(result.url.path.hasPrefix(root.path + "/"))
    }
}
