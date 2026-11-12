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

        // Rescanning bottles afterwards must add 0 duplicates
        let coordinator = PipelineCoordinator(services: DefaultWorkflowServices(), jobStore: reloaded)
        let added = await coordinator.addDiscoveredBottles([scannedRimWorld, scannedParabox])
        #expect(added == 0)
    }

}
