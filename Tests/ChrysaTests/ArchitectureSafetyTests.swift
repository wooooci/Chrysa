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

    func testLegacyStoppedTaskMapsToCancelledJob() {
        let task = StudioTask(title: "stopped.7z", status: .failed, pill: "已停止")
        let job = Job.fromLegacy(task, kind: .download)

        XCTAssertEqual(job.status, .cancelled)
    }

    func testJobStoreTracksProgressAndRejectsLateUpdatesAfterCompletion() async {
        let store = JobStore()
        let job = Job(kind: .download, title: "game.7z", status: .running, progress: 0.25)
        await store.upsert(job)
        await store.update(id: job.id, progress: 0.7, message: "下载中")
        await store.update(id: job.id, status: .succeeded, progress: 1)
        await store.update(id: job.id, status: .running, progress: 0.4, message: "迟到进度")

        let saved = await store.job(for: job.id)
        XCTAssertEqual(saved?.status, .succeeded)
        XCTAssertEqual(saved?.progress, 1)
        XCTAssertEqual(saved?.message, "下载中")
    }

    func testJobStoreRejectsLateUpdatesAfterCancellation() async {
        let store = JobStore()
        let job = Job(kind: .unpack, title: "game.7z", status: .running, progress: 0.6)
        await store.upsert(job)
        await store.update(id: job.id, status: .cancelled, message: "已停止")
        await store.update(id: job.id, status: .running, progress: 0.9, message: "迟到进度")

        let saved = await store.job(for: job.id)
        XCTAssertEqual(saved?.status, .cancelled)
        XCTAssertEqual(saved?.progress, 0.6)
        XCTAssertEqual(saved?.message, "已停止")
    }

    func testStageRegistryRegistersAndExecutesStage() async throws {
        var registry = StageRegistry()
        let stage = EchoStage()
        registry.register(stage)

        XCTAssertEqual(registry.registeredIDs, [stage.id])
        let result = try await registry.stage(for: stage.id)?.execute(
            context: StageContext(jobID: UUID(), input: ArtifactRef(kind: .file, value: "/tmp/input"))
        )
        XCTAssertEqual(result?.artifact, ArtifactRef(kind: .file, value: "/tmp/input"))
    }
}

private struct EchoStage: Stage {
    let id = StageID("test.echo")

    func execute(context: StageContext) async throws -> StageOutput {
        StageOutput(artifact: context.input)
    }
}
