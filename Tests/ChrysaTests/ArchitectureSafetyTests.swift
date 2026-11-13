import Foundation
import AppKit
import ImageIO
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

    @Test
    func testPEIconExtractionAndGameIconResolverDiskCache() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-icon-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var rgba = Data(count: 32 * 32 * 4)
        for idx in stride(from: 0, to: rgba.count, by: 4) {
            rgba[idx] = 0x24
            rgba[idx + 1] = 0x47
            rgba[idx + 2] = 0x9E
            rgba[idx + 3] = 0xFF
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let provider = try #require(CGDataProvider(data: rgba as CFData))
        let cgImg = try #require(CGImage(
            width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32 * 4,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let pngBuf = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(pngBuf, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cgImg, nil)
        #expect(CGImageDestinationFinalize(dest))
        let pngPayload = pngBuf as Data

        let peData = Self.makePEWithIconResource(iconPayload: pngPayload, width: 32, height: 32, bitCount: 32)
        let extracted = try #require(PEBinaryInspector.extractIconData(from: peData))
        #expect(extracted == pngPayload)

        let exeURL = tmpDir.appendingPathComponent("TestGame.exe")
        try peData.write(to: exeURL)

        let cacheDir = tmpDir.appendingPathComponent("icon-cache", isDirectory: true)
        let resolver = GameIconResolver(
            cacheDirectory: cacheDir,
            crossOverAppsDirectory: tmpDir.appendingPathComponent("absent-cx-apps").path,
            allowNetworkFallback: false
        )
        let game = LaunchGame(title: "TestGame", exePath: exeURL.path, gameDirectory: tmpDir.path, source: .manualImport)
        let resolvedPNG = try #require(await resolver.resolveIconPNG(for: game))
        let resolvedImg = try #require(NSImage(data: resolvedPNG))
        #expect(resolvedImg.size.width > 0)

        // Removing the source .exe must still serve the cached 32x32 PNG from disk
        try FileManager.default.removeItem(at: exeURL)
        let coldResolver = GameIconResolver(
            cacheDirectory: cacheDir,
            crossOverAppsDirectory: tmpDir.appendingPathComponent("absent-cx-apps").path,
            allowNetworkFallback: false
        )
        let cachedPNG = try #require(await coldResolver.resolveIconPNG(for: game))
        #expect(cachedPNG == resolvedPNG)
    }

    private static func makePEWithIconResource(iconPayload: Data, width: UInt8, height: UInt8, bitCount: UInt16) -> Data {
        var pe = Data(count: 0x300)
        func writeU16(_ val: UInt16, at off: Int, into buf: inout Data) {
            var le = val.littleEndian
            buf.replaceSubrange(off..<(off + 2), with: Data(bytes: &le, count: 2))
        }
        func writeU32(_ val: UInt32, at off: Int, into buf: inout Data) {
            var le = val.littleEndian
            buf.replaceSubrange(off..<(off + 4), with: Data(bytes: &le, count: 4))
        }

        writeU16(0x5A4D, at: 0, into: &pe)
        writeU32(0x80, at: 0x3C, into: &pe)

        let peOff = 0x80
        writeU32(0x00004550, at: peOff, into: &pe)
        writeU16(1, at: peOff + 6, into: &pe)
        writeU16(240, at: peOff + 20, into: &pe)

        let optStart = peOff + 24
        writeU16(0x20B, at: optStart, into: &pe)
        let rsrcRVA: UInt32 = 0x1000
        let rsrcRawOff = 0x200

        var rsrc = Data(count: 0x120)
        writeU16(2, at: 0x00 + 14, into: &rsrc)
        writeU32(3, at: 0x10, into: &rsrc)
        writeU32(0x8000_0020, at: 0x14, into: &rsrc)
        writeU32(14, at: 0x18, into: &rsrc)
        writeU32(0x8000_0060, at: 0x1C, into: &rsrc)

        writeU16(1, at: 0x20 + 14, into: &rsrc)
        writeU32(1, at: 0x30, into: &rsrc)
        writeU32(0x8000_0038, at: 0x34, into: &rsrc)

        writeU16(1, at: 0x38 + 14, into: &rsrc)
        writeU32(0x0409, at: 0x48, into: &rsrc)
        writeU32(0x50, at: 0x4C, into: &rsrc)

        writeU16(1, at: 0x60 + 14, into: &rsrc)
        writeU32(1, at: 0x70, into: &rsrc)
        writeU32(0x8000_0078, at: 0x74, into: &rsrc)

        writeU16(1, at: 0x78 + 14, into: &rsrc)
        writeU32(0x0409, at: 0x88, into: &rsrc)
        writeU32(0x90, at: 0x8C, into: &rsrc)

        let grpRel = 0xA0
        writeU16(0, at: grpRel, into: &rsrc)
        writeU16(1, at: grpRel + 2, into: &rsrc)
        writeU16(1, at: grpRel + 4, into: &rsrc)
        rsrc[grpRel + 6] = width
        rsrc[grpRel + 7] = height
        writeU16(1, at: grpRel + 10, into: &rsrc)
        writeU16(bitCount, at: grpRel + 12, into: &rsrc)
        writeU32(UInt32(iconPayload.count), at: grpRel + 14, into: &rsrc)
        writeU16(1, at: grpRel + 18, into: &rsrc)

        let iconRel = rsrc.count
        rsrc.append(iconPayload)

        writeU32(rsrcRVA + UInt32(iconRel), at: 0x50, into: &rsrc)
        writeU32(UInt32(iconPayload.count), at: 0x54, into: &rsrc)

        writeU32(rsrcRVA + UInt32(grpRel), at: 0x90, into: &rsrc)
        writeU32(20, at: 0x94, into: &rsrc)

        writeU32(rsrcRVA, at: optStart + 112 + 16, into: &pe)
        writeU32(UInt32(rsrc.count), at: optStart + 112 + 20, into: &pe)

        let secOff = optStart + 240
        writeU32(UInt32(rsrc.count), at: secOff + 8, into: &pe)
        writeU32(rsrcRVA, at: secOff + 12, into: &pe)
        writeU32(UInt32(rsrc.count), at: secOff + 16, into: &pe)
        writeU32(UInt32(rsrcRawOff), at: secOff + 20, into: &pe)

        pe.replaceSubrange(rsrcRawOff..<pe.count, with: rsrc.prefix(pe.count - rsrcRawOff))
        if rsrcRawOff + rsrc.count > pe.count {
            pe.append(rsrc.suffix(rsrcRawOff + rsrc.count - pe.count))
        }
        return pe
    }

    @Test
    func testLocalAppAndNestedExeImportAndCustomIconLifecycle() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-local-icon-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let services = DefaultWorkflowServices()

        // 1. Standalone macOS .app import strips ".app" and reads bundle icon
        let macApp = tmpDir.appendingPathComponent("Balatro.app", isDirectory: true)
        let appContents = macApp.appendingPathComponent("Contents", isDirectory: true)
        let appResources = appContents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: appResources, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleName": "Balatro",
            "CFBundleIconFile": "AppIcon.png"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: appContents.appendingPathComponent("Info.plist"))

        let squarePNG = try Self.makeSolidPNG(width: 64, height: 64, r: 0x33, g: 0x66, b: 0xCC)
        try squarePNG.write(to: appResources.appendingPathComponent("AppIcon.png"))

        let importedApp = try #require(await services.inspectGameForImport(at: macApp, bottlesDirectory: tmpDir.path))
        #expect(importedApp.title == "Balatro")
        #expect(importedApp.gameDirectory == macApp.path)

        let cacheDir = tmpDir.appendingPathComponent("icon-cache", isDirectory: true)
        let customIconsDir = tmpDir.appendingPathComponent("custom-icons", isDirectory: true)
        let resolver = GameIconResolver(
            cacheDirectory: cacheDir,
            customIconsDirectory: customIconsDir,
            crossOverAppsDirectory: tmpDir.appendingPathComponent("absent-cx-apps").path,
            allowNetworkFallback: false
        )
        let appIconPNG = try #require(await resolver.resolveIconPNG(for: importedApp))
        let appIconImg = try #require(NSImage(data: appIconPNG))
        #expect(appIconImg.size.width == 64)
        #expect(appIconImg.size.height == 64)

        // 2. Nested Unreal-style EXE import recovers game folder title & ancestor steam_appid.txt
        let ueGameRoot = tmpDir.appendingPathComponent("MyAwesomeGame", isDirectory: true)
        let ueBinDir = ueGameRoot.appendingPathComponent("Binaries/Win64", isDirectory: true)
        try FileManager.default.createDirectory(at: ueBinDir, withIntermediateDirectories: true)
        try "123456\n".write(to: ueGameRoot.appendingPathComponent("steam_appid.txt"), atomically: true, encoding: .utf8)
        let ueEXE = ueBinDir.appendingPathComponent("MyAwesomeGame-Win64-Shipping.exe")
        let peData = Self.makePEWithIconResource(iconPayload: squarePNG, width: 64, height: 64, bitCount: 32)
        try peData.write(to: ueEXE)

        let importedUE = try #require(await services.inspectGameForImport(at: ueEXE, bottlesDirectory: tmpDir.path))
        #expect(importedUE.title == "MyAwesomeGame")
        #expect(importedUE.appID == "123456")

        // 3. Custom rectangular image is normalized to square and overrides EXE icon when .custom is selected
        let rectImageURL = tmpDir.appendingPathComponent("wide-cover.png")
        let rectPNG = try Self.makeSolidPNG(width: 96, height: 48, r: 0xEE, g: 0x44, b: 0x22)
        try rectPNG.write(to: rectImageURL)

        let savedCustomPath = try #require(await resolver.saveCustomIcon(from: rectImageURL, for: importedUE.id))
        #expect(FileManager.default.fileExists(atPath: savedCustomPath))
        let customImg = try #require(NSImage(contentsOfFile: savedCustomPath))
        #expect(customImg.size.width == customImg.size.height)

        var customizedUE = importedUE
        customizedUE.customIconPath = savedCustomPath
        customizedUE.iconPreference = .custom
        let customResolved = try #require(await resolver.resolveIconPNG(for: customizedUE))

        var exePreferredUE = customizedUE
        exePreferredUE.iconPreference = .executable
        let exeResolved = try #require(await resolver.resolveIconPNG(for: exePreferredUE))
        #expect(customResolved != exeResolved)

        // Cleanup removes managed custom icon without touching original file
        await resolver.removeCustomIcon(at: savedCustomPath)
        #expect(!FileManager.default.fileExists(atPath: savedCustomPath))
        #expect(FileManager.default.fileExists(atPath: rectImageURL.path))

        // 4. Bottle scanner helper ignores drive_c/windows system EXEs
        let bottleDir = tmpDir.appendingPathComponent("TestBottle", isDirectory: true)
        let winDir = bottleDir.appendingPathComponent("drive_c/windows", isDirectory: true)
        try FileManager.default.createDirectory(at: winDir, withIntermediateDirectories: true)
        try Data(repeating: 0x4D, count: 1024).write(to: winDir.appendingPathComponent("explorer.exe"))
        #expect(CrossOverBottleScanner.findMainExecutable(in: bottleDir.path) == nil)
    }

    private static func makeSolidPNG(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> Data {
        var rgba = Data(count: width * height * 4)
        for idx in stride(from: 0, to: rgba.count, by: 4) {
            rgba[idx] = r
            rgba[idx + 1] = g
            rgba[idx + 2] = b
            rgba[idx + 3] = 0xFF
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let provider = try #require(CGDataProvider(data: rgba as CFData))
        let cgImg = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let buf = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(buf, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cgImg, nil)
        #expect(CGImageDestinationFinalize(dest))
        return buf as Data
    }

}
