import Foundation
import Testing
@testable import Chrysa
import ChrysaCore
import ChrysaApplication
import ChrysaAdapters
import ChrysaPresentation

struct ArchitectureSafetyTests {

    @Test
    func testPathSafetyRejectsTraversalAndUnsafeNames() {
        #expect(PathSafety.safeFilename("../outside.7z") == nil)
        #expect(PathSafety.safeFilename("nested/file.7z") == nil)
        #expect(PathSafety.safeRelativeDirectory("../outside") == nil)
        #expect(PathSafety.safeRelativeDirectory("/absolute/path") == nil)
        #expect(PathSafety.safeRelativeDirectory("folder/part-01") == "folder/part-01")
    }

    @Test
    func testUnpackDirectoryNeverUsesEmptyCleanTitle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-safety-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let result = try PathSafety.uniqueChildDirectory(parent: root, proposedName: "v1.2.7z")
        #expect(result.name != "")
        #expect(result.url.path.hasPrefix(root.path + "/"))
    }

    @Test
    func testJobStoreTracksProgressAndRejectsLateUpdatesAfterCompletion() async {
        let store = JobStore(inMemoryOnly: true)
        let job = Job(kind: .download, title: "game.7z", status: .running, progress: 0.25)
        await store.upsert(job)
        await store.update(id: job.id, progress: 0.7, message: "下载中")
        await store.update(id: job.id, status: .succeeded, progress: 1)
        await store.update(id: job.id, status: .running, progress: 0.4, message: "迟到进度")

        let saved = await store.job(for: job.id)
        #expect(saved?.status == .succeeded)
        #expect(saved?.progress == 1)
        #expect(saved?.message == "下载中")
    }

    @Test
    func testJobStoreRejectsLateUpdatesAfterCancellation() async {
        let store = JobStore(inMemoryOnly: true)
        let job = Job(kind: .unpack, title: "game.7z", status: .running, progress: 0.6)
        await store.upsert(job)
        await store.update(id: job.id, status: .cancelled, message: "已停止")
        await store.update(id: job.id, status: .running, progress: 0.9, message: "迟到进度")

        let saved = await store.job(for: job.id)
        #expect(saved?.status == .cancelled)
        #expect(saved?.progress == 0.6)
        #expect(saved?.message == "已停止")
    }

    @Test
    func testJobPersistenceMigrationRecoveryAndSchemaProtection() async throws {
        try await JobPersistenceChecks.run()
    }

    @MainActor
    @Test
    func testPatchWorkflowAndLaunchOutcomes() async throws {
        try await PatchWorkflowChecks.run()
    }

}
