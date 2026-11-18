import Foundation
import AppKit
import CryptoKit
import ImageIO
import Testing
import ChrysaCore
import ChrysaApplication
import ChrysaAdapters
import ChrysaPresentation

struct ArchitectureSafetyTests {

    @Test
    func testPathSafetyRejectsTraversalAndUnsafeNames() throws {
        #expect(PathSafety.safeFilename("../outside.7z") == nil)
        #expect(PathSafety.safeFilename("nested/file.7z") == nil)
        #expect(PathSafety.safeRelativeDirectory("../outside") == nil)
        #expect(PathSafety.safeRelativeDirectory("/absolute/path") == nil)
        #expect(PathSafety.safeRelativeDirectory("folder/part-01") == "folder/part-01")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-contained-\(UUID().uuidString)", isDirectory: true)
        let inside = root.appendingPathComponent("inside", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let escapingLink = inside.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escapingLink, withDestinationURL: outside)
        let outsidePayload = outside.appendingPathComponent("payload")
        try Data().write(to: outsidePayload)
        #expect(PathSafety.containedURL(escapingLink, in: inside) == nil)
        #expect(PathSafety.containedURL(escapingLink.appendingPathComponent("payload"), in: inside) == nil)
        #expect(PathSafety.containedURL(inside.appendingPathComponent("nested/file.txt"), in: inside) != nil)
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
        await store.upsert(job)

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
        let launchDeadline = Date().addingTimeInterval(5)
        while !vm.launchGames.contains(where: { $0.title == "Hollow Knight" }) && Date() < launchDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let launchedHollow = try #require(vm.launchGames.first(where: { $0.title == "Hollow Knight" }))
        #expect(launchedHollow.source == .patchPipeline)
        #expect(launchedHollow.appID == "367520")

        vm.archiveTask(patchJob.legacyTask())
        vm.deleteTask(patchJob.legacyTask())
        let deleteDeadline = Date().addingTimeInterval(5)
        while !vm.jobs(of: .patch).isEmpty && Date() < deleteDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
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
        vm.setMascotTheme(.roundMochi)
        vm.setMascotTheme(.grokAstral)
        vm.setMascotTheme(.none)
        vm.cycleMascotTheme()
        #expect(vm.mascotTheme == .forestCube)
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

        let pngPayload = try Self.makeSolidPNG(width: 32, height: 32, r: 0x24, g: 0x47, b: 0x9E)

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

    @Test
    func testResolverRegistryNormalizationThreadCapsAndUnsupportedHosts() async {
        #expect(HostResolverRegistry.normalizeDownloadInput("magnet:?xt=urn:btih:123") == nil)
        #expect(HostResolverRegistry.normalizeDownloadInput("https://example.test/game.torrent") == nil)
        #expect(HostResolverRegistry.normalizeDownloadInput("mega.nz/file/abc123") == nil)
        #expect(HostResolverRegistry.normalizeDownloadInput("bzzhr.co/abcd1234") == "https://bzzhr.co/abcd1234")
        #expect(HostResolverRegistry.normalizeDownloadInput("fuckingfast.co/xyz#Game.rar") == "https://fuckingfast.co/xyz#Game.rar")
        #expect(HostResolverRegistry.normalizeDownloadInput("1fichier.com/?xyz123") == "https://1fichier.com/?xyz123")

        #expect(HostResolverRegistry.maxThreads(for: "https://a-10.1fichier.com/c123", configuredMax: 16) == 1)
        #expect(HostResolverRegistry.maxThreads(for: "https://pixeldrain.com/api/file/abc", configuredMax: 16) == 4)
        #expect(HostResolverRegistry.maxThreads(for: "https://fileditchfiles.st/f/abc", configuredMax: 16) == 2)
        #expect(HostResolverRegistry.proxyNeeds(for: "https://bzzhr.co/abcd") == false)
        #expect(HostResolverRegistry.proxyNeeds(for: "https://fuckingfast.co/dl/xyz") == true)

        let megaResult = await HostResolverRegistry.resolveLinksDetailed("https://mega.nz/file/abc#key")
        #expect(megaResult.downloads.isEmpty)
        #expect(megaResult.failureReason == "不支持该网盘·需专用客户端")

        let encodedFilename = Data("https://cdn.example.test/RainWorld.7z".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let offlineResolved = await HostResolverRegistry.resolveLinks("https://example.test/\(encodedFilename)")
        #expect(offlineResolved.first?.suggestedFilename == "RainWorld.7z")
    }

    @Test
    func testUnpackMultipartPathNormalizationBottleScanAndProcessCancellation() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-infra-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("TestGame.part01.rar").path, contents: Data())
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("TestGame.7z.001").path, contents: Data())
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("setup_rain_world_1.11.8_(90164).exe").path, contents: Data())
        #expect(UnpackService.normalizeMultipartArchivePath(tmpDir.appendingPathComponent("TestGame.part02.rar").path).hasSuffix("TestGame.part01.rar"))
        #expect(UnpackService.normalizeMultipartArchivePath(tmpDir.appendingPathComponent("TestGame.7z.003").path).hasSuffix("TestGame.7z.001"))
        #expect(UnpackService.normalizeMultipartArchivePath(tmpDir.appendingPathComponent("setup_rain_world_1.11.8_(90164)-1.bin").path).hasSuffix(".exe"))

        let fixtureBottles = tmpDir.appendingPathComponent("FixtureBottles", isDirectory: true)
        let fixtureApps = tmpDir.appendingPathComponent("FixtureCrossOverApps", isDirectory: true)
        let fixtureGame = fixtureBottles.appendingPathComponent("Fixture Bottle/drive_c/Fixture Game", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureGame, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixtureApps, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: fixtureGame.appendingPathComponent("Fixture.exe"))
        let discoveredBottles = CrossOverBottleScanner.scanInstalledBottles(
            bottlesDirectory: fixtureBottles.path,
            crossOverAppsDirectory: fixtureApps.path
        )
        #expect(discoveredBottles.count == 1)
        #expect(discoveredBottles.first?.title == "Fixture Bottle")

        let processStart = Date()
        let runningProcess = Task {
            try await ProcessSupervisor.shared.run(executable: "/bin/sleep", arguments: ["30"], taskID: UUID())
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        runningProcess.cancel()
        _ = try? await runningProcess.value
        #expect(Date().timeIntervalSince(processStart) < 5)
    }

    @Test
    func testResolverHTMLAndJSONParsers() throws {
        // 1. Pixeldrain /l/ list JSON
        let listJSON = Data("""
        {
          "success": true,
          "title": "Cool Game Pack",
          "files": [
            {"id": "f1", "name": "Cool.part1.rar", "size": 1000},
            {"id": "f2", "name": "Cool.part2.rar", "size": 500}
          ]
        }
        """.utf8)
        let pdList = PixeldrainResolver.parseListJSON(listJSON, listID: "list1", originalInput: "https://pixeldrain.com/l/list1")
        #expect(pdList.downloads.count == 2)
        #expect(pdList.downloads[0].subDirectory == "Cool Game Pack")
        #expect(pdList.downloads[0].finalURL == "https://pixeldrain.com/api/file/f1?download")
        #expect(pdList.downloads[1].originalURL == "https://pixeldrain.com/u/f2")

        // 2. Buzzheavier filename extraction
        let buzzHTML = "<html><head><title>Hollow_Knight_v1.5.7z - Buzzheavier</title></head><body></body></html>"
        #expect(BuzzheavierResolver.extractFilenameFromHTML(buzzHTML) == "Hollow_Knight_v1.5.7z")

        // 3. Google Drive 100MB+ virus scan form extraction
        let gdriveHTML = """
        <html><body>
        <span class="uc-name-size"><a href="/open?id=FILE123">Big_Game_Build.7z</a> (4.2G)</span>
        <form id="download-form" action="https://drive.usercontent.google.com/download" method="get">
          <input type="hidden" name="id" value="FILE123">
          <input type="hidden" name="export" value="download">
          <input type="hidden" name="confirm" value="t">
          <input type="hidden" name="uuid" value="uuid-999-abc">
        </form>
        </body></html>
        """
        let gParsed = try #require(GoogleDriveResolver.parseVirusScanForm(html: gdriveHTML, fallbackID: "FILE123"))
        #expect(gParsed.filename == "Big_Game_Build.7z")
        #expect(gParsed.finalURL.contains("uuid=uuid-999-abc"))
        #expect(gParsed.finalURL.contains("confirm=t"))
        #expect(gParsed.finalURL.contains("id=FILE123"))

        // 4. MirrorUploadX provider preference order
        let mirrorHTML = """
        {"provider":"vikingfile","clickUrl":"/go/vf"},
        {"provider":"buzzheavier","clickUrl":"/go/bh"},
        {"provider":"fuckingfast","clickUrl":"/go/ff"},
        {"provider":"pixeldrain","clickUrl":"/go/pd"},
        {"provider":"gofile","clickUrl":"/go/gf"}
        """
        let ordered = MirrorUploadXResolver.extractOrderedProviders(from: mirrorHTML)
        #expect(ordered.map(\.0) == ["gofile", "fuckingfast", "buzzheavier", "pixeldrain", "vikingfile"])

        // 5. FuckingFast JS + fragment parsing
        let ffHTML = "<script>window.open('https://fuckingfast.co/dl/AbC_123');</script>"
        let ffParsed = try #require(FuckingFastResolver.parsePage(html: ffHTML, originalURL: "https://fuckingfast.co/xyz#TestGame.rar"))
        #expect(ffParsed.directURL == "https://fuckingfast.co/dl/AbC_123")
        #expect(ffParsed.filename == "TestGame.rar")

        // 6. 1fichier form & download link parsing
        let ofInitial = """
        <form method="post" action="https://1fichier.com/?xyz999">
          <input type="hidden" name="adz" value="123.456">
        </form>
        """
        let ofForm = try #require(OneFichierResolver.parseInitialForm(html: ofInitial, baseURL: "https://1fichier.com/?xyz999"))
        #expect(ofForm.formBody.contains("adz=123.456"))
        let ofFinalHTML = """
        <table><tr><td>Filename :</td><td>Archive_Game.zip</td></tr></table>
        <a href="https://a-12.1fichier.com/c888999" class="ok">Click here to download</a>
        """
        let ofDirect = try #require(OneFichierResolver.parseDownloadPage(html: ofFinalHTML))
        #expect(ofDirect.directURL == "https://a-12.1fichier.com/c888999")
        #expect(ofDirect.filename == "Archive_Game.zip")
    }

    @Test
    func testFakePayloadGuardAndDeterministicStagingLifecycle() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-guard-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let cfFile = tmpDir.appendingPathComponent("fake_cf.7z")
        try Data("<!DOCTYPE html><html><title>Just a moment...</title></html>".utf8).write(to: cfFile)
        #expect(ResolverHTTPHelper.validateStagedPayload(at: cfFile, expectedFilename: "game.7z") == "含网页盾·请用浏览器下载")

        let quotaFile = tmpDir.appendingPathComponent("fake_quota.rar")
        try Data("<html><body>Download quota exceeded for this file</body></html>".utf8).write(to: quotaFile)
        #expect(ResolverHTTPHelper.validateStagedPayload(at: quotaFile, expectedFilename: "game.rar") == "今日额度已满")

        let validBinary = tmpDir.appendingPathComponent("real.7z")
        try Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x04]).write(to: validBinary)
        #expect(ResolverHTTPHelper.validateStagedPayload(at: validBinary, expectedFilename: "real.7z") == nil)

        let jobID = UUID()
        let stageDir = try DownloadService.stagingDirectoryURL(downloadDirectory: tmpDir.path, jobID: jobID)
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        let partialFile = stageDir.appendingPathComponent("game.7z")
        try Data("partial".utf8).write(to: partialFile)
        #expect(stageDir.path.contains("/.chrysa-staging/\(jobID.uuidString)"))
        #expect(FileManager.default.fileExists(atPath: partialFile.path))

        DownloadService.cleanupStaging(for: jobID, downloadDirectory: tmpDir.path)
        #expect(!FileManager.default.fileExists(atPath: stageDir.path))
    }

    @Test
    func testJobStorePreservesPausedJobsAcrossRestart() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-paused-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let jobsURL = tmpDir.appendingPathComponent("jobs.json")
        let store = JobStore(customFileURL: jobsURL)
        let pausedJob = Job(
            kind: .download,
            title: "PausedGame.7z",
            status: .paused,
            progress: 0.42,
            source: ArtifactRef(kind: .remoteURL, value: "https://example.test/PausedGame.7z"),
            message: "已暂停"
        )
        await store.upsert(pausedJob)

        let reloaded = JobStore(customFileURL: jobsURL)
        _ = await reloaded.load()
        let loadedJob = try #require(await reloaded.job(for: pausedJob.id))
        #expect(loadedJob.status == .paused)
        #expect(loadedJob.progress == 0.42)
        #expect(loadedJob.message == "已暂停")
    }

    @Test
    func testGameDirectoryInspectorResolvesAnkerGamesRepackAndOverridesStaleSpacewarAppID() async throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory
            .appendingPathComponent("chrysa-inspector-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        #expect(LaunchGame.isIgnoredHelperExecutable("Redist/PhysX_9.08.14_9.09.0814_SystemSoftware.exe"))
        #expect(LaunchGame.isIgnoredHelperExecutable("Redist/vcredist_x86.exe"))
        #expect(LaunchGame.isIgnoredHelperExecutable("Redist/DXWebSetup.exe"))
        #expect(!LaunchGame.isIgnoredHelperExecutable("Pentiment/Pentiment.exe"))

        let releaseRoot = tmpDir.appendingPathComponent("Pentiment-AnkerGames", isDirectory: true)
        let redistDir = releaseRoot.appendingPathComponent("Redist", isDirectory: true)
        let innerGameDir = releaseRoot.appendingPathComponent("Pentiment", isDirectory: true)
        let pluginDir = innerGameDir.appendingPathComponent("Pentiment_Data/Plugins/x86_64", isDirectory: true)
        try fm.createDirectory(at: redistDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        try Data("URL=https://example.invalid\n".utf8)
            .write(to: releaseRoot.appendingPathComponent("AnkerGames - Free Pre-installed PC Games.url"))
        try Data("readme".utf8).write(to: releaseRoot.appendingPathComponent("Read Me.txt"))
        try Data("@echo off\n".utf8).write(to: releaseRoot.appendingPathComponent("Run Me!.bat"))

        // Deliberately large redistributable installer to ensure helper filtering beats file size.
        try Data(repeating: 0x5A, count: 8192)
            .write(to: redistDir.appendingPathComponent("PhysX_9.08.14_9.09.0814_SystemSoftware.exe"))
        try Data(repeating: 0x5A, count: 4096).write(to: redistDir.appendingPathComponent("vcredist_x86.exe"))
        try Data(repeating: 0x5A, count: 4096).write(to: redistDir.appendingPathComponent("DXWebSetup.exe"))

        let expectedEXE = innerGameDir.appendingPathComponent("Pentiment.exe")
        try Data(repeating: 0x4D, count: 64).write(to: expectedEXE)
        try Data("480\n".utf8).write(to: innerGameDir.appendingPathComponent("steam_appid.txt"))
        try Data("[Settings]\n;AppId=999999\nAppId=1205520\nUserName=AnkerGames\n".utf8)
            .write(to: pluginDir.appendingPathComponent("steam_emu.ini"))

        let inspection = try #require(GameDirectoryInspector.inspect(directory: releaseRoot.path))
        #expect(inspection.resolvedTitle == "Pentiment")
        #expect(inspection.existingAppID == "1205520")
        #expect(inspection.mainExecutable == expectedEXE.path)
        #expect(!inspection.candidateExecutables.contains(where: { $0.contains("Redist") }))

        let imported = try #require(
            await DefaultWorkflowServices().inspectGameForImport(
                at: releaseRoot,
                bottlesDirectory: tmpDir.appendingPathComponent("Bottles").path
            )
        )
        #expect(imported.title == "Pentiment")
        #expect(imported.appID == "1205520")
        #expect(imported.exePath == expectedEXE.path)
    }

    @Test
    func testGameDirectoryInspectorHandlesFlatUnityUnrealAndPreservesDistinctTitles() throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory
            .appendingPathComponent("chrysa-inspector-variants-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // 1. Unreal layout with sibling Engine/ and Binaries/Win64
        let unrealRoot = tmpDir.appendingPathComponent("CoolGame-SomeGroup", isDirectory: true)
        let unrealBinDir = unrealRoot.appendingPathComponent("CoolGame/Binaries/Win64", isDirectory: true)
        try fm.createDirectory(at: unrealRoot.appendingPathComponent("Engine", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: unrealBinDir, withIntermediateDirectories: true)
        let unrealEXE = unrealBinDir.appendingPathComponent("CoolGame-Win64-Shipping.exe")
        try Data("exe".utf8).write(to: unrealEXE)
        let unrealInspection = try #require(GameDirectoryInspector.inspect(directory: unrealRoot.path))
        #expect(unrealInspection.resolvedTitle == "CoolGame")
        #expect(unrealInspection.mainExecutable == unrealEXE.path)

        // 2. Flat Unity folder with trailing repack tag + MonoBleedingEdge dir
        let flatUnity = tmpDir.appendingPathComponent("Hollow Knight-RepackTeam", isDirectory: true)
        try fm.createDirectory(at: flatUnity.appendingPathComponent("hollow_knight_Data", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: flatUnity.appendingPathComponent("MonoBleedingEdge", isDirectory: true), withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: flatUnity.appendingPathComponent("hollow_knight.exe"))
        let flatInspection = try #require(GameDirectoryInspector.inspect(directory: flatUnity.path))
        #expect(flatInspection.resolvedTitle == "Hollow Knight")

        // 3. Multi-word clean folder title with mismatched exe stem + Content/MonoBleedingEdge folders
        let sinkingRoot = tmpDir.appendingPathComponent("Order of the Sinking Star", isDirectory: true)
        try fm.createDirectory(at: sinkingRoot.appendingPathComponent("MonoBleedingEdge", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: sinkingRoot.appendingPathComponent("Content", isDirectory: true), withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: sinkingRoot.appendingPathComponent("sinking_star.exe"))
        let sinkingInspection = try #require(GameDirectoryInspector.inspect(directory: sinkingRoot.path))
        #expect(sinkingInspection.resolvedTitle == "Order of the Sinking Star")

        // 4. Explicit Spacewar 480 + generic "Game.exe" preservation
        let manualRoot = tmpDir.appendingPathComponent("Manual Game", isDirectory: true)
        try fm.createDirectory(at: manualRoot, withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: manualRoot.appendingPathComponent("Game.exe"))
        try Data("480\n".utf8).write(to: manualRoot.appendingPathComponent("steam_appid.txt"))
        let manualInspection = try #require(GameDirectoryInspector.inspect(directory: manualRoot.path))
        #expect(manualInspection.resolvedTitle == "Manual Game")
        #expect(manualInspection.existingAppID == "480")

        // 5. INI comment skipping + inline comment trimming
        let codexINI = manualRoot.appendingPathComponent("codex.ini")
        try Data(";AppId=999999\n#AppId=888888\n[Settings]\nAppId = 367520 ; Hollow Knight\n".utf8).write(to: codexINI)
        #expect(GameDirectoryInspector.parseEmulatorINIAppID(atPath: codexINI.path) == "367520")
    }

    @Test
    func testNewHostResolversPixeldrainAccelerationAndHTTPProbeGuard() throws {
        // 1. Bare URL normalization for newly added shield-free hosts
        #expect(HostResolverRegistry.normalizeDownloadInput("datanodes.to/abc123/Game.7z") == "https://datanodes.to/abc123/Game.7z")
        #expect(HostResolverRegistry.normalizeDownloadInput("qiwi.gg/file/xyz987") == "https://qiwi.gg/file/xyz987")
        #expect(HostResolverRegistry.normalizeDownloadInput("workupload.com/file/AbCd1234") == "https://workupload.com/file/AbCd1234")
        #expect(HostResolverRegistry.normalizeDownloadInput("krakenfiles.com/view/hAsH01/file.html") == "https://krakenfiles.com/view/hAsH01/file.html")

        // 2. DataNodes HTML form + direct link parsing
        let dnHTML = """
        <html><head><title>Download Elder_Pack.7z | DataNodes</title></head>
        <body>
        <form method="POST" action="https://datanodes.to/download">
          <input type="hidden" name="op" value="download2">
          <input type="hidden" name="id" value="abc123">
          <input type="hidden" name="rand" value="r99">
          <input type="hidden" name="method_free" value="Free Download">
        </form>
        </body></html>
        """
        let dnURL = try #require(URL(string: "https://datanodes.to/abc123/Elder_Pack.7z"))
        #expect(DataNodesResolver.extractFilename(from: dnHTML) == "Elder_Pack.7z")
        let dnForm = try #require(DataNodesResolver.parseDownloadForm(html: dnHTML, baseURL: dnURL.absoluteString, url: dnURL))
        #expect(dnForm.actionURL == "https://datanodes.to/download")
        #expect(dnForm.formBody.contains("op=download2"))
        #expect(dnForm.formBody.contains("id=abc123"))
        #expect(
            DataNodesResolver.extractDirectLink(fromJSONOrHTML: #"{"url":"https://dl3.datanodes.to/d/tok123/Elder_Pack.7z"}"#)
                == "https://dl3.datanodes.to/d/tok123/Elder_Pack.7z"
        )

        // 3. Qiwi.gg HTML / Spyderrock candidate parsing
        let qiwiHTML = """
        <html><head><title>Indie_Build.rar - qiwi.gg</title></head>
        <body><h1 class="TextHeading">Indie_Build.rar</h1>
        <script>{"slug":"abcSlug9","downloadUrl":"https://spyderrock.com/abcSlug9.rar"}</script>
        </body></html>
        """
        let qiwiURL = try #require(URL(string: "https://qiwi.gg/file/abcSlug9"))
        let qiwiParsed = QiwiResolver.parsePage(html: qiwiHTML, originalURL: qiwiURL)
        #expect(qiwiParsed.filename == "Indie_Build.rar")
        #expect(qiwiParsed.candidateURLs.contains("https://spyderrock.com/abcSlug9.rar"))

        // 4. Workupload ID + server JSON + filename parsing
        let wuURL = try #require(URL(string: "https://workupload.com/file/WU9876"))
        #expect(WorkuploadResolver.extractFileID(from: wuURL) == "WU9876")
        let wuJSON = Data(#"{"success":true,"data":{"url":"https://srv12.workupload.com/download/WU9876/token99"}}"#.utf8)
        #expect(WorkuploadResolver.parseDownloadServerJSON(wuJSON) == "https://srv12.workupload.com/download/WU9876/token99")
        #expect(WorkuploadResolver.extractFilename(from: "<html><title>ModPack.zip - workupload</title></html>") == "ModPack.zip")

        // 5. KrakenFiles form token + JSON download URL parsing
        let kfHTML = """
        <html><head><title>Soundtrack.zip - Krakenfiles</title></head>
        <body><form id="dl-form" action="/download/kHash42" method="post">
          <input type="hidden" name="token" value="tok-kf-888">
        </form></body></html>
        """
        let kfURL = try #require(URL(string: "https://krakenfiles.com/view/kHash42/file.html"))
        let kfParsed = try #require(KrakenFilesResolver.parseLandingPage(html: kfHTML, url: kfURL))
        #expect(kfParsed.actionURL == "https://krakenfiles.com/download/kHash42")
        #expect(kfParsed.token == "tok-kf-888")
        #expect(kfParsed.filename == "Soundtrack.zip")
        #expect(
            KrakenFilesResolver.parseDownloadJSON(Data(#"{"status":"ok","url":"//s5.krakenfiles.com/get/kHash42/dl"}"#.utf8))
                == "https://s5.krakenfiles.com/get/kHash42/dl"
        )

        // 6. Pixeldrain rate-limit detection + Basic Auth header & Real-Debrid parsing
        let pdLimited = PixeldrainResolver.parseFileInfoJSON(
            Data(#"{"name":"Demo.7z","size":2048,"availability":"file_rate_limited","download_speed_limit":1048576}"#.utf8),
            hasAPIKey: false
        )
        #expect(pdLimited.name == "Demo.7z")
        #expect(pdLimited.rateLimitNote == "限速 1MB/s")
        #expect(pdLimited.failureReason == nil)

        let pdWithKey = PixeldrainResolver.parseFileInfoJSON(
            Data(#"{"name":"Demo.7z","size":2048,"availability":"file_rate_limited","download_speed_limit":1048576}"#.utf8),
            hasAPIKey: true
        )
        #expect(pdWithKey.rateLimitNote == nil)
        #expect(PixeldrainResolver.basicAuthHeaderValue(for: "secret")?.hasPrefix("Basic ") == true)

        let rdResolved = try #require(
            DebridAccelerator.parseRealDebridJSON(
                Data(#"{"filename":"RD_Game.7z","filesize":999999,"download":"https://rd.example/d/RD_Game.7z"}"#.utf8),
                originalURL: "https://1fichier.com/?rd1"
            )
        )
        #expect(rdResolved.finalURL == "https://rd.example/d/RD_Game.7z")
        #expect(rdResolved.suggestedFilename == "RD_Game.7z")

        // 7. Proxy env sanitization & fake-payload probe guard
        let cleanedEnv = ResolverHTTPHelper.cleanedDirectEnvironment()
        #expect(cleanedEnv["http_proxy"] == nil)
        #expect(cleanedEnv["https_proxy"] == nil)
        #expect(cleanedEnv["all_proxy"] == nil)
        #expect(cleanedEnv["HTTP_PROXY"] == nil)
        #expect(cleanedEnv["HTTPS_PROXY"] == nil)
        #expect(cleanedEnv["ALL_PROXY"] == nil)

        let rawHTMLCurlDump = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<html><title>Just a moment...</title></html>\n__CHRYSA_EFFECTIVE_URL__:https://example.invalid/dl__CHRYSA_STATUS__:200".utf8)
        let htmlFakeProbe = try #require(
            ResolverHTTPHelper.parseCurlDumpedOutput(rawHTMLCurlDump, fallbackURL: "https://example.invalid/dl")
        )
        #expect(ResolverHTTPHelper.validateDownloadProbe(htmlFakeProbe) != nil)
    }

    @Test
    func testDownloadServiceExpiredDirectLinkRefreshAndMirrorFallbackEndToEnd() async throws {
        guard ToolchainLocator.locateDownloadEngineBinary() != nil else { return }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-dl-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let portFile = tmpDir.appendingPathComponent("port.txt")
        let serverScript = """
        import http.server, socketserver, sys
        payload = b'CHRYSA_PAYLOAD_' * 512
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_HEAD(self):
                if self.path == '/expired.bin':
                    self.send_response(403); self.end_headers()
                elif self.path == '/quota.bin':
                    self.send_response(429); self.end_headers()
                elif self.path == '/aria_expired.bin':
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(payload)))
                    self.send_header('Accept-Ranges', 'bytes')
                    self.end_headers()
                elif self.path in ('/fresh.bin', '/mirror_ok.bin'):
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(payload)))
                    self.send_header('Accept-Ranges', 'bytes')
                    self.end_headers()
                else:
                    self.send_response(404); self.end_headers()
            def do_GET(self):
                if self.path == '/expired.bin':
                    self.send_response(403); self.end_headers()
                elif self.path == '/quota.bin':
                    self.send_response(429); self.end_headers()
                elif self.path == '/aria_expired.bin':
                    if self.headers.get('Range') == 'bytes=0-0':
                        self.send_response(206)
                        self.send_header('Content-Length', '1')
                        self.send_header('Content-Range', f'bytes 0-0/{len(payload)}')
                        self.end_headers()
                        self.wfile.write(payload[:1])
                    else:
                        self.send_response(403); self.end_headers()
                elif self.path in ('/fresh.bin', '/mirror_ok.bin'):
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(payload)))
                    self.send_header('Accept-Ranges', 'bytes')
                    self.end_headers()
                    self.wfile.write(payload)
                else:
                    self.send_response(404); self.end_headers()
        with socketserver.TCPServer(('127.0.0.1', 0), Handler) as httpd:
            with open(sys.argv[1], 'w') as f:
                f.write(str(httpd.server_address[1]))
            httpd.serve_forever()
        """
        let scriptURL = tmpDir.appendingPathComponent("mock_server.py")
        try serverScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [scriptURL.path, portFile.path]
        try server.run()
        defer { if server.isRunning { server.terminate() } }

        var port: Int?
        let deadline = Date().addingTimeInterval(5)
        while port == nil && Date() < deadline {
            if let s = try? String(contentsOf: portFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let p = Int(s), p > 0 {
                port = p
                break
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        let listenPort = try #require(port)

        // Direct connectivity pre-probe under smart routing against local server
        let routeCheck = await ResolverHTTPHelper.resolveProxyRoute(
            for: "http://127.0.0.1:\(listenPort)/fresh.bin",
            policy: .smart
        )
        #expect(routeCheck.route == .direct)
        #expect(routeCheck.probe?.statusCode == 200)
        #expect(routeCheck.probe?.contentLength == Int64("CHRYSA_PAYLOAD_".utf8.count * 512))

        let dlDir = tmpDir.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: dlDir, withIntermediateDirectories: true)
        var settings = AppSettings.default
        settings.downloadDirectory = dlDir.path
        settings.proxyPolicy = .directOnly
        settings.maxConcurrentConnections = 2

        let service = DownloadService()

        // Scenario A: 403 expired direct link triggers auto-refresh via originalURL
        let refreshLogs = ActorBox<String>([])
        let refreshDiags = ActorBox<String>([])
        let resA = await service.executeDownload(
            taskID: UUID(),
            currentTitle: "refresh_test.bin",
            resolved: ResolvedDownload(
                originalURL: "https://origin.example/share-refresh",
                finalURL: "http://127.0.0.1:\(listenPort)/expired.bin",
                headers: [],
                suggestedFilename: "refresh_test.bin"
            ),
            settings: settings,
            stagingJobID: UUID(),
            stagingSubkey: nil,
            refreshHandler: { item, _ in
                HostResolutionResult(downloads: [
                    ResolvedDownload(
                        originalURL: item.originalURL,
                        finalURL: "http://127.0.0.1:\(listenPort)/fresh.bin",
                        headers: [],
                        suggestedFilename: "refresh_test.bin"
                    )
                ])
            },
            isCancelled: { false },
            onProgress: { _ in },
            onLog: { msg, _ in await refreshLogs.append(msg) },
            onDiagnostic: { diag in await refreshDiags.append(diag.message) }
        )
        switch resA {
        case .completed(let outPath, _, _):
            let data = try Data(contentsOf: URL(fileURLWithPath: outPath))
            #expect(data.count == "CHRYSA_PAYLOAD_".utf8.count * 512)
            #expect(String(data: data.prefix(15), encoding: .utf8) == "CHRYSA_PAYLOAD_")
        default:
            Issue.record("Expected expired 403 link to auto-refresh and succeed")
        }
        #expect(await refreshDiags.snapshot().contains(where: { $0.contains("正在从原分享页刷新") }))
        #expect(await refreshLogs.snapshot().contains(where: { $0.contains("直链已刷新") }))

        // Scenario B: 429 quota/rate-limit falls back automatically to backup mirror
        let mirrorDiags = ActorBox<String>([])
        let resB = await service.executeDownload(
            taskID: UUID(),
            currentTitle: "mirror_test.bin",
            resolved: ResolvedDownload(
                originalURL: "http://127.0.0.1:\(listenPort)/quota.bin",
                finalURL: "http://127.0.0.1:\(listenPort)/quota.bin",
                mirrorURLs: ["https://mirror.example/file-ok"],
                headers: [],
                suggestedFilename: "mirror_test.bin"
            ),
            settings: settings,
            stagingJobID: UUID(),
            stagingSubkey: nil,
            mirrorResolveHandler: { mirrorURL, _ in
                if mirrorURL == "https://mirror.example/file-ok" {
                    return HostResolutionResult(downloads: [
                        ResolvedDownload(
                            originalURL: mirrorURL,
                            finalURL: "http://127.0.0.1:\(listenPort)/mirror_ok.bin",
                            headers: [],
                            suggestedFilename: "mirror_test.bin"
                        )
                    ])
                }
                return HostResolutionResult(downloads: [])
            },
            isCancelled: { false },
            onProgress: { _ in },
            onLog: { _, _ in },
            onDiagnostic: { diag in await mirrorDiags.append(diag.message) }
        )
        switch resB {
        case .completed(let outPath, _, _):
            let data = try Data(contentsOf: URL(fileURLWithPath: outPath))
            #expect(data.count == "CHRYSA_PAYLOAD_".utf8.count * 512)
        default:
            Issue.record("Expected 429 primary to switch to backup mirror and succeed")
        }
        #expect(await mirrorDiags.snapshot().contains(where: { $0.contains("切换备用镜像") }))

        // Scenario C: aria2c itself hits 403 mid-download -> preserves staging dir & auto-refreshes
        let ariaRefreshLogs = ActorBox<String>([])
        let ariaRefreshDiags = ActorBox<String>([])
        let resC = await service.executeDownload(
            taskID: UUID(),
            currentTitle: "aria_refresh_test.bin",
            resolved: ResolvedDownload(
                originalURL: "https://origin.example/aria-share",
                finalURL: "http://127.0.0.1:\(listenPort)/aria_expired.bin",
                headers: [],
                suggestedFilename: "aria_refresh_test.bin"
            ),
            settings: settings,
            stagingJobID: UUID(),
            stagingSubkey: nil,
            refreshHandler: { item, _ in
                HostResolutionResult(downloads: [
                    ResolvedDownload(
                        originalURL: item.originalURL,
                        finalURL: "http://127.0.0.1:\(listenPort)/fresh.bin",
                        headers: [],
                        suggestedFilename: "aria_refresh_test.bin"
                    )
                ])
            },
            isCancelled: { false },
            onProgress: { _ in },
            onLog: { msg, _ in await ariaRefreshLogs.append(msg) },
            onDiagnostic: { diag in await ariaRefreshDiags.append(diag.message) }
        )
        switch resC {
        case .completed(let outPath, _, _):
            let data = try Data(contentsOf: URL(fileURLWithPath: outPath))
            #expect(data.count == "CHRYSA_PAYLOAD_".utf8.count * 512)
        default:
            Issue.record("Expected aria2c 403 exit to trigger direct link auto-refresh and succeed")
        }
        #expect(await ariaRefreshDiags.snapshot().contains(where: { $0.contains("正在从原分享页刷新并延续进度") }))
        #expect(await ariaRefreshLogs.snapshot().contains(where: { $0.contains("沿用 .aria2 进度继续续传") }))
    }

    @Test
    func testSteamDLLAuthenticodeTriagePreservesPreCrackedAndDRMFreeBuilds() async throws {
        func writeU16LE(_ v: UInt16, into buf: inout Data, at off: Int) {
            buf[off] = UInt8(v & 0xFF)
            buf[off + 1] = UInt8((v >> 8) & 0xFF)
        }
        func writeU32LE(_ v: UInt32, into buf: inout Data, at off: Int) {
            buf[off] = UInt8(v & 0xFF)
            buf[off + 1] = UInt8((v >> 8) & 0xFF)
            buf[off + 2] = UInt8((v >> 16) & 0xFF)
            buf[off + 3] = UInt8((v >> 24) & 0xFF)
        }
        func makeSyntheticPE64(imageSize: Int = 65_536, signerText: String? = nil, extraMarker: String? = nil) -> Data {
            var img = Data(repeating: 0, count: max(imageSize, 0x600))
            let peOff = 0x80
            let optStart = peOff + 24
            let checksumOff = optStart + 64
            let certDirOff = optStart + 112 + 32

            writeU16LE(0x5A4D, into: &img, at: 0)              // "MZ"
            writeU32LE(UInt32(peOff), into: &img, at: 0x3C)    // e_lfanew
            writeU32LE(0x0000_4550, into: &img, at: peOff)     // "PE\0\0"
            writeU16LE(1, into: &img, at: peOff + 6)           // NumberOfSections = 1
            writeU16LE(240, into: &img, at: peOff + 20)        // SizeOfOptionalHeader = 240
            writeU16LE(0x020B, into: &img, at: optStart)       // PE32+
            writeU32LE(16, into: &img, at: optStart + 108)     // NumberOfRvaAndSizes = 16

            // Single .text section at file offset 0x200
            let secOff = optStart + 240
            writeU32LE(0x200, into: &img, at: secOff + 8)      // VirtualSize
            writeU32LE(0x1000, into: &img, at: secOff + 12)    // VirtualAddress
            writeU32LE(0x200, into: &img, at: secOff + 16)     // SizeOfRawData
            writeU32LE(0x200, into: &img, at: secOff + 20)     // PointerToRawData
            img[0x200] = 0xC3                                  // ret instruction

            if let marker = extraMarker {
                let mBytes = Data(marker.utf8)
                img.replaceSubrange(0x240 ..< (0x240 + mBytes.count), with: mBytes)
            }

            guard let signerText else {
                return img
            }

            var sha = SHA256()
            sha.update(data: img[0 ..< checksumOff])
            sha.update(data: img[(checksumOff + 4) ..< certDirOff])
            sha.update(data: img[(certDirOff + 8) ..< img.count])
            let digest = Data(sha.finalize())

            var certBody = Data(signerText.utf8)
            certBody.append(0)
            certBody.append(digest)
            while (8 + certBody.count) % 8 != 0 {
                certBody.append(0)
            }
            let certTotalLen = 8 + certBody.count
            let certFileOff = img.count
            writeU32LE(UInt32(certFileOff), into: &img, at: certDirOff)
            writeU32LE(UInt32(certTotalLen), into: &img, at: certDirOff + 4)

            var certHeader = Data(repeating: 0, count: 8)
            writeU32LE(UInt32(certTotalLen), into: &certHeader, at: 0)
            writeU16LE(0x0200, into: &certHeader, at: 4)
            writeU16LE(0x0002, into: &certHeader, at: 6)       // WIN_CERT_TYPE_PKCS_SIGNED_DATA
            img.append(certHeader)
            img.append(certBody)
            return img
        }

        // 1. Binary signature triage unit checks
        let genuineValveDLL = makeSyntheticPE64(signerText: "CN=Valve Corp., O=Valve Corp., Issuer=DigiCert Trusted G4 Code Signing RSA4096")
        #expect(PEBinaryInspector.classifySteamDLL(data: genuineValveDLL) == .officialValve)

        var tamperedValveDLL = genuineValveDLL
        tamperedValveDLL[0x200] ^= 0xFF // Modify 1 byte in .text while keeping Valve PKCS#7 trailer intact
        #expect(PEBinaryInspector.classifySteamDLL(data: tamperedValveDLL) == .thirdPartyEmulator)

        let selfSignedFakeValve = makeSyntheticPE64(signerText: "CN=Valve Corp., Issuer=SelfSigned Local")
        #expect(PEBinaryInspector.classifySteamDLL(data: selfSignedFakeValve) == .thirdPartyEmulator)

        let unsignedRuneDLL = makeSyntheticPE64(imageSize: 380_000)
        #expect(PEBinaryInspector.classifySteamDLL(data: unsignedRuneDLL) == .thirdPartyEmulator)

        let gbeSignedDLL = makeSyntheticPE64(signerText: "CN=GSE1, O=GSE0")
        #expect(PEBinaryInspector.classifySteamDLL(data: gbeSignedDLL) == .goldberg)

        // 2. End-to-end PatchService triage: Pre-cracked RUNE / TENOKE folder preserves DLL & syncs INI language
        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory.appendingPathComponent("chrysa-triage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpRoot) }

        var settings = AppSettings.default
        settings.patch.defaultLanguage = .schinese
        settings.patch.bottlesDirectory = tmpRoot.appendingPathComponent("absent-bottles").path
        let patchSvc = PatchService()

        let runeDir = tmpRoot.appendingPathComponent("Ghost of Tsushima", isDirectory: true)
        try fm.createDirectory(at: runeDir, withIntermediateDirectories: true)
        try makeSyntheticPE64(imageSize: 90_000, extraMarker: "steam_api64.dll").write(to: runeDir.appendingPathComponent("GhostOfTsushima.exe"))
        let runeDLLURL = runeDir.appendingPathComponent("steam_api64.dll")
        try unsignedRuneDLL.write(to: runeDLLURL)
        try "[Settings]\r\nAppId=2215430\r\nLanguage=english\r\n".write(
            to: runeDir.appendingPathComponent("steam_emu.ini"),
            atomically: true,
            encoding: .utf8
        )
        try "language = \"english\" # default locale\n".write(
            to: runeDir.appendingPathComponent("tenoke.ini"),
            atomically: true,
            encoding: .utf8
        )

        let runeResult = try await patchSvc.executePatch(
            taskID: UUID(),
            folderPath: runeDir.path,
            cleanTitle: "Ghost of Tsushima",
            settings: settings,
            onLog: { _, _ in }
        )
        #expect(runeResult.pill == "原包已修补 x64")
        #expect(runeResult.appID == "2215430")
        #expect(try Data(contentsOf: runeDLLURL) == unsignedRuneDLL)
        #expect(!fm.fileExists(atPath: runeDir.appendingPathComponent("steam_api64.dll.bak").path))
        #expect(!fm.fileExists(atPath: runeDir.appendingPathComponent("steam_settings").path))
        let updatedRuneINI = try String(contentsOf: runeDir.appendingPathComponent("steam_emu.ini"), encoding: .utf8)
        #expect(updatedRuneINI.contains("Language=schinese\r\n"))
        let updatedTenokeINI = try String(contentsOf: runeDir.appendingPathComponent("tenoke.ini"), encoding: .utf8)
        #expect(updatedTenokeINI == "language = \"schinese\" # default locale\n")

        // 3. End-to-end PatchService triage: DRM-free / GOG standalone game skips unnecessary DLL injection
        let gogDir = tmpRoot.appendingPathComponent("Cyberpunk DRMFree", isDirectory: true)
        try fm.createDirectory(at: gogDir, withIntermediateDirectories: true)
        try makeSyntheticPE64(imageSize: 80_000).write(to: gogDir.appendingPathComponent("Cyberpunk2077.exe"))

        let gogResult = try await patchSvc.executePatch(
            taskID: UUID(),
            folderPath: gogDir.path,
            cleanTitle: "Cyberpunk 2077",
            settings: settings,
            onLog: { _, _ in }
        )
        #expect(gogResult.pill == "免补丁直装 x64")
        #expect(!fm.fileExists(atPath: gogDir.appendingPathComponent("steam_api64.dll").path))
        #expect(!fm.fileExists(atPath: gogDir.appendingPathComponent("steam_settings").path))

        // 4. Genuine Valve-signed DLL is backed up and replaced when Goldberg runtime DLL is present
        if ToolchainLocator.locateGbeDLL(is64Bit: true) != nil {
            let csfDir = tmpRoot.appendingPathComponent("Hades II CSF", isDirectory: true)
            try fm.createDirectory(at: csfDir, withIntermediateDirectories: true)
            try makeSyntheticPE64(imageSize: 80_000, extraMarker: "steam_api64.dll").write(to: csfDir.appendingPathComponent("Hades2.exe"))
            let csfDLLURL = csfDir.appendingPathComponent("steam_api64.dll")
            try genuineValveDLL.write(to: csfDLLURL)
            try "1145350\n".write(to: csfDir.appendingPathComponent("steam_appid.txt"), atomically: true, encoding: .utf8)

            let csfResult = try await patchSvc.executePatch(
                taskID: UUID(),
                folderPath: csfDir.path,
                cleanTitle: "Hades II",
                settings: settings,
                onLog: { _, _ in }
            )
            #expect(csfResult.pill == "Goldberg x64")
            #expect(try Data(contentsOf: csfDir.appendingPathComponent("steam_api64.dll.bak")) == genuineValveDLL)
            #expect(try Data(contentsOf: csfDLLURL) != genuineValveDLL)
            #expect(fm.fileExists(atPath: csfDir.appendingPathComponent("steam_settings/configs.user.ini").path))
        }
    }

    @MainActor
    @Test
    func testMascotThemePersistenceProgressSummaryAndIntakeAlignment() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-mascot-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let settingsURL = tmpDir.appendingPathComponent("settings.json")
        let store = AppSettingsStore(customFileURL: settingsURL)
        let jobStore = JobStore(inMemoryOnly: true)
        let coordinator = PipelineCoordinator(
            services: DefaultWorkflowServices(),
            jobStore: jobStore,
            gameLibrary: LaunchGameStore(inMemoryOnly: true)
        )
        let vm = StudioViewModel(
            inMemoryOnly: true,
            settingsStore: store,
            taskStore: TaskStore(inMemoryOnly: true),
            coordinator: coordinator
        )

        #expect(vm.mascotTheme == .forestCube)
        #expect(abs(MascotController.slotAlignOffsetX(for: .forestCube) - 2.7) < 0.001)
        #expect(MascotController.slotAlignOffsetX(for: .roundMochi) == 0)
        #expect(MascotController.slotAlignOffsetX(for: .grokAstral) == 0)

        vm.setMascotTheme(.roundMochi)
        store.flushPendingPersistence()
        let reloadedStore = AppSettingsStore(customFileURL: settingsURL)
        #expect(reloadedStore.settings.mascotTheme == .roundMochi)

        // Pipeline progress summary tracks running -> paused -> completed states
        #expect(vm.activePipelineProgressSummary.progress == nil)
        #expect(vm.activePipelineProgressSummary.isPaused)

        let dlJob = Job(kind: .download, title: "Silksong.7z", status: .running, progress: 0.64)
        await coordinator.addJob(dlJob)
        try await Task.sleep(nanoseconds: 25_000_000)
        let runningSummary = vm.activePipelineProgressSummary
        #expect(abs((runningSummary.progress ?? 0) - 0.64) < 0.01)
        #expect(!runningSummary.isPaused)

        await coordinator.updateJob(dlJob.id, status: .paused)
        try await Task.sleep(nanoseconds: 25_000_000)
        let pausedSummary = vm.activePipelineProgressSummary
        #expect(abs((pausedSummary.progress ?? 0) - 0.64) < 0.01)
        #expect(pausedSummary.isPaused)

        await coordinator.updateJob(dlJob.id, status: .succeeded, progress: 1.0)
        try await Task.sleep(nanoseconds: 25_000_000)
        #expect(vm.activePipelineProgressSummary.progress == nil)
    }
}

private actor ActorBox<T: Sendable> {
    private var items: [T]
    init(_ items: [T]) { self.items = items }
    func append(_ item: T) { items.append(item) }
    func snapshot() -> [T] { items }
}
