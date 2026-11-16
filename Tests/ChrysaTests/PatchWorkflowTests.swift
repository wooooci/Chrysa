import Foundation
import Testing
import ChrysaCore
import ChrysaApplication
import ChrysaAdapters
import ChrysaPresentation

struct PatchWorkflowTests {
    @MainActor
    @Test
    func testDroppedFileRoutingToStages() async throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }

        let game = root.appendingPathComponent("Manual Game", isDirectory: true)
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        let exe = game.appendingPathComponent("Game.exe")
        try Data(repeating: 0x4D, count: 64).write(to: exe)

        let archiveDirectory = root.appendingPathComponent("drop-inputs", isDirectory: true)
        try fm.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let archive = archiveDirectory.appendingPathComponent("Game.7Z")
        try Data().write(to: archive)

        let installer = root.appendingPathComponent("setup_fixture.exe")
        try Data().write(to: installer)

        let textFile = root.appendingPathComponent("links.txt")
        try Data().write(to: textFile)

        let coordinator = PipelineCoordinator(
            services: DefaultWorkflowServices(),
            jobStore: JobStore(inMemoryOnly: true),
            gameLibrary: LaunchGameStore(inMemoryOnly: true)
        )

        let droppedGame = await coordinator.resolveDroppedFile(game)
        #expect(droppedGame.kind == .patch && droppedGame.path == game.path)

        let droppedEXE = await coordinator.resolveDroppedFile(exe)
        #expect(droppedEXE.kind == .patch && droppedEXE.path == game.path)

        let droppedArchive = await coordinator.resolveDroppedFile(archive)
        #expect(droppedArchive.kind == .unpack && droppedArchive.path == archive.path)

        let droppedDirectory = await coordinator.resolveDroppedFile(archiveDirectory)
        #expect(droppedDirectory.kind == .unpack && droppedDirectory.path == archive.path)

        let droppedInstaller = await coordinator.resolveDroppedFile(installer)
        #expect(droppedInstaller.kind == .unpack && droppedInstaller.path == installer.path)

        let droppedText = await coordinator.resolveDroppedFile(textFile)
        #expect(droppedText.kind == .download && droppedText.path == textFile.path)
    }

    @MainActor
    @Test
    func testManualPatchLanguageLogsListEditsRetryAndDeletePersistence() async throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }

        let game = root.appendingPathComponent("Manual Game", isDirectory: true)
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        // Existing large DLLs keep the established Goldberg detection rule.
        try Data(repeating: 0x4D, count: 2_100_000).write(to: game.appendingPathComponent("steam_api64.dll"))
        try Data(repeating: 0x4D, count: 1024).write(to: game.appendingPathComponent("Game.exe"))
        try "480\n".write(to: game.appendingPathComponent("steam_appid.txt"), atomically: true, encoding: .utf8)

        let storeFile = root.appendingPathComponent("jobs.json")
        let coordinator = PipelineCoordinator(
            services: DefaultWorkflowServices(),
            jobStore: JobStore(customFileURL: storeFile),
            gameLibrary: LaunchGameStore(inMemoryOnly: true)
        )
        let vm = StudioViewModel(
            inMemoryOnly: true,
            settingsStore: AppSettingsStore(inMemoryOnly: true),
            taskStore: TaskStore(inMemoryOnly: true),
            coordinator: coordinator
        )

        vm.activeTab = .settings
        vm.settingsStore.settings.bottlesDirectory = root.appendingPathComponent("absent-bottles").path
        vm.settingsStore.settings.defaultLanguage = .tchinese
        vm.startPatch(folderPath: game.path)

        try await waitUntil { vm.jobs(of: .patch).first?.status == .succeeded }
        let id = try #require(vm.jobs(of: .patch).first?.id)
        let completed = try #require(vm.task(for: id))
        #expect(completed.exePath?.hasSuffix("Game.exe") == true)

        let config = try String(contentsOf: game.appendingPathComponent("steam_settings/configs.user.ini"), encoding: .utf8)
        #expect(config.contains("language=tchinese") && config.contains("ip_country=TW"))
        #expect(vm.activeTab == .settings)

        let messages = vm.logs.map(\.message)
        let firstLog = try #require(messages.firstIndex(where: { $0.hasPrefix("gbe_fork") }))
        let finalLog = try #require(messages.firstIndex(where: { $0.hasPrefix("config ▸") }))
        #expect(firstLog < finalLog)

        vm.archiveTask(completed)
        vm.toggleExpanded(completed)
        let itemID = try #require(completed.checklist.first?.id)
        vm.toggleChecklistItem(taskID: id, itemID: itemID)
        try await waitUntil {
            guard let job = vm.jobs.first(where: { $0.id == id }) else { return false }
            return job.isArchived && !job.expanded && job.checklist.first?.isChecked == false
        }

        vm.beginEditTask(try #require(vm.task(for: id)))
        vm.editTitleInput = "Edited Game"
        vm.saveEditedTask(andRetry: false)
        try await waitUntil { vm.task(for: id)?.title == "Edited Game" }
        await vm.flushTasksImmediately()

        let restored = await JobStore(customFileURL: storeFile).load().jobs
        let saved = try #require(restored.first(where: { $0.id == id }))
        #expect(saved.title == "Edited Game" && saved.isArchived && saved.checklist.first?.isChecked == false)

        await coordinator.updateJob(id, status: .running, progress: 0.1, title: "Late title", message: "Late progress")
        let protected = await coordinator.jobStore.job(for: id)
        #expect(protected?.title == "Edited Game" && protected?.status == .succeeded)

        let missing = root.appendingPathComponent("missing")
        vm.startPatch(folderPath: missing.path)
        try await waitUntil { vm.jobs(of: .patch).contains { $0.source?.value == missing.path && $0.status == .failed } }
        let failed = try #require(vm.jobs(of: .patch).first { $0.source?.value == missing.path })

        vm.beginEditTask(try #require(vm.task(for: failed.id)))
        vm.editPathOrURLInput = game.path
        vm.saveEditedTask(andRetry: true)
        try await waitUntil { vm.jobs(of: .patch).filter { $0.status == .succeeded }.count == 2 }
        #expect(await coordinator.jobStore.job(for: failed.id) == nil)

        vm.deleteTask(try #require(vm.task(for: id)))
        try await waitUntil { vm.task(for: id) == nil }
        let afterDeletion = await JobStore(customFileURL: storeFile).load().jobs
        #expect(!afterDeletion.contains { $0.id == id })
    }

    @MainActor
    @Test
    func testPatchStageRejectsWriteFailureEscapingSymlinkAndCancellation() async throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }

        var settings = AppSettings.default
        settings.bottlesDirectory = root.appendingPathComponent("absent-bottles").path

        let dllData = Data(repeating: 0x4D, count: 2_100_000)
        let blocked = root.appendingPathComponent("blocked", isDirectory: true)
        try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
        try dllData.write(to: blocked.appendingPathComponent("steam_api64.dll"))
        try "480\n".write(to: blocked.appendingPathComponent("steam_appid.txt"), atomically: true, encoding: .utf8)
        try Data("keep".utf8).write(to: blocked.appendingPathComponent("steam_settings"))

        let patchStage = PatchStage(service: PatchService(), settings: settings, cleanTitle: "Fixture")
        let writeFailure = await patchStage.execute(context: StageContext(
            jobID: UUID(),
            input: ArtifactRef(kind: .directory, value: blocked.path)
        ))
        guard case .failure = writeFailure else {
            Issue.record("Expected write failure when steam_settings is a regular file")
            return
        }
        #expect(try Data(contentsOf: blocked.appendingPathComponent("steam_api64.dll")) == dllData)

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.removeItem(at: blocked.appendingPathComponent("steam_settings"))
        try fm.createSymbolicLink(at: blocked.appendingPathComponent("steam_settings"), withDestinationURL: outside)
        let escape = await patchStage.execute(context: StageContext(
            jobID: UUID(),
            input: ArtifactRef(kind: .directory, value: blocked.path)
        ))
        guard case .failure = escape else {
            Issue.record("Expected escaping configuration symlink to fail")
            return
        }
        #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)

        let cancelled = root.appendingPathComponent("cancelled", isDirectory: true)
        try fm.createDirectory(at: cancelled, withIntermediateDirectories: true)
        let originalDLL = Data(repeating: 0x44, count: 100)
        try originalDLL.write(to: cancelled.appendingPathComponent("steam_api64.dll"))
        for index in 0..<32 {
            try Data().write(to: cancelled.appendingPathComponent("scan-\(index).txt"))
        }
        let gate = CancellationGate()
        let midScan = await patchStage.execute(context: StageContext(
            jobID: UUID(),
            input: ArtifactRef(kind: .directory, value: cancelled.path),
            isCancelled: { await gate.cancelDuringScan() }
        ))
        #expect(midScan == .cancelled)
        #expect(try Data(contentsOf: cancelled.appendingPathComponent("steam_api64.dll")) == originalDLL)
        #expect(!fm.fileExists(atPath: cancelled.appendingPathComponent("steam_api64.dll.bak").path))

        let coordinator = PipelineCoordinator(
            services: DefaultWorkflowServices(),
            jobStore: JobStore(inMemoryOnly: true),
            gameLibrary: LaunchGameStore(inMemoryOnly: true)
        )
        let stopped = Job(kind: .patch, title: "Stopped", status: .running, source: ArtifactRef(kind: .directory, value: cancelled.path))
        await coordinator.addJob(stopped)
        await coordinator.cancelTask(stopped.id)
        await coordinator.runPatchTask(taskID: stopped.id, folderPath: cancelled.path, cleanTitle: stopped.title, settings: settings)
        let stoppedJob = await coordinator.jobStore.job(for: stopped.id)
        #expect(stoppedJob?.status == .cancelled && stoppedJob?.output == nil)
    }

    @Test
    func testLaunchGameStageOutcomesAndCancellation() async throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }

        let game = root.appendingPathComponent("Game", isDirectory: true)
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        let missing = root.appendingPathComponent("missing")

        let directoryJob = Job(kind: .patch, title: UUID().uuidString, status: .succeeded, source: ArtifactRef(kind: .directory, value: game.path))
        let request = GameLaunchRequest(job: directoryJob, bottlesDirectory: missing.path)
        let launchContext = StageContext(jobID: directoryJob.id, input: directoryJob.source)

        let failingLaunch = LaunchGameStage(service: GameLauncher(openExecutable: "/usr/bin/false"), request: request)
        guard case .failure = await failingLaunch.execute(context: launchContext) else {
            Issue.record("Expected nonzero open exit to fail")
            return
        }

        let successfulLaunch = LaunchGameStage(service: GameLauncher(openExecutable: "/usr/bin/true"), request: request)
        guard case .success = await successfulLaunch.execute(context: launchContext) else {
            Issue.record("Expected zero open exit to succeed")
            return
        }

        let cancelledLaunch = await successfulLaunch.execute(context: StageContext(jobID: UUID(), isCancelled: { true }))
        #expect(cancelledLaunch == .cancelled)

        let missingJob = Job(kind: .patch, title: UUID().uuidString, status: .succeeded, source: ArtifactRef(kind: .directory, value: missing.path))
        let absentLaunch = LaunchGameStage(service: GameLauncher(), request: GameLaunchRequest(job: missingJob, bottlesDirectory: missing.path))
        guard case .failure = await absentLaunch.execute(context: StageContext(jobID: missingJob.id)) else {
            Issue.record("Expected missing launch directory to fail")
            return
        }
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-patch-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "Timed out waiting for patch workflow")
    }
}

private actor CancellationGate {
    private var checks = 0

    func cancelDuringScan() -> Bool {
        checks += 1
        return checks >= 8
    }
}
