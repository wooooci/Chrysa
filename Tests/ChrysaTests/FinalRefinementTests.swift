import ChrysaAdapters
import ChrysaApplication
import ChrysaCore
import CryptoKit
import Foundation
import Testing

struct FinalRefinementTests {
    // MARK: - 1. Launch Library Complete Uninstall & PathSafety Guardrails

    @MainActor
    @Test
    func testLaunchGameCompleteUninstallMovesArtifactsToTrashAndCleansCaches() async throws {
        let fm = FileManager.default
        let root = try makeTempDir(prefix: "chrysa-uninstall-full")
        defer { try? fm.removeItem(at: root) }

        var trashCleanupURLs: [URL] = []
        defer {
            for url in trashCleanupURLs {
                try? fm.removeItem(at: url)
            }
        }

        let bottlesRoot = root.appendingPathComponent("Bottles", isDirectory: true)
        let cxAppsDir = root.appendingPathComponent("CrossOverApps", isDirectory: true)
        let downloadDir = root.appendingPathComponent("Downloads", isDirectory: true)
        let snapshotsRoot = root.appendingPathComponent("Snapshots", isDirectory: true)
        let iconsCacheDir = root.appendingPathComponent("IconCache", isDirectory: true)
        let customIconsDir = root.appendingPathComponent("CustomIcons", isDirectory: true)
        let externalGameDir = downloadDir.appendingPathComponent("EldenQuest", isDirectory: true)

        try fm.createDirectory(at: bottlesRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: cxAppsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: externalGameDir, withIntermediateDirectories: true)

        let mainExe = externalGameDir.appendingPathComponent("EldenQuest.exe")
        try Data("PE-GAME".utf8).write(to: mainExe)

        // Dedicated CrossOver bottle with drive_c/<BottleName> symlink + game Start Menu shortcut
        let bottleDir = bottlesRoot.appendingPathComponent("EldenQuest", isDirectory: true)
        let driveC = bottleDir.appendingPathComponent("drive_c", isDirectory: true)
        let startMenu = driveC.appendingPathComponent("users/crossover/AppData/Roaming/Microsoft/Windows/Start Menu", isDirectory: true)
        try fm.createDirectory(at: startMenu, withIntermediateDirectories: true)
        try "[EnvironmentVariables]\n".write(to: bottleDir.appendingPathComponent("cxbottle.conf"), atomically: true, encoding: .utf8)
        try "WINE REGISTRY Version 2\n".write(to: bottleDir.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: driveC.appendingPathComponent("EldenQuest"), withDestinationURL: externalGameDir)
        try Data("lnk".utf8).write(to: startMenu.appendingPathComponent("EldenQuest.lnk"))
        try Data("lnk".utf8).write(to: startMenu.appendingPathComponent("Uninstall EldenQuest.lnk"))

        // CrossOver menu helper .app bundle
        let helperApp = cxAppsDir.appendingPathComponent("EldenQuest.app", isDirectory: true)
        try fm.createDirectory(at: helperApp.appendingPathComponent("Contents", isDirectory: true), withIntermediateDirectories: true)
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleName": "EldenQuest",
                "CXHelperAppBottleName": "EldenQuest"
            ],
            format: .xml,
            options: 0
        )
        try plistData.write(to: helperApp.appendingPathComponent("Contents/Info.plist"))

        // Custom icon + snapshot setup
        try fm.createDirectory(at: customIconsDir, withIntermediateDirectories: true)
        let customIconFile = customIconsDir.appendingPathComponent("custom.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: customIconFile)

        let game = LaunchGame(
            title: "EldenQuest",
            exePath: mainExe.path,
            gameDirectory: externalGameDir.path,
            bottleName: "EldenQuest",
            source: .patchPipeline,
            customIconPath: customIconFile.path
        )

        let snapshotManager = GameSnapshotManager(storageRoot: snapshotsRoot)
        _ = try await snapshotManager.ensureBaselineSnapshot(for: game, bottlePath: bottleDir.path) { _, _ in }
        #expect(snapshotManager.hasSnapshot(for: game))

        let settings = AppSettings(
            download: DownloadSettings(downloadDirectory: downloadDir.path),
            patch: PatchSettings(bottlesDirectory: bottlesRoot.path)
        )

        // Check .recordOnly mode via PipelineCoordinator preserves local directory & bottle while clearing snapshot & library entry
        let gameLibraryRecordOnly = LaunchGameStore(inMemoryOnly: true)
        await gameLibraryRecordOnly.upsert(game, preferIncomingMetadata: true)
        let servicesRecordOnly = DefaultWorkflowServices(
            iconResolver: GameIconResolver(cacheDirectory: iconsCacheDir, customIconsDirectory: customIconsDir, crossOverAppsDirectory: cxAppsDir.path, allowNetworkFallback: false),
            snapshotManager: snapshotManager
        )
        let coordRecordOnly = PipelineCoordinator(
            services: servicesRecordOnly,
            jobStore: JobStore(inMemoryOnly: true),
            gameLibrary: gameLibraryRecordOnly
        )
        await coordRecordOnly.removeLaunchGame(game.id, mode: .recordOnly, settings: settings)
        #expect(await gameLibraryRecordOnly.all().isEmpty)
        #expect(!snapshotManager.hasSnapshot(for: game))
        #expect(fm.fileExists(atPath: externalGameDir.path))
        #expect(fm.fileExists(atPath: bottleDir.path))
        #expect(fm.fileExists(atPath: helperApp.path))

        // Now test full uninstall into Trash (and assert Wine termination fires BEFORE trashing!)
        let eventLog = StringArrayBox()
        let outcome = LaunchGameUninstaller.uninstall(
            game: game,
            knownGames: [game],
            settings: settings,
            crossOverAppsDirectory: cxAppsDir.path,
            trashHandler: { url in
                eventLog.append("trash:\(url.lastPathComponent)")
                let trashed = try LaunchGameUninstaller.defaultTrashItem(url)
                if let trashed {
                    trashCleanupURLs.append(trashed)
                }
                return trashed
            },
            wineTerminator: { bottlePath in
                eventLog.append("kill:\(URL(fileURLWithPath: bottlePath).lastPathComponent)")
            }
        )

        #expect(outcome.terminatedBottleName == "EldenQuest")
        #expect(outcome.skippedProtectedPaths.isEmpty)
        #expect(outcome.warnings.isEmpty)
        #expect(outcome.trashedPaths.count == 3)
        #expect(!fm.fileExists(atPath: externalGameDir.path))
        #expect(!fm.fileExists(atPath: bottleDir.path))
        #expect(!fm.fileExists(atPath: helperApp.path))

        let trace = eventLog.snapshot()
        #expect(trace.first == "kill:EldenQuest")
        #expect(Set(trace.dropFirst()) == Set(["trash:EldenQuest", "trash:EldenQuest.app"]))
    }

    @Test
    func testUninstallSafetyGuardsProtectSharedBottlesAndSystemDirectories() async throws {
        let fm = FileManager.default
        let root = try makeTempDir(prefix: "chrysa-uninstall-guard")
        defer { try? fm.removeItem(at: root) }

        var trashCleanupURLs: [URL] = []
        defer {
            for url in trashCleanupURLs {
                try? fm.removeItem(at: url)
            }
        }

        let bottlesRoot = root.appendingPathComponent("Bottles", isDirectory: true)
        let cxAppsDir = root.appendingPathComponent("CrossOverApps", isDirectory: true)
        let downloadsRoot = root.appendingPathComponent("CustomDownloads", isDirectory: true)
        try fm.createDirectory(at: bottlesRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: cxAppsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)

        let settings = AppSettings(
            download: DownloadSettings(downloadDirectory: downloadsRoot.path),
            patch: PatchSettings(bottlesDirectory: bottlesRoot.path)
        )

        // Guardrail A: Shared bottle named "Steam" must NEVER be terminated or trashed; external dir pointed to Downloads root must also be blocked.
        let steamBottle = bottlesRoot.appendingPathComponent("Steam", isDirectory: true)
        let steamGameInside = steamBottle.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps/common/SampleSteamGame", isDirectory: true)
        try fm.createDirectory(at: steamGameInside, withIntermediateDirectories: true)
        let steamExe = steamGameInside.appendingPathComponent("Sample.exe")
        try Data("PE".utf8).write(to: steamExe)

        let userRealDownloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? ("~/Downloads" as NSString).expandingTildeInPath
        #expect(LaunchGameUninstaller.isProtectedSystemOrRootDirectory(userRealDownloads))
        #expect(LaunchGameUninstaller.isProtectedSystemOrRootDirectory("~/Downloads"))
        #expect(LaunchGameUninstaller.isProtectedSystemOrRootDirectory(downloadsRoot.path, additionalProtectedRoots: [downloadsRoot.path]))
        #expect(LaunchGameUninstaller.isProtectedSystemOrRootDirectory("/"))
        #expect(LaunchGameUninstaller.isProtectedSystemOrRootDirectory(NSHomeDirectory()))

        let dangerGame = LaunchGame(
            title: "SampleSteamGame",
            exePath: steamExe.path,
            gameDirectory: userRealDownloads,
            bottleName: "Steam",
            source: .crossoverScan
        )

        let killedTracker = StringArrayBox()
        let steamOutcome = LaunchGameUninstaller.uninstall(
            game: dangerGame,
            knownGames: [dangerGame],
            settings: settings,
            crossOverAppsDirectory: cxAppsDir.path,
            trashHandler: { url in
                Issue.record("Must NOT trash protected path: \(url.path)")
                return nil
            },
            wineTerminator: { path in
                killedTracker.append(path)
            }
        )

        #expect(killedTracker.snapshot().isEmpty)
        #expect(steamOutcome.terminatedBottleName == nil)
        #expect(steamOutcome.trashedPaths.isEmpty)
        #expect(steamOutcome.skippedProtectedPaths.count >= 2)
        #expect(fm.fileExists(atPath: steamBottle.path))
        #expect(fm.fileExists(atPath: userRealDownloads))

        // Guardrail B: Bottle with another game directory in drive_c or another .app shortcut is treated as shared and preserved
        let multiBottle = bottlesRoot.appendingPathComponent("ActionRPG", isDirectory: true)
        let multiDriveC = multiBottle.appendingPathComponent("drive_c", isDirectory: true)
        try fm.createDirectory(at: multiDriveC.appendingPathComponent("OtherGameDir", isDirectory: true), withIntermediateDirectories: true)
        let ownGameDir = downloadsRoot.appendingPathComponent("ActionRPG", isDirectory: true)
        try fm.createDirectory(at: ownGameDir, withIntermediateDirectories: true)
        let ownExe = ownGameDir.appendingPathComponent("ActionRPG.exe")
        try Data("PE".utf8).write(to: ownExe)
        try fm.createSymbolicLink(at: multiDriveC.appendingPathComponent("ActionRPG"), withDestinationURL: ownGameDir)

        let multiGame = LaunchGame(
            title: "ActionRPG",
            exePath: ownExe.path,
            gameDirectory: ownGameDir.path,
            bottleName: "ActionRPG",
            source: .patchPipeline
        )
        let multiOutcome = LaunchGameUninstaller.uninstall(
            game: multiGame,
            knownGames: [multiGame],
            settings: settings,
            crossOverAppsDirectory: cxAppsDir.path,
            trashHandler: { url in
                let trashed = try LaunchGameUninstaller.defaultTrashItem(url)
                if let trashed { trashCleanupURLs.append(trashed) }
                return trashed
            },
            wineTerminator: { path in
                killedTracker.append(path)
            }
        )

        // External ownGameDir may be trashed, but the multi-game shared bottle is spared & not killed
        #expect(killedTracker.snapshot().isEmpty)
        #expect(multiOutcome.terminatedBottleName == nil)
        #expect(fm.fileExists(atPath: multiBottle.path))
        #expect(!fm.fileExists(atPath: ownGameDir.path))
        #expect(multiOutcome.skippedProtectedPaths.contains { $0.hasSuffix("/Bottles/ActionRPG") })

        // Guardrail C: Bottle with an unrelated .app helper pointing to it is also shared
        let shortcutBottle = bottlesRoot.appendingPathComponent("SoloTitle", isDirectory: true)
        try fm.createDirectory(at: shortcutBottle.appendingPathComponent("drive_c", isDirectory: true), withIntermediateDirectories: true)
        let otherHelperApp = cxAppsDir.appendingPathComponent("SecondGame.app", isDirectory: true)
        try fm.createDirectory(at: otherHelperApp.appendingPathComponent("Contents", isDirectory: true), withIntermediateDirectories: true)
        let otherPlist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleName": "SecondGame", "CXHelperAppBottleName": "SoloTitle"],
            format: .xml,
            options: 0
        )
        try otherPlist.write(to: otherHelperApp.appendingPathComponent("Contents/Info.plist"))

        let soloGame = LaunchGame(title: "SoloTitle", bottleName: "SoloTitle", source: .crossoverScan)
        let soloClass = LaunchGameUninstaller.classifyBottleSafety(
            bottleName: "SoloTitle",
            bottlePath: shortcutBottle.path,
            for: soloGame,
            knownGames: [soloGame],
            crossOverAppsDirectory: cxAppsDir.path
        )
        guard case .shared(_, _, _) = soloClass else {
            Issue.record("Expected bottle shared by SecondGame.app to be classified .shared")
            return
        }
    }

    // MARK: - 2. EAC / BattlEye Stub Bypass

    @MainActor
    @Test
    func testAntiCheatStubBypassElectionSteamAppIDAndDefaultArguments() async throws {
        let fm = FileManager.default
        let root = try makeTempDir(prefix: "chrysa-eac-bypass")
        defer { try? fm.removeItem(at: root) }

        // Stub checks directly
        #expect(LaunchGame.isAntiCheatHelperExecutable("start_protected_game.exe"))
        #expect(LaunchGame.isAntiCheatHelperExecutable("EasyAntiCheat/EasyAntiCheat_Launcher.exe"))
        #expect(LaunchGame.isAntiCheatHelperExecutable("Game/Binaries/Win64/Game_BE.exe"))
        #expect(LaunchGame.isAntiCheatHelperExecutable("BattlEye/BEService_x64.exe"))
        #expect(LaunchGame.isAntiCheatHelperExecutable("EAAntiCheat.GameServiceLauncher.exe"))
        #expect(!LaunchGame.isAntiCheatHelperExecutable("Game/Binaries/Win64/EldenRing.exe"))

        let gameRoot = root.appendingPathComponent("ShadowArena", isDirectory: true)
        let subBin = gameRoot.appendingPathComponent("Game", isDirectory: true)
        let eacDir = gameRoot.appendingPathComponent("EasyAntiCheat", isDirectory: true)
        try fm.createDirectory(at: subBin, withIntermediateDirectories: true)
        try fm.createDirectory(at: eacDir, withIntermediateDirectories: true)

        // Anti-cheat stubs at shallow depth & larger byte size than real game binary
        try Data(repeating: 0xAA, count: 8192).write(to: gameRoot.appendingPathComponent("start_protected_game.exe"))
        try Data(repeating: 0xBB, count: 4096).write(to: eacDir.appendingPathComponent("EasyAntiCheat_Launcher.exe"))
        try Data(repeating: 0xCC, count: 4096).write(to: gameRoot.appendingPathComponent("ShadowArena_BE.exe"))
        try Data(repeating: 0xDD, count: 4096).write(to: gameRoot.appendingPathComponent("BEService_x64.exe"))
        try Data(repeating: 0xEE, count: 4096).write(to: gameRoot.appendingPathComponent("EAAntiCheat.Installer.exe"))

        // Real game executable inside Game/ subdirectory with sibling pre-cracked/DRM-free or Goldberg behavior
        let realExe = subBin.appendingPathComponent("ShadowArena.exe")
        try makeMinimalPE64().write(to: realExe)

        let inspection = try #require(GameDirectoryInspector.inspect(directory: gameRoot.path))
        #expect(inspection.hasEasyAntiCheat)
        #expect(inspection.mainExecutable == realExe.path)
        #expect(!inspection.candidateExecutables.contains { $0.lowercased().contains("start_protected_game") })

        // Verify PatchService writes steam_appid.txt in real mainEXE dir & emits default "-eac-nop-loaded"
        let patchSvc = PatchService()
        let nonExistBottles = root.appendingPathComponent("NoBottles", isDirectory: true)
        let settings = AppSettings(patch: PatchSettings(bottlesDirectory: nonExistBottles.path, defaultLanguage: .schinese))

        let payload = try await patchSvc.executePatch(
            taskID: UUID(),
            folderPath: gameRoot.path,
            cleanTitle: "ShadowArena",
            settings: settings,
            onLog: { _, _ in }
        )
        #expect(payload.exePath == realExe.path)
        #expect(payload.defaultLaunchArguments == "-eac-nop-loaded")

        let appIdNextToRealExe = subBin.appendingPathComponent("steam_appid.txt")
        #expect(fm.fileExists(atPath: appIdNextToRealExe.path))
        let writtenAppID = try String(contentsOf: appIdNextToRealExe, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!writtenAppID.isEmpty)

        // Verify PipelineCoordinator attaches "-eac-nop-loaded" for fresh game, but preserves user custom arguments if already set
        let gameLibrary = LaunchGameStore(inMemoryOnly: true)
        let jobStore = JobStore(inMemoryOnly: true)
        let coordinator = PipelineCoordinator(
            services: DefaultWorkflowServices(patch: patchSvc),
            jobStore: jobStore,
            gameLibrary: gameLibrary
        )

        let patchJob1 = Job(kind: .patch, title: "ShadowArena", status: .queued, source: ArtifactRef(kind: .directory, value: gameRoot.path))
        await coordinator.addJob(patchJob1)
        await coordinator.runPatchTask(taskID: patchJob1.id, folderPath: gameRoot.path, cleanTitle: "ShadowArena", settings: settings)

        let storedFirst = try #require(await gameLibrary.all().first)
        #expect(storedFirst.exePath == realExe.path)
        #expect(storedFirst.launchArguments == "-eac-nop-loaded")

        // User customizes launch arguments
        var customized = storedFirst
        customized.launchArguments = "-dx12 -windowed"
        _ = await gameLibrary.update(customized)

        let patchJob2 = Job(kind: .patch, title: "ShadowArena", status: .queued, source: ArtifactRef(kind: .directory, value: gameRoot.path))
        await coordinator.addJob(patchJob2)
        await coordinator.runPatchTask(taskID: patchJob2.id, folderPath: gameRoot.path, cleanTitle: "ShadowArena", settings: settings)

        let storedSecond = try #require(await gameLibrary.all().first)
        #expect(storedSecond.launchArguments == "-dx12 -windowed")
    }

    // MARK: - 3. Nested Archive Secondary Unpack

    @Test
    func testNestedArchivePayloadDetectionAndSecondaryUnpack() async throws {
        let fm = FileManager.default
        let root = try makeTempDir(prefix: "chrysa-nested-unpack")
        defer { try? fm.removeItem(at: root) }

        // A. Detection guardrails on synthetic staging directories
        let dirWithExe = root.appendingPathComponent("StageWithExe", isDirectory: true)
        try fm.createDirectory(at: dirWithExe, withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: dirWithExe.appendingPathComponent("Game.exe"))
        try Data("zip".utf8).write(to: dirWithExe.appendingPathComponent("Bonus.zip"))
        #expect(UnpackService.detectNestedArchivePayload(in: dirWithExe) == nil)

        let dirIncompleteParts = root.appendingPathComponent("StageIncomplete", isDirectory: true)
        try fm.createDirectory(at: dirIncompleteParts, withIntermediateDirectories: true)
        try Data("p1".utf8).write(to: dirIncompleteParts.appendingPathComponent("Bundle.part01.rar"))
        try Data("p3".utf8).write(to: dirIncompleteParts.appendingPathComponent("Bundle.part03.rar"))
        #expect(UnpackService.detectNestedArchivePayload(in: dirIncompleteParts) == nil)

        let dirCompleteParts = root.appendingPathComponent("StageComplete", isDirectory: true)
        try fm.createDirectory(at: dirCompleteParts.appendingPathComponent("Wrapper", isDirectory: true), withIntermediateDirectories: true)
        try Data("p1".utf8).write(to: dirCompleteParts.appendingPathComponent("Wrapper/Bundle.part01.rar"))
        try Data("p2".utf8).write(to: dirCompleteParts.appendingPathComponent("Wrapper/Bundle.part02.rar"))
        try Data("notes".utf8).write(to: dirCompleteParts.appendingPathComponent("Wrapper/readme.txt"))
        let detectedRar = UnpackService.detectNestedArchivePayload(in: dirCompleteParts)
        #expect(detectedRar?.primaryArchiveURL.lastPathComponent == "Bundle.part01.rar")
        #expect(detectedRar?.volumeURLs.count == 2)

        let dirMultipleArchives = root.appendingPathComponent("StageTwoZips", isDirectory: true)
        try fm.createDirectory(at: dirMultipleArchives, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: dirMultipleArchives.appendingPathComponent("Game.zip"))
        try Data("b".utf8).write(to: dirMultipleArchives.appendingPathComponent("Patch.7z"))
        #expect(UnpackService.detectNestedArchivePayload(in: dirMultipleArchives) == nil)

        // B. End-to-end nested archive unpack using 7zz / ditto when available
        guard let sevenZip = ToolchainLocator.locateSevenZip() else {
            return
        }

        // B1: Outer .zip containing Wrapper/InnerGame.zip + Wrapper/readme.txt -> unwraps to InnerPayload/Game.exe
        let payloadSource = root.appendingPathComponent("PayloadSrc", isDirectory: true)
        let gameFolderInZip = payloadSource.appendingPathComponent("NestedGame", isDirectory: true)
        try fm.createDirectory(at: gameFolderInZip, withIntermediateDirectories: true)
        try makeMinimalPE64().write(to: gameFolderInZip.appendingPathComponent("NestedGame.exe"))

        let innerZip = root.appendingPathComponent("InnerBuild.zip")
        try runProcess(executable: sevenZip, arguments: ["a", "-tzip", "-y", innerZip.path, gameFolderInZip.path])

        let outerStaging = root.appendingPathComponent("OuterSrc", isDirectory: true)
        let wrapperDir = outerStaging.appendingPathComponent("Package", isDirectory: true)
        try fm.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
        try fm.copyItem(at: innerZip, to: wrapperDir.appendingPathComponent("InnerBuild.zip"))
        try Data("readme".utf8).write(to: wrapperDir.appendingPathComponent("readme.txt"))

        let unpackWorkDir = root.appendingPathComponent("Work", isDirectory: true)
        try fm.createDirectory(at: unpackWorkDir, withIntermediateDirectories: true)
        let outerArchive = unpackWorkDir.appendingPathComponent("Nested Release.zip")
        try runProcess(executable: sevenZip, arguments: ["a", "-tzip", "-y", outerArchive.path, wrapperDir.path])

        let unpackSvc = UnpackService(postProcessors: [])
        let logs = StringArrayBox()
        let outcome = await unpackSvc.executeUnpack(
            taskID: UUID(),
            archivePath: outerArchive.path,
            candidatePasswords: [""],
            deleteArchiveAfterUnpack: true,
            onProgress: { _, _ in },
            onLog: { msg, _ in logs.append(msg) }
        )

        guard case .completed(let outDir, _, _) = outcome else {
            Issue.record("Expected nested unpack to succeed")
            return
        }
        let unpackedExe = URL(fileURLWithPath: outDir).appendingPathComponent("NestedGame/NestedGame.exe")
        #expect(fm.fileExists(atPath: unpackedExe.path))
        #expect(!fm.fileExists(atPath: URL(fileURLWithPath: outDir).appendingPathComponent("Package/InnerBuild.zip").path))
        #expect(!fm.fileExists(atPath: outerArchive.path))
        #expect(logs.snapshot().contains { $0.contains("二次拆包") })

        // B2: Max depth = 1 limit (3-layer russian doll stops after 1 secondary unpack without infinite recursion)
        let layer3Zip = root.appendingPathComponent("Layer3.zip")
        try runProcess(executable: sevenZip, arguments: ["a", "-tzip", "-y", layer3Zip.path, gameFolderInZip.path])
        let layer2Zip = root.appendingPathComponent("Layer2.zip")
        try runProcess(executable: sevenZip, arguments: ["a", "-tzip", "-y", layer2Zip.path, layer3Zip.path])
        let layer1Dir = root.appendingPathComponent("Layer1Work", isDirectory: true)
        try fm.createDirectory(at: layer1Dir, withIntermediateDirectories: true)
        let layer1Zip = layer1Dir.appendingPathComponent("ThreeLayer.zip")
        try runProcess(executable: sevenZip, arguments: ["a", "-tzip", "-y", layer1Zip.path, layer2Zip.path])

        let maxDepthOutcome = await unpackSvc.executeUnpack(
            taskID: UUID(),
            archivePath: layer1Zip.path,
            candidatePasswords: [""],
            deleteArchiveAfterUnpack: false,
            onProgress: { _, _ in },
            onLog: { _, _ in }
        )
        guard case .completed(let layerOutDir, _, _) = maxDepthOutcome else {
            Issue.record("Expected 3-layer unpack to stop cleanly after 1 secondary unpack")
            return
        }
        #expect(fm.fileExists(atPath: URL(fileURLWithPath: layerOutDir).appendingPathComponent("Layer3.zip").path))
        #expect(!fm.fileExists(atPath: URL(fileURLWithPath: layerOutDir).appendingPathComponent("Layer2.zip").path))
    }

    // MARK: - 4. CrossOver Graphics Backend & RetinaMode Config Read/Write

    @MainActor
    @Test
    func testCrossOverGraphicsBackendAndRetinaModeReadWrite() async throws {
        let fm = FileManager.default
        let root = try makeTempDir(prefix: "chrysa-bottle-options")
        defer { try? fm.removeItem(at: root) }

        // Pure text helpers
        let sampleConf = """
        [Bottle]
        "MenuFolder" = "Sample"

        [EnvironmentVariables]
        "WINEMSYNC" = "1"
        "WINEDLLOVERRIDES" = "winhttp=n,b"
        """
        #expect(CrossOverRegistryHelper.readGraphicsBackend(fromConf: sampleConf) == .automatic)

        let updatedDXMT = CrossOverRegistryHelper.setGraphicsBackend(.dxmt, inConf: sampleConf)
        #expect(CrossOverRegistryHelper.readGraphicsBackend(fromConf: updatedDXMT) == .dxmt)
        #expect(updatedDXMT.contains(#""CX_GRAPHICS_BACKEND" = "dxmt""#))
        #expect(updatedDXMT.contains(#""WINEDLLOVERRIDES" = "winhttp=n,b""#))

        let clearedAuto = CrossOverRegistryHelper.setGraphicsBackend(.automatic, inConf: updatedDXMT)
        #expect(CrossOverRegistryHelper.readGraphicsBackend(fromConf: clearedAuto) == .automatic)
        #expect(!clearedAuto.contains("CX_GRAPHICS_BACKEND"))

        let sampleReg = "WINE REGISTRY Version 2\n"
        #expect(!CrossOverRegistryHelper.readRetinaMode(fromReg: sampleReg))
        let enabledReg = CrossOverRegistryHelper.setRetinaMode(true, inReg: sampleReg)
        #expect(CrossOverRegistryHelper.readRetinaMode(fromReg: enabledReg))
        #expect(enabledReg.contains("[Software\\\\Wine\\\\Mac Driver]"))
        #expect(enabledReg.contains(#""RetinaMode"="y""#))
        let disabledReg = CrossOverRegistryHelper.setRetinaMode(false, inReg: enabledReg)
        #expect(!CrossOverRegistryHelper.readRetinaMode(fromReg: disabledReg))
        #expect(disabledReg.contains(#""RetinaMode"="n""#))

        // Full disk round-trip via DefaultWorkflowServices & PipelineCoordinator
        let bottlesRoot = root.appendingPathComponent("Bottles", isDirectory: true)
        let bottleDir = bottlesRoot.appendingPathComponent("TestBottle", isDirectory: true)
        try fm.createDirectory(at: bottleDir.appendingPathComponent("drive_c", isDirectory: true), withIntermediateDirectories: true)
        try sampleConf.write(to: bottleDir.appendingPathComponent("cxbottle.conf"), atomically: true, encoding: .utf8)
        try sampleReg.write(to: bottleDir.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)

        let coordinator = PipelineCoordinator(
            services: DefaultWorkflowServices(),
            jobStore: JobStore(inMemoryOnly: true),
            gameLibrary: LaunchGameStore(inMemoryOnly: true)
        )

        let gameWithoutBottle = LaunchGame(title: "NoBottleGame", bottleName: "MissingBottle", source: .manualImport)
        #expect(await coordinator.readBottleRuntimeOptions(for: gameWithoutBottle, bottlesDirectory: bottlesRoot.path) == nil)

        let gameWithBottle = LaunchGame(title: "TestBottle", bottleName: "TestBottle", source: .patchPipeline)
        let initial = try #require(await coordinator.readBottleRuntimeOptions(for: gameWithBottle, bottlesDirectory: bottlesRoot.path))
        #expect(initial == CrossOverBottleRuntimeOptions(graphicsBackend: .automatic, retinaMode: false))

        try await coordinator.saveBottleRuntimeOptions(
            CrossOverBottleRuntimeOptions(graphicsBackend: .d3dmetal, retinaMode: true),
            for: gameWithBottle,
            bottlesDirectory: bottlesRoot.path
        )
        let reloaded = try #require(await coordinator.readBottleRuntimeOptions(for: gameWithBottle, bottlesDirectory: bottlesRoot.path))
        #expect(reloaded == CrossOverBottleRuntimeOptions(graphicsBackend: .d3dmetal, retinaMode: true))

        try await coordinator.saveBottleRuntimeOptions(
            CrossOverBottleRuntimeOptions(graphicsBackend: .dxvk, retinaMode: false),
            for: gameWithBottle,
            bottlesDirectory: bottlesRoot.path
        )
        let updatedConf = try String(contentsOf: bottleDir.appendingPathComponent("cxbottle.conf"), encoding: .utf8)
        let updatedReg = try String(contentsOf: bottleDir.appendingPathComponent("user.reg"), encoding: .utf8)
        #expect(updatedConf.contains(#""CX_GRAPHICS_BACKEND" = "dxvk""#))
        #expect(updatedReg.contains(#""RetinaMode"="n""#))

        try await coordinator.saveBottleRuntimeOptions(
            CrossOverBottleRuntimeOptions(graphicsBackend: .automatic, retinaMode: false),
            for: gameWithBottle,
            bottlesDirectory: bottlesRoot.path
        )
        let finalConf = try String(contentsOf: bottleDir.appendingPathComponent("cxbottle.conf"), encoding: .utf8)
        #expect(!finalConf.contains("CX_GRAPHICS_BACKEND"))
    }

    // MARK: - Helpers

    private func makeTempDir(prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeMinimalPE64() -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x200)
        bytes[0] = 0x4D // 'M'
        bytes[1] = 0x5A // 'Z'
        bytes[0x3C] = 0x40
        bytes[0x40] = 0x50 // 'P'
        bytes[0x41] = 0x45 // 'E'
        bytes[0x40 + 20] = 0xF0 // SizeOfOptionalHeader = 240
        bytes[0x40 + 24] = 0x0B // PE32+ Magic 0x020B
        bytes[0x40 + 25] = 0x02
        return Data(bytes)
    }

    private func runProcess(executable: String, arguments: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0)
    }
}

private final class StringArrayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        let copy = values
        lock.unlock()
        return copy
    }
}
