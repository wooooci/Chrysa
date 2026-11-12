import ChrysaCore
import ChrysaApplication
import ChrysaAdapters
import ChrysaPresentation
import Foundation

/// Exercises application entry points using temporary files and substitute open commands.
@MainActor
enum PatchWorkflowChecks {
    static func run() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp/chrysa-patch-checks-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let game = root.appendingPathComponent("Manual Game", isDirectory: true)
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        let dll = game.appendingPathComponent("steam_api64.dll")
        // Existing large DLLs keep the established already-patched detection rule.
        let dllData = Data(repeating: 0x4D, count: 2_100_000)
        try dllData.write(to: dll)
        try Data(repeating: 0x4D, count: 1024).write(to: game.appendingPathComponent("Game.exe"))
        try "480\n".write(to: game.appendingPathComponent("steam_appid.txt"), atomically: true, encoding: .utf8)

        let storeFile = root.appendingPathComponent("jobs.json")
        let coordinator = PipelineCoordinator(services: DefaultWorkflowServices(), jobStore: JobStore(customFileURL: storeFile))
        let vm = AppComposition.makeViewModel(inMemoryOnly: true, coordinator: coordinator)
        let droppedGame = await coordinator.resolveDroppedFile(game)
        try require(droppedGame.kind == .patch && droppedGame.path == game.path, "Game folder was not routed to patching")
        let droppedEXE = await coordinator.resolveDroppedFile(game.appendingPathComponent("Game.exe"))
        try require(droppedEXE.kind == .patch && droppedEXE.path == game.path, "Game executable lost its parent directory")
        let archiveDirectory = root.appendingPathComponent("drop-inputs", isDirectory: true)
        try fm.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let archive = archiveDirectory.appendingPathComponent("Game.7Z")
        try Data().write(to: archive)
        let droppedArchive = await coordinator.resolveDroppedFile(archive)
        try require(droppedArchive.kind == .unpack && droppedArchive.path == archive.path, "Archive was not routed to unpacking")
        let droppedDirectory = await coordinator.resolveDroppedFile(archiveDirectory)
        try require(droppedDirectory.kind == .unpack && droppedDirectory.path == archive.path, "Folder archive selection changed")
        let installer = root.appendingPathComponent("setup_fixture.exe")
        try Data().write(to: installer)
        let droppedInstaller = await coordinator.resolveDroppedFile(installer)
        try require(droppedInstaller.kind == .unpack && droppedInstaller.path == installer.path, "Setup executable was not routed to unpacking")
        let textFile = root.appendingPathComponent("links.txt")
        try Data().write(to: textFile)
        let droppedText = await coordinator.resolveDroppedFile(textFile)
        try require(droppedText.kind == .download && droppedText.path == textFile.path, "Link file was not routed to downloading")
        vm.activeTab = .settings
        vm.settingsStore.settings.bottlesDirectory = root.appendingPathComponent("absent-bottles").path
        vm.settingsStore.settings.defaultLanguage = .tchinese
        vm.startPatch(folderPath: game.path)
        try await waitUntil { vm.jobs(of: .patch).first?.status == .succeeded }
        let id = vm.jobs(of: .patch)[0].id
        let completed = vm.task(for: id)!
        try require(completed.exePath?.hasSuffix("Game.exe") == true, "Manual patch lost executable output")
        let config = try String(contentsOf: game.appendingPathComponent("steam_settings/configs.user.ini"), encoding: .utf8)
        try require(config.contains("language=tchinese") && config.contains("ip_country=TW"), "Manual patch lost language settings")
        try require(vm.activeTab == .settings, "Manual patch changed the selected tab")
        let messages = vm.logs.map(\.message)
        guard let firstLog = messages.firstIndex(where: { $0.hasPrefix("gbe_fork") }),
              let finalLog = messages.firstIndex(where: { $0.hasPrefix("config ▸") }) else {
            throw CheckFailure("Patch logs were not delivered before success")
        }
        try require(firstLog < finalLog, "Patch logs arrived out of order")

        vm.archiveTask(completed)
        vm.toggleExpanded(completed)
        let itemID = completed.checklist[0].id
        vm.toggleChecklistItem(taskID: id, itemID: itemID)
        try await waitUntil {
            guard let job = vm.jobs.first(where: { $0.id == id }) else { return false }
            return job.isArchived && !job.expanded && job.checklist.first?.isChecked == false
        }
        vm.beginEditTask(vm.task(for: id)!)
        vm.editTitleInput = "Edited Game"
        vm.saveEditedTask(andRetry: false)
        try await waitUntil { vm.task(for: id)?.title == "Edited Game" }
        await vm.flushTasksImmediately()
        let restored = await JobStore(customFileURL: storeFile).load().jobs
        let saved = restored.first(where: { $0.id == id })
        try require(saved?.title == "Edited Game" && saved?.isArchived == true && saved?.checklist.first?.isChecked == false,
                    "List edits did not survive store reconstruction")
        await coordinator.updateJob(id, status: .running, progress: 0.1, title: "Late title", message: "Late progress")
        let protected = await coordinator.jobStore.job(for: id)
        try require(protected?.title == "Edited Game" && protected?.status == .succeeded, "Late workflow update changed a completed job")

        let missing = root.appendingPathComponent("missing")
        vm.startPatch(folderPath: missing.path)
        try await waitUntil { vm.jobs(of: .patch).contains { $0.source?.value == missing.path && $0.status == .failed } }
        let failed = vm.jobs(of: .patch).first { $0.source?.value == missing.path }!
        vm.beginEditTask(vm.task(for: failed.id)!)
        vm.editPathOrURLInput = game.path
        vm.saveEditedTask(andRetry: true)
        try await waitUntil { vm.jobs(of: .patch).filter { $0.status == .succeeded }.count == 2 }
        let obsolete = await coordinator.jobStore.job(for: failed.id)
        try require(obsolete == nil, "Retry retained the failed job")
        vm.deleteTask(vm.task(for: id)!)
        try await waitUntil { vm.task(for: id) == nil }
        let afterDeletion = await JobStore(customFileURL: storeFile).load().jobs
        try require(!afterDeletion.contains { $0.id == id }, "Deleted record returned after reload")

        // A file where a directory is required reliably triggers a write error, including when run as root.
        let blocked = root.appendingPathComponent("blocked", isDirectory: true)
        try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
        try dllData.write(to: blocked.appendingPathComponent("steam_api64.dll"))
        try "480\n".write(to: blocked.appendingPathComponent("steam_appid.txt"), atomically: true, encoding: .utf8)
        try Data("keep".utf8).write(to: blocked.appendingPathComponent("steam_settings"))
        let patchStage = PatchStage(service: PatchService(), settings: vm.settingsStore.settings, cleanTitle: "Fixture")
        let writeFailure = await patchStage.execute(context: StageContext(jobID: UUID(), input: ArtifactRef(kind: .directory, value: blocked.path)))
        guard case .failure = writeFailure else { throw CheckFailure("Failed patch write was reported as success") }
        try require(try Data(contentsOf: blocked.appendingPathComponent("steam_api64.dll")) == dllData, "Failed write damaged the existing DLL")

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.removeItem(at: blocked.appendingPathComponent("steam_settings"))
        try fm.createSymbolicLink(at: blocked.appendingPathComponent("steam_settings"), withDestinationURL: outside)
        let escape = await patchStage.execute(context: StageContext(jobID: UUID(), input: ArtifactRef(kind: .directory, value: blocked.path)))
        guard case .failure = escape else { throw CheckFailure("Patch accepted an escaping configuration symlink") }
        try require(try fm.contentsOfDirectory(atPath: outside.path).isEmpty, "Patch wrote through an escaping symlink")

        let cancelled = root.appendingPathComponent("cancelled", isDirectory: true)
        try fm.createDirectory(at: cancelled, withIntermediateDirectories: true)
        let originalDLL = Data(repeating: 0x44, count: 100)
        try originalDLL.write(to: cancelled.appendingPathComponent("steam_api64.dll"))
        for index in 0..<32 {
            try Data().write(to: cancelled.appendingPathComponent("scan-\(index).txt"))
        }
        let gate = CancellationGate()
        let midScan = await patchStage.execute(context: StageContext(
            jobID: UUID(), input: ArtifactRef(kind: .directory, value: cancelled.path),
            isCancelled: { await gate.cancelDuringScan() }
        ))
        try require(midScan == .cancelled, "Mid-scan cancellation became success or failure")
        try require(try Data(contentsOf: cancelled.appendingPathComponent("steam_api64.dll")) == originalDLL, "Cancelled scan changed the DLL")
        try require(!fm.fileExists(atPath: cancelled.appendingPathComponent("steam_api64.dll.bak").path), "Cancelled scan created a backup")
        let stopped = Job(kind: .patch, title: "Stopped", status: .running, source: ArtifactRef(kind: .directory, value: cancelled.path))
        await coordinator.addJob(stopped)
        await coordinator.cancelTask(stopped.id)
        await coordinator.runPatchTask(taskID: stopped.id, folderPath: cancelled.path, cleanTitle: stopped.title, settings: vm.settingsStore.settings)
        let stoppedJob = await coordinator.jobStore.job(for: stopped.id)
        try require(stoppedJob?.status == .cancelled && stoppedJob?.output == nil, "Stopped patch was revived")

        let directoryJob = Job(kind: .patch, title: UUID().uuidString, status: .succeeded, source: ArtifactRef(kind: .directory, value: game.path))
        let request = GameLaunchRequest(job: directoryJob, bottlesDirectory: missing.path)
        let failingLaunch = LaunchGameStage(service: GameLauncher(openExecutable: "/usr/bin/false"), request: request)
        let launchContext = StageContext(jobID: directoryJob.id, input: directoryJob.source)
        guard case .failure = await failingLaunch.execute(context: launchContext) else {
            throw CheckFailure("Nonzero open exit was reported as a successful launch")
        }
        let successfulLaunch = LaunchGameStage(service: GameLauncher(openExecutable: "/usr/bin/true"), request: request)
        guard case .success = await successfulLaunch.execute(context: launchContext) else {
            throw CheckFailure("Successful substitute open command did not produce a stage output")
        }
        let cancelledLaunch = await successfulLaunch.execute(context: StageContext(jobID: UUID(), isCancelled: { true }))
        try require(cancelledLaunch == .cancelled, "Launch ignored cancellation")
        let missingJob = Job(kind: .patch, title: UUID().uuidString, status: .succeeded, source: ArtifactRef(kind: .directory, value: missing.path))
        let absentLaunch = LaunchGameStage(service: GameLauncher(), request: GameLaunchRequest(job: missingJob, bottlesDirectory: missing.path))
        guard case .failure = await absentLaunch.execute(context: StageContext(jobID: missingJob.id)) else {
            throw CheckFailure("Missing launch input did not fail")
        }
        print("5D. Patch workflow -> dropped-file routing, manual entry, ordered logs, list persistence, edit/retry/delete, write failure, symlink containment, cancellation and launch outcomes OK")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message) }
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try require(condition(), "Timed out waiting for patch workflow")
    }

    private struct CheckFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private actor CancellationGate {
        private var checks = 0
        func cancelDuringScan() -> Bool {
            checks += 1
            return checks >= 8
        }
    }
}
