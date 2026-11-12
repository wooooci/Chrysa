import ChrysaCore
import ChrysaApplication
import ChrysaAdapters
import ChrysaPresentation
import Foundation

/// Shared by the executable self-test and the Swift Testing integration suite.
enum JobPersistenceChecks {
    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-jobs-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let tasksURL = directory.appendingPathComponent("tasks.json")
        let jobsURL = directory.appendingPathComponent("jobs.json")
        let legacyDownload = StudioTask(
            title: "Interrupted.7z", status: .running(0.4), pill: "下载中",
            sourceURL: "https://example.com/game.7z"
        )
        let legacyPatch = StudioTask(
            title: "Saved Game", status: .done, pill: "已就绪", rightText: "▶ 启动",
            localPath: "/tmp/game", exePath: "/tmp/game/game.exe", appID: "1234",
            isArchived: true, expanded: true,
            checklist: [CheckItem(title: "补丁完成", isChecked: true)]
        )
        let olderDownload = StudioTask(title: "Older.7z", status: .done, localPath: "/tmp/older.7z")
        let snapshot = PersistedTaskSnapshot(downloadTasks: [legacyDownload, olderDownload], unpackTasks: [], patchTasks: [legacyPatch])
        // Pre-envelope installations must migrate through the same entry point as the app.
        let legacyBytes = try JSONEncoder().encode(snapshot)
        try legacyBytes.write(to: tasksURL, options: .atomic)
        let legacyStore = TaskStore(customFileURL: tasksURL)
        let store = JobStore(customFileURL: jobsURL)
        let migration = await store.load(migratingLegacyStore: legacyStore)
        guard case .migrated(let migrated) = migration else { throw CheckFailure("Legacy migration did not run") }
        try require(migrated.count == 3, "Migration lost records")
        try require(migrated.filter { $0.kind == .download }.map(\.id) == [legacyDownload.id, olderDownload.id], "Migration changed list order")
        let interrupted = await store.job(for: legacyDownload.id)
        try require(interrupted?.status == .failed && interrupted?.message == "已中断", "Interrupted job was not normalized")
        let patch = await store.job(for: legacyPatch.id)
        try require(patch?.legacyTask() == legacyPatch, "Migration lost display or launch fields")
        try require(try Data(contentsOf: tasksURL) == legacyBytes, "Migration changed the legacy source")

        let live = Job(
            kind: .unpack, title: "Archive.7z", status: .running, progress: 0.6,
            source: ArtifactRef(kind: .file, value: "/tmp/archive.7z")
        )
        await store.upsert(live)
        let output = ArtifactRef(kind: .directory, value: "/tmp/unpacked")
        await store.update(id: live.id, status: .succeeded, progress: 1, output: output, message: "已解锁")
        await store.update(id: live.id, status: .running, progress: 0.2, message: "迟到进度")
        await store.upsert(live)
        let finished = await store.job(for: live.id)
        try require(finished?.status == .succeeded && finished?.progress == 1, "Late updates revived a terminal job")

        var presented = finished!.legacyTask()
        presented.isArchived = true
        await store.synchronizePresentation(from: PersistedTaskSnapshot(
            downloadTasks: [interrupted!.legacyTask()], unpackTasks: [presented], patchTasks: [legacyPatch]
        ))
        let synchronized = await store.job(for: live.id)
        try require(synchronized?.source == live.source && synchronized?.output == output, "Presentation lost stage artifacts")
        let restarted = JobStore(customFileURL: jobsURL)
        let restored = await restarted.load(migratingLegacyStore: legacyStore)
        try require(restored.jobs.count == 4, "Restart changed the persisted job count")
        let restoredUnpack = await restarted.job(for: live.id)
        try require(restoredUnpack?.status == .succeeded && restoredUnpack?.isArchived == true, "Restart lost terminal or display state")

        var editedUnpack = restoredUnpack!.legacyTask()
        editedUnpack.localPath = "/tmp/relocated-output"
        await restarted.synchronizePresentation(from: PersistedTaskSnapshot(
            downloadTasks: [interrupted!.legacyTask()], unpackTasks: [editedUnpack], patchTasks: [legacyPatch]
        ))
        let edited = await restarted.job(for: live.id)
        try require(edited?.source == live.source, "Editing the unpack output replaced its archive source")
        try require(edited?.output?.value == editedUnpack.localPath, "Editing the unpack output was not persisted")

        // A failed destination write must leave migration pending with the source intact.
        let blockedDirectory = directory.appendingPathComponent("blocked")
        try Data("not-a-directory".utf8).write(to: blockedDirectory)
        let blockedJobsURL = blockedDirectory.appendingPathComponent("jobs.json")
        let pendingMigration = JobStore(customFileURL: blockedJobsURL)
        guard case .migrationPending(let pending) = await pendingMigration.load(migratingLegacyStore: legacyStore) else {
            throw CheckFailure("Failed migration write was reported as completed")
        }
        try require(pending.count == 3, "Failed migration discarded the loaded jobs")
        try require(try Data(contentsOf: tasksURL) == legacyBytes, "Failed migration changed the legacy source")
        try FileManager.default.removeItem(at: blockedDirectory)
        await pendingMigration.synchronizePresentation(from: snapshot)
        let retriedMigration = await JobStore(customFileURL: blockedJobsURL).load()
        try require(retriedMigration.jobs.count == 3, "Migration did not persist after the destination recovered")

        let running = Job(kind: .download, title: "Running", status: .running, progress: 0.45)
        await restarted.upsert(running)
        let afterInterruption = JobStore(customFileURL: jobsURL)
        _ = await afterInterruption.load()
        let normalized = await afterInterruption.job(for: running.id)
        try require(normalized?.status == .failed && normalized?.message == "已中断", "Restart left an in-flight job running")

        // A corrupt main file must recover the backup, preserve the bytes, and survive another restart.
        let backupURL = jobsURL.appendingPathExtension("bak")
        let backupBytes = try Data(contentsOf: backupURL)
        let corruptBytes = Data("incomplete-json".utf8)
        try corruptBytes.write(to: jobsURL, options: .atomic)
        let recovering = JobStore(customFileURL: jobsURL)
        guard case .recovered(let recovered) = await recovering.load() else { throw CheckFailure("Backup recovery failed") }
        try require(!recovered.isEmpty, "Recovery returned no jobs")
        try require(try Data(contentsOf: jobsURL.appendingPathExtension("corrupt")) == corruptBytes, "Corrupt bytes were not preserved")
        try require(try Data(contentsOf: backupURL) == backupBytes, "Recovery destroyed the valid backup")
        let secondRestart = await JobStore(customFileURL: jobsURL).load()
        try require(secondRestart.jobs.count == recovered.count, "Recovered jobs did not survive another restart")
        try FileManager.default.removeItem(at: jobsURL)
        guard case .recovered = await JobStore(customFileURL: jobsURL).load() else {
            throw CheckFailure("Missing main file did not recover its backup")
        }

        let futureBytes = Data(#"{"schemaVersion":999,"jobs":[],"payload":{}}"#.utf8)
        let futureJobsURL = directory.appendingPathComponent("future-jobs.json")
        try futureBytes.write(to: futureJobsURL, options: .atomic)
        let futureJobs = JobStore(customFileURL: futureJobsURL)
        guard case .unsupported = await futureJobs.load(migratingLegacyStore: legacyStore) else {
            throw CheckFailure("Future job schema was accepted")
        }
        await futureJobs.upsert(live)
        try require(try Data(contentsOf: futureJobsURL) == futureBytes, "Future jobs file was overwritten")

        let futureTasksURL = directory.appendingPathComponent("future-tasks.json")
        let pendingJobsURL = directory.appendingPathComponent("pending-jobs.json")
        try futureBytes.write(to: futureTasksURL, options: .atomic)
        let pendingStore = JobStore(customFileURL: pendingJobsURL)
        guard case .unsupported = await pendingStore.load(migratingLegacyStore: TaskStore(customFileURL: futureTasksURL)) else {
            throw CheckFailure("Future legacy schema was treated as empty data")
        }
        await pendingStore.upsert(live)
        try require(!FileManager.default.fileExists(atPath: pendingJobsURL.path), "Unsupported legacy migration created a shadow archive")
        try require(try Data(contentsOf: futureTasksURL) == futureBytes, "Future legacy file was overwritten")

        // Versioned legacy records and their backup remain readable too.
        let wrappedURL = directory.appendingPathComponent("wrapped-tasks.json")
        let wrappedLegacy = TaskStore(customFileURL: wrappedURL)
        await wrappedLegacy.save(snapshot)
        await wrappedLegacy.save(snapshot)
        try corruptBytes.write(to: wrappedURL, options: .atomic)
        let wrappedMigration = await JobStore(customFileURL: directory.appendingPathComponent("wrapped-jobs.json"))
            .load(migratingLegacyStore: wrappedLegacy)
        try require(wrappedMigration.jobs.count == 3, "Versioned legacy backup did not migrate")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message) }
    }

    private struct CheckFailure: LocalizedError {
        let errorDescription: String?

        init(_ message: String) { errorDescription = message }
    }
}
