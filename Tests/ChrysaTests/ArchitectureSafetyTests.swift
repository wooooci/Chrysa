import Foundation
import SwiftUI
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

    @MainActor
    @Test
    func testModuleSFSymbolsAndLogoAccentThemeLinkage() throws {
        #expect(StudioTab.download.symbolName == "tray.and.arrow.down")
        #expect(StudioTab.unpack.symbolName == "square.grid.3x1.folder.badge.plus")
        #expect(StudioTab.patch.symbolName == "puzzlepiece")
        #expect(StudioTab.launch.symbolName == "gamecontroller")
        #expect(StudioTab.settings.symbolName == "slider.horizontal.3")
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-theme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let settingsFile = tmpDir.appendingPathComponent("settings.json")
        let store = AppSettingsStore(inMemoryOnly: false, customFileURL: settingsFile)
        let vm = StudioViewModel(
            inMemoryOnly: true,
            settingsStore: store,
            taskStore: TaskStore(inMemoryOnly: true),
            coordinator: PipelineCoordinator(services: DefaultWorkflowServices(), jobStore: JobStore(inMemoryOnly: true))
        )

        // 1. Default mode is pure-black monochrome
        #expect(vm.accentColorMode == .monochrome)
        #expect(vm.themePalette.mode == .monochrome)
        #expect(vm.themePalette.accent == .t3InkBlack)
        #expect(vm.themePalette.iconActive == .t3InkBlack)

        // 2. Toggle Follow App Logo switch ON and verify every Logo yields its own synced accent color
        vm.toggleFollowAppIconTheme()
        #expect(vm.themePalette.mode == .followAppIcon)
        #expect(vm.themePalette.accent != .t3InkBlack)
        var seenAccents: [Color] = []
        for option in vm.iconOptions {
            vm.selectAppIcon(id: option.id)
            let resolved = vm.themePalette
            #expect(resolved.selectedIconID == option.id)
            #expect(resolved.accent == resolved.logoAccent)
            #expect(resolved.iconActive == resolved.logoAccent)
            #expect(resolved.accent != .t3InkBlack)
            #expect(!seenAccents.contains(resolved.accent))
            seenAccents.append(resolved.accent)
        }
        #expect(seenAccents.count == 6)

        // 3. Persistence round-trip preserves followAppIcon + selectedIconID
        let reloadedStore = AppSettingsStore(inMemoryOnly: false, customFileURL: settingsFile)
        #expect(reloadedStore.settings.accentColorMode == .followAppIcon)
        #expect(reloadedStore.settings.selectedIconID == "dark_emerald_mint")

        // 4. Toggling switch OFF restores pure-black minimalist mode while keeping the Logo choice
        vm.toggleFollowAppIconTheme()
        #expect(vm.themePalette.mode == .monochrome)
        #expect(vm.themePalette.accent == .t3InkBlack)
        #expect(vm.settingsStore.settings.selectedIconID == "dark_emerald_mint")
    }
    @MainActor
    @Test
    func testPatchLibraryDeduplicatesScannerAndLegacyDuplicates() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-patch-dedup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Case 1: Outer unpacked build folder vs scanner inner symlinked folder + same exePath/appID
        let directRimWorld = Job(
            kind: .patch,
            title: "RimWorld",
            status: .succeeded,
            progress: 1,
            source: ArtifactRef(kind: .directory, value: "/Users/test/Downloads/RimWorld.Build.26571351"),
            input: ArtifactRef(kind: .directory, value: "/Users/test/Downloads/RimWorld.Build.26571351"),
            output: ArtifactRef(kind: .file, value: "/Users/test/Downloads/RimWorld.Build.26571351/steamapps/common/RimWorld/RimWorld.exe"),
            message: "Goldberg x64",
            rightText: "▶ 启动",
            appID: "294100",
            checklist: [CheckItem(title: "steam_api64.dll ➔ Goldberg (294100) · 简中", isChecked: true)],
            listPosition: 0
        )
        let scannedRimWorld = Job(
            kind: .patch,
            title: "RimWorld",
            status: .succeeded,
            progress: 1,
            source: ArtifactRef(kind: .directory, value: "/Users/test/Downloads/RimWorld.Build.26571351/steamapps/common/RimWorld"),
            output: ArtifactRef(kind: .file, value: "/Users/test/Downloads/RimWorld.Build.26571351/steamapps/common/RimWorld/RimWorld.exe"),
            message: "Goldberg x64",
            rightText: "▶ 启动",
            appID: "294100",
            checklist: [CheckItem(title: "CrossOver 容器 [RimWorld] (DXMT + MSync)", isChecked: true)],
            listPosition: 5
        )

        // Case 2: Condensed bottle name / curly apostrophe variants from scanner vs legacy migrated task
        let scannedParabox = Job(
            kind: .patch,
            title: "Patrick‘s Parabox",
            status: .succeeded,
            progress: 1,
            source: ArtifactRef(kind: .directory, value: "/Users/test/Bottles/Patrick‘s Parabox"),
            checklist: [CheckItem(title: "CrossOver 容器 [Patrick‘s Parabox] (DXMT + MSync)", isChecked: true)],
            listPosition: 1
        )
        let migratedParabox = Job.fromLegacy(
            StudioTask(
                title: "Patrick's Parabox",
                status: .done,
                localPath: "/Users/test/Bottles/Patrick‘s Parabox",
                checklist: [CheckItem(title: "CrossOver 容器 [Patrick‘s Parabox] (DXMT + MSync)", isChecked: true)]
            ),
            kind: .patch
        )

        let jobsURL = tmpDir.appendingPathComponent("jobs.json")
        let store = JobStore(customFileURL: jobsURL)
        await store.upsert(scannedRimWorld)
        await store.upsert(directRimWorld)
        await store.upsert(scannedParabox)
        await store.upsert(migratedParabox)

        // Reloading from disk automatically collapses duplicates and keeps the richer direct/migrated jobs
        let reloaded = JobStore(customFileURL: jobsURL)
        let loadRes = await reloaded.load()
        let patchJobs = loadRes.jobs.filter { $0.kind == .patch }
        #expect(patchJobs.count == 2)
        #expect(patchJobs.contains(where: { $0.id == directRimWorld.id && $0.checklist.first?.title.contains("steam_api64.dll") == true }))
        #expect(patchJobs.contains(where: { $0.id == migratedParabox.id }))

        // Rescanning bottles afterwards adds to Launch library instead of Patch jobs, and avoids duplicates
        let launchStore = LaunchGameStore(inMemoryOnly: true)
        let coordinator = PipelineCoordinator(services: DefaultWorkflowServices(), jobStore: reloaded, gameLibrary: launchStore)
        let scannedGames = [
            LaunchGame(title: "RimWorld", exePath: directRimWorld.exePath, gameDirectory: directRimWorld.localPath, bottleName: "RimWorld", appID: "294100", source: .crossoverScan),
            LaunchGame(title: "Patrick‘s Parabox", gameDirectory: "/Users/test/Bottles/Patrick‘s Parabox", bottleName: "Patrick‘s Parabox", source: .crossoverScan)
        ]
        let added = await coordinator.addDiscoveredLaunchGames(scannedGames)
        #expect(added == 2)
        let addedAgain = await coordinator.addDiscoveredLaunchGames(scannedGames)
        #expect(addedAgain == 0)
        #expect((await reloaded.all()).filter { $0.kind == .patch }.count == 2)
    }

    @MainActor
    @Test
    func testLaunchModuleDecouplingPersistenceImportAndMigration() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-launch-sep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let gameDir = tmpDir.appendingPathComponent("Hollow Knight", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        let gameEXE = gameDir.appendingPathComponent("hollow_knight.exe")
        try Data(repeating: 0x4D, count: 2048).write(to: gameEXE)
        try Data(repeating: 0x4D, count: 2_100_000).write(to: gameDir.appendingPathComponent("steam_api64.dll"))
        try "367520\n".write(to: gameDir.appendingPathComponent("steam_appid.txt"), atomically: true, encoding: .utf8)

        let manualDir = tmpDir.appendingPathComponent("Celeste", isDirectory: true)
        try FileManager.default.createDirectory(at: manualDir, withIntermediateDirectories: true)
        let manualEXE = manualDir.appendingPathComponent("Celeste.exe")
        try Data(repeating: 0x4D, count: 1024).write(to: manualEXE)

        let jobsURL = tmpDir.appendingPathComponent("jobs.json")
        let gamesURL = tmpDir.appendingPathComponent("games.json")
        let jobStore = JobStore(customFileURL: jobsURL)
        let gameStore = LaunchGameStore(customFileURL: gamesURL)

        // Seed a legacy scanner-discovered patch job to verify one-time cleanup migration
        let legacyScannerPatch = Job(
            kind: .patch,
            title: "Legacy Scanned Game",
            status: .succeeded,
            source: ArtifactRef(kind: .directory, value: tmpDir.appendingPathComponent("legacy-bottle").path),
            checklist: [CheckItem(title: "CrossOver 容器 [Legacy Scanned Game] (DXMT + MSync)", isChecked: true)]
        )
        await jobStore.upsert(legacyScannerPatch)

        let settingsStore = AppSettingsStore(inMemoryOnly: true)
        settingsStore.settings.bottlesDirectory = tmpDir.appendingPathComponent("absent-bottles").path

        let coordinator = PipelineCoordinator(services: DefaultWorkflowServices(), jobStore: jobStore, gameLibrary: gameStore)
        let vm = StudioViewModel(
            inMemoryOnly: true,
            settingsStore: settingsStore,
            taskStore: TaskStore(inMemoryOnly: true),
            coordinator: coordinator
        )

        // 1. Migrate legacy scanner patch out of JobStore into LaunchGameStore
        _ = await coordinator.loadJobs(migratingLegacyStore: TaskStore(inMemoryOnly: true))
        _ = await coordinator.loadLaunchLibrary()
        await coordinator.migrateLegacyPatchEntriesToLaunchLibrary()
        let postMigrationJobs = await jobStore.all()
        #expect(!postMigrationJobs.contains(where: { $0.id == legacyScannerPatch.id }))
        let migratedGames = await gameStore.all()
        let migratedEntry = try #require(migratedGames.first(where: { $0.title == "Legacy Scanned Game" }))
        #expect(migratedEntry.source == .crossoverScan)

        // 2. Patch task completion auto-registers into LaunchGameStore; archiving/deleting Patch job leaves LaunchGame intact
        vm.startPatch(folderPath: gameDir.path)
        let deadline = Date().addingTimeInterval(5)
        while !(vm.jobs(of: .patch).first?.status == .succeeded) && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let patchJob = try #require(vm.jobs(of: .patch).first)
        #expect(patchJob.status == .succeeded)
        try await Task.sleep(nanoseconds: 30_000_000)
        let launchedHollow = try #require(vm.launchGames.first(where: { $0.title == "Hollow Knight" }))
        #expect(launchedHollow.source == .patchPipeline)
        #expect(launchedHollow.appID == "367520")

        vm.archiveTask(patchJob.legacyTask())
        vm.deleteTask(patchJob.legacyTask())
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(vm.jobs(of: .patch).isEmpty)
        #expect(vm.launchGames.contains(where: { $0.title == "Hollow Knight" }))

        // 3. Manual import (.exe and directory) populates LaunchGameStore and persists across reload
        let importedCeleste = await coordinator.importLaunchGame(at: manualEXE, settings: settingsStore.settings)
        #expect(importedCeleste?.title == "Celeste")
        #expect(importedCeleste?.exePath == manualEXE.path)
        #expect(importedCeleste?.source == .manualImport)

        let reloadedGameStore = LaunchGameStore(customFileURL: gamesURL)
        let reloadedGames = await reloadedGameStore.load().games
        #expect(reloadedGames.contains(where: { $0.title == "Hollow Knight" }))
        #expect(reloadedGames.contains(where: { $0.title == "Celeste" }))
        #expect(reloadedGames.contains(where: { $0.title == "Legacy Scanned Game" }))

        // 4. Removing a scanned game suppresses auto-rescan resurrection until explicit rescan
        let legacyEntry = try #require(vm.launchGames.first(where: { $0.title == "Legacy Scanned Game" }))
        await coordinator.removeLaunchGame(legacyEntry.id)
        let scannedAgain = [LaunchGame(title: "Legacy Scanned Game", bottleName: "Legacy Scanned Game", source: .crossoverScan)]
        let readded = await coordinator.addDiscoveredLaunchGames(scannedAgain)
        #expect(readded == 0)
    }

    @MainActor
    @Test
    func testStructuredTaskScopedLoggingRawErrorCaptureAndNoUINoise() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-log-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = AppSettingsStore(inMemoryOnly: true)
        let jobStore = JobStore(customFileURL: tmpDir.appendingPathComponent("jobs.json"))
        let coordinator = PipelineCoordinator(services: DefaultWorkflowServices(), jobStore: jobStore)
        let vm = StudioViewModel(
            inMemoryOnly: true,
            settingsStore: store,
            taskStore: TaskStore(inMemoryOnly: true),
            coordinator: coordinator
        )

        // 1. Pure UI/preference actions must produce zero log noise
        #expect(vm.logs.isEmpty)
        vm.selectAppIcon(id: "w6_burgundy")
        vm.toggleFollowAppIconTheme()
        vm.toggleAutoRelay()
        vm.toggleDeleteArchiveAfterUnpack()
        vm.setConcurrentConnections(8)
        vm.setDefaultLanguage(.tchinese)
        vm.newPasswordInput = "test_secret_pwd"
        vm.addPassword()
        vm.resetDownloadDirectory()
        #expect(vm.logs.isEmpty)
        #expect(!vm.hasUnreadErrorLogs)

        // 2. Subprocess failure (corrupt archive on 7zz) binds to taskID, records .unpack/.error, captures raw output, and redacts passwords
        let corruptPath = tmpDir.appendingPathComponent("broken_archive.7z").path
        try Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x00]).write(to: URL(fileURLWithPath: corruptPath))
        let unpackTaskID = UUID()
        let unpackJob = Job(
            id: unpackTaskID,
            kind: .unpack,
            title: "broken_archive.7z",
            status: .running,
            source: ArtifactRef(kind: .file, value: corruptPath),
            input: ArtifactRef(kind: .file, value: corruptPath)
        )
        await coordinator.addJob(unpackJob)
        await coordinator.runUnpackTask(
            taskID: unpackTaskID,
            archivePath: corruptPath,
            candidatePasswords: ["", "super_secret_pwd_123"],
            settings: store.settings
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        let taskScopedLogs = vm.logs(for: unpackTaskID)
        #expect(!taskScopedLogs.isEmpty)
        #expect(taskScopedLogs.allSatisfy { $0.taskID == unpackTaskID && $0.module == .unpack })
        #expect(taskScopedLogs.contains { $0.level == .error })
        if ToolchainLocator.locateSevenZip() != nil {
            let rawErr = vm.rawErrorOutput(for: unpackTaskID)
            #expect(rawErr != nil && !(rawErr?.isEmpty ?? true))
            #expect(rawErr?.contains("super_secret_pwd_123") == false)
        }
        #expect(vm.hasUnreadErrorLogs)

        // 3. Opening global drawer clears unread error indicator and supports module/error/search filtering
        vm.toggleLogDrawer()
        #expect(vm.isLogDrawerPresented)
        #expect(!vm.hasUnreadErrorLogs)

        vm.logModuleFilter = .download
        #expect(vm.filteredGlobalLogs.isEmpty)
        vm.logModuleFilter = .unpack
        #expect(!vm.filteredGlobalLogs.isEmpty)
        vm.logErrorsOnly = true
        #expect(vm.filteredGlobalLogs.allSatisfy { $0.level == .error })
        vm.logSearchQuery = "non_existent_keyword_xyz"
        #expect(vm.filteredGlobalLogs.isEmpty)
        vm.logSearchQuery = ""

        // 4. Per-job log cap prevents persistence bloat
        var cappedJob = Job(kind: .download, title: "cap.7z")
        for idx in 0..<160 {
            cappedJob.appendBoundedLog(LogEntry(taskID: cappedJob.id, module: .download, level: .info, message: "step \(idx)"))
        }
        #expect(cappedJob.logs.count == Job.maxPersistedLogs)
        #expect(cappedJob.logs.first?.message == "step 60")
    }

}
