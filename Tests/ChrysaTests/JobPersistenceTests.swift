import Foundation
import Testing
import ChrysaCore
import ChrysaApplication
import ChrysaAdapters

struct JobPersistenceTests {
    @Test
    func testLegacySnapshotMigrationPreservesFieldsOrderAndArtifacts() async throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        let tasksURL = directory.appendingPathComponent("tasks.json")
        let jobsURL = directory.appendingPathComponent("jobs.json")
        let legacyDownload = StudioTask(
            title: "Interrupted.7z", status: .running(0.4), pill: "下载中",
            sourceURL: "https://example.com/game.7z"
        )
        let legacyPatch = StudioTask(
            title: "Saved Game", status: .done, pill: "已就绪", rightText: "▶ 启动",
            localPath: directory.appendingPathComponent("game").path,
            exePath: directory.appendingPathComponent("game/game.exe").path, appID: "1234",
            isArchived: true, expanded: true,
            checklist: [CheckItem(title: "补丁完成", isChecked: true)]
        )
        let olderDownload = StudioTask(
            title: "Older.7z", status: .done, localPath: directory.appendingPathComponent("older.7z").path
        )
        let snapshot = PersistedTaskSnapshot(
            downloadTasks: [legacyDownload, olderDownload],
            unpackTasks: [],
            patchTasks: [legacyPatch]
        )
        let legacyBytes = try JSONEncoder().encode(snapshot)
        try legacyBytes.write(to: tasksURL, options: .atomic)

        let legacyStore = TaskStore(customFileURL: tasksURL)
        let store = JobStore(customFileURL: jobsURL)
        let migration = await store.load(migratingLegacyStore: legacyStore)
        guard case .migrated(let migrated) = migration else {
            Issue.record("Expected legacy migration to run")
            return
        }

        #expect(migrated.count == 3)
        #expect(migrated.filter { $0.kind == .download }.map(\.id) == [legacyDownload.id, olderDownload.id])
        let interrupted = try #require(await store.job(for: legacyDownload.id))
        #expect(interrupted.status == .failed && interrupted.message == "已中断")
        let patch = try #require(await store.job(for: legacyPatch.id))
        #expect(patch.legacyTask() == legacyPatch)
        #expect(try Data(contentsOf: tasksURL) == legacyBytes)

        // Presentation sync keeps stage artifacts and edited outputs across restart; in-flight jobs normalize on reload.
        let live = Job(
            kind: .unpack, title: "Archive.7z", status: .running, progress: 0.6,
            source: ArtifactRef(kind: .file, value: directory.appendingPathComponent("archive.7z").path),
            input: ArtifactRef(kind: .file, value: directory.appendingPathComponent("archive.7z").path)
        )
        await store.upsert(live)
        let output = ArtifactRef(kind: .directory, value: directory.appendingPathComponent("unpacked").path)
        await store.update(id: live.id, status: .succeeded, progress: 1, output: output, message: "已解锁")

        var presented = try #require(await store.job(for: live.id)).legacyTask()
        presented.isArchived = true
        await store.synchronizePresentation(from: PersistedTaskSnapshot(
            downloadTasks: [interrupted.legacyTask()],
            unpackTasks: [presented],
            patchTasks: [legacyPatch]
        ))
        let synchronized = try #require(await store.job(for: live.id))
        #expect(synchronized.source == live.source && synchronized.output == output)

        let restarted = JobStore(customFileURL: jobsURL)
        let restored = await restarted.load(migratingLegacyStore: legacyStore)
        #expect(restored.jobs.count == 4)
        let restoredUnpack = try #require(await restarted.job(for: live.id))
        #expect(restoredUnpack.status == .succeeded && restoredUnpack.isArchived)

        var editedUnpack = restoredUnpack.legacyTask()
        editedUnpack.localPath = directory.appendingPathComponent("relocated-output").path
        await restarted.synchronizePresentation(from: PersistedTaskSnapshot(
            downloadTasks: [interrupted.legacyTask()],
            unpackTasks: [editedUnpack],
            patchTasks: [legacyPatch]
        ))
        let edited = try #require(await restarted.job(for: live.id))
        #expect(edited.source == live.source)
        #expect(edited.output?.value == editedUnpack.localPath)

        let running = Job(kind: .download, title: "Running", status: .running, progress: 0.45)
        await restarted.upsert(running)
        let afterInterruption = JobStore(customFileURL: jobsURL)
        _ = await afterInterruption.load()
        let normalized = try #require(await afterInterruption.job(for: running.id))
        #expect(normalized.status == .failed && normalized.message == "已中断")
    }

    @Test
    func testPartialJobsArchiveDoesNotSuppressLegacyMigrationAndDeletedJobsStayDeleted() async throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        let tasksURL = directory.appendingPathComponent("mixed-tasks.json")
        let jobsURL = directory.appendingPathComponent("mixed-jobs.json")
        let legacyDownload = StudioTask(
            title: "RimWorld.zip", status: .done, sourceURL: "https://example.test/rimworld.zip",
            localPath: "/downloads/RimWorld.zip"
        )
        let legacyUnpack = StudioTask(title: "RimWorld.zip", status: .done, localPath: "/downloads/RimWorld")
        let legacyPatchJobs = (1...10).map { index in
            StudioTask(title: "Legacy Game \(index)", status: .done, localPath: "/games/Legacy Game \(index)")
        }
        let twelveLegacyTasks = PersistedTaskSnapshot(
            downloadTasks: [legacyDownload],
            unpackTasks: [legacyUnpack],
            patchTasks: legacyPatchJobs
        )
        try JSONEncoder().encode(twelveLegacyTasks).write(to: tasksURL, options: .atomic)

        let dummyJobs = [
            Job(kind: .download, title: "JobStoreCheck.7z", status: .succeeded),
            Job(kind: .unpack, title: "CancelledCheck.7z", status: .cancelled, message: "已停止")
        ]
        let encodedDummyJobs = try JSONSerialization.jsonObject(with: JSONEncoder().encode(dummyJobs))
        let oldEnvelope = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "jobs": encodedDummyJobs])
        try oldEnvelope.write(to: jobsURL, options: .atomic)
        try oldEnvelope.write(to: jobsURL.appendingPathExtension("bak"), options: .atomic)

        let legacyStore = TaskStore(customFileURL: tasksURL)
        let store = JobStore(customFileURL: jobsURL)
        guard case .migrated(let mixedJobs) = await store.load(migratingLegacyStore: legacyStore) else {
            Issue.record("Valid partial jobs archive blocked legacy migration")
            return
        }
        #expect(mixedJobs.count == 14)
        let legacyIDs = [legacyDownload.id, legacyUnpack.id] + legacyPatchJobs.map(\.id)
        #expect(legacyIDs.allSatisfy { id in mixedJobs.contains(where: { $0.id == id }) })

        await store.remove(id: legacyIDs[0])
        let restarted = JobStore(customFileURL: jobsURL)
        let reloaded = await restarted.load(migratingLegacyStore: legacyStore)
        #expect(reloaded.jobs.count == 13)
        #expect(await restarted.job(for: legacyIDs[0]) == nil)
    }

    @Test
    func testFailedMigrationWriteRemainsPendingUntilDestinationRecovers() async throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        let tasksURL = directory.appendingPathComponent("tasks.json")
        let snapshot = PersistedTaskSnapshot(
            downloadTasks: [StudioTask(title: "One.7z", status: .done)],
            unpackTasks: [StudioTask(title: "Two", status: .done)],
            patchTasks: [StudioTask(title: "Three", status: .done)]
        )
        let legacyBytes = try JSONEncoder().encode(snapshot)
        try legacyBytes.write(to: tasksURL, options: .atomic)

        let blockedDirectory = directory.appendingPathComponent("blocked")
        try Data("not-a-directory".utf8).write(to: blockedDirectory)
        let blockedJobsURL = blockedDirectory.appendingPathComponent("jobs.json")

        let pendingStore = JobStore(customFileURL: blockedJobsURL)
        guard case .migrationPending(let pending) = await pendingStore.load(migratingLegacyStore: TaskStore(customFileURL: tasksURL)) else {
            Issue.record("Expected failed migration write to report migrationPending")
            return
        }
        #expect(pending.count == 3)
        #expect(try Data(contentsOf: tasksURL) == legacyBytes)

        try FileManager.default.removeItem(at: blockedDirectory)
        await pendingStore.synchronizePresentation(from: snapshot)
        let retried = await JobStore(customFileURL: blockedJobsURL).load()
        #expect(retried.jobs.count == 3)
    }

    @Test
    func testCorruptOrMissingJobsAndVersionedLegacyBackupsRecover() async throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        let jobsURL = directory.appendingPathComponent("jobs.json")
        let store = JobStore(customFileURL: jobsURL)
        let first = Job(kind: .download, title: "First.7z", status: .succeeded)
        let second = Job(kind: .patch, title: "Second", status: .succeeded)
        await store.upsert(first)
        await store.upsert(second)

        let backupURL = jobsURL.appendingPathExtension("bak")
        let backupBytes = try Data(contentsOf: backupURL)
        let corruptBytes = Data("incomplete-json".utf8)
        try corruptBytes.write(to: jobsURL, options: .atomic)

        let recovering = JobStore(customFileURL: jobsURL)
        guard case .recovered(let recovered) = await recovering.load() else {
            Issue.record("Expected backup recovery from corrupt jobs.json")
            return
        }
        #expect(!recovered.isEmpty)
        #expect(try Data(contentsOf: jobsURL.appendingPathExtension("corrupt")) == corruptBytes)
        #expect(try Data(contentsOf: backupURL) == backupBytes)

        let secondRestart = await JobStore(customFileURL: jobsURL).load()
        #expect(secondRestart.jobs.count == recovered.count)

        try FileManager.default.removeItem(at: jobsURL)
        guard case .recovered = await JobStore(customFileURL: jobsURL).load() else {
            Issue.record("Expected missing main file to recover from backup")
            return
        }

        // Versioned legacy records and their backup remain readable too.
        let snapshot = PersistedTaskSnapshot(
            downloadTasks: [StudioTask(title: "D1.7z", status: .done)],
            unpackTasks: [StudioTask(title: "U1", status: .done)],
            patchTasks: [StudioTask(title: "P1", status: .done)]
        )
        let wrappedURL = directory.appendingPathComponent("wrapped-tasks.json")
        let wrappedLegacy = TaskStore(customFileURL: wrappedURL)
        await wrappedLegacy.save(snapshot)
        await wrappedLegacy.save(snapshot)
        try corruptBytes.write(to: wrappedURL, options: .atomic)
        let wrappedMigration = await JobStore(customFileURL: directory.appendingPathComponent("wrapped-jobs.json"))
            .load(migratingLegacyStore: wrappedLegacy)
        #expect(wrappedMigration.jobs.count == 3)
    }

    @Test
    func testFutureSchemaVersionProtectsJobsAndLegacyFilesFromOverwrite() async throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        let futureBytes = Data(#"{"schemaVersion":999,"jobs":[],"payload":{}}"#.utf8)
        let sampleJob = Job(kind: .unpack, title: "Archive.7z", status: .running)

        let futureJobsURL = directory.appendingPathComponent("future-jobs.json")
        try futureBytes.write(to: futureJobsURL, options: .atomic)
        let futureJobs = JobStore(customFileURL: futureJobsURL)
        guard case .unsupported = await futureJobs.load(migratingLegacyStore: TaskStore(inMemoryOnly: true)) else {
            Issue.record("Future job schema should be rejected")
            return
        }
        await futureJobs.upsert(sampleJob)
        #expect(try Data(contentsOf: futureJobsURL) == futureBytes)

        let futureTasksURL = directory.appendingPathComponent("future-tasks.json")
        let pendingJobsURL = directory.appendingPathComponent("pending-jobs.json")
        try futureBytes.write(to: futureTasksURL, options: .atomic)
        let pendingStore = JobStore(customFileURL: pendingJobsURL)
        guard case .unsupported = await pendingStore.load(migratingLegacyStore: TaskStore(customFileURL: futureTasksURL)) else {
            Issue.record("Future legacy schema should be rejected")
            return
        }
        await pendingStore.upsert(sampleJob)
        #expect(!FileManager.default.fileExists(atPath: pendingJobsURL.path))
        #expect(try Data(contentsOf: futureTasksURL) == futureBytes)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-jobs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
