import ChrysaAdapters
import ChrysaApplication
import ChrysaCore
import CryptoKit
import Foundation
import Testing

struct LifecycleAndPatchTests {
    @Test
    func testSameNameStagingReplacementPreservesSavesAndMergesLaunchGame() async throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }

        let targetName = "Chrysa Test RPG"
        #expect(UnpackService.resolvedTargetDirectoryName(for: targetName) == targetName)

        // Existing sibling v1 directory + Launch Library matched previous directory with portable saves
        let oldSibling = root.appendingPathComponent(targetName, isDirectory: true)
        try fm.createDirectory(at: oldSibling.appendingPathComponent("Saves", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: oldSibling.appendingPathComponent("steam_settings/settings", isDirectory: true), withIntermediateDirectories: true)
        try Data("old-exe".utf8).write(to: oldSibling.appendingPathComponent("Game.exe"))
        try Data("v1-only-asset".utf8).write(to: oldSibling.appendingPathComponent("legacy_v1.pak"))
        try Data("slot1-progress".utf8).write(to: oldSibling.appendingPathComponent("Saves/slot01.sav"))
        try Data("readme-v1".utf8).write(to: oldSibling.appendingPathComponent("Saves/readme.txt"))
        try Data("PlayerOne".utf8).write(to: oldSibling.appendingPathComponent("steam_settings/settings/account_name.txt"))

        let oldMatchedDir = root.appendingPathComponent("Chrysa Test RPG Build 100", isDirectory: true)
        try fm.createDirectory(at: oldMatchedDir.appendingPathComponent("userdata", isDirectory: true), withIntermediateDirectories: true)
        try Data("user-profile".utf8).write(to: oldMatchedDir.appendingPathComponent("userdata/profile.json"))

        // Staging directory for incoming v2 release (with steam_appid.txt for non-480 AppID matching)
        let staging = root.appendingPathComponent(".chrysa-unpack-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging.appendingPathComponent("Saves", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("steam_settings", isDirectory: true), withIntermediateDirectories: true)
        try Data("new-exe-v2".utf8).write(to: staging.appendingPathComponent("Game_v2.exe"))
        try Data("123456\n".utf8).write(to: staging.appendingPathComponent("steam_appid.txt"))
        try Data("readme-v2-do-not-overwrite".utf8).write(to: staging.appendingPathComponent("Saves/readme.txt"))

        let existingGameID = UUID()
        let lastPlayed = Date(timeIntervalSince1970: 1_700_000_000)
        let knownGame = LaunchGame(
            id: existingGameID,
            title: "Chrysa Test RPG v1",
            exePath: oldMatchedDir.appendingPathComponent("Game.exe").path,
            gameDirectory: oldMatchedDir.path,
            bottleName: "Chrysa Test RPG",
            appID: "123456",
            source: .patchPipeline,
            customIconPath: "/custom/icon.png",
            iconPreference: .custom,
            launchArguments: "-dx11",
            addedAt: Date(timeIntervalSince1970: 1_690_000_000),
            lastPlayedAt: lastPlayed
        )

        var logs: [String] = []
        let logBox = LogBox()
        let finalized = try await UnpackService.finalizeStagedDirectory(
            stagingURL: staging,
            parentURL: root,
            targetName: targetName,
            knownGames: [knownGame]
        ) { msg, _ in
            await logBox.append(msg)
        }
        logs = await logBox.snapshot()

        #expect(finalized.replacedOld == true)
        #expect(finalized.finalName == targetName)
        #expect(finalized.finalURL.lastPathComponent == targetName)
        #expect(!finalized.finalURL.lastPathComponent.contains(UUID().uuidString))
        #expect(fm.fileExists(atPath: finalized.finalURL.appendingPathComponent("Game_v2.exe").path))
        #expect(!fm.fileExists(atPath: finalized.finalURL.appendingPathComponent("legacy_v1.pak").path))
        #expect(!fm.fileExists(atPath: staging.path))
        #expect(!fm.fileExists(atPath: oldMatchedDir.path))

        // Portable saves are migrated additively without overwriting new package files
        let migratedSave = try String(contentsOf: finalized.finalURL.appendingPathComponent("Saves/slot01.sav"), encoding: .utf8)
        let readmeText = try String(contentsOf: finalized.finalURL.appendingPathComponent("Saves/readme.txt"), encoding: .utf8)
        let migratedSettings = try String(contentsOf: finalized.finalURL.appendingPathComponent("steam_settings/settings/account_name.txt"), encoding: .utf8)
        let migratedUserdata = try String(contentsOf: finalized.finalURL.appendingPathComponent("userdata/profile.json"), encoding: .utf8)
        #expect(migratedSave == "slot1-progress")
        #expect(readmeText == "readme-v2-do-not-overwrite")
        #expect(migratedSettings == "PlayerOne")
        #expect(migratedUserdata == "user-profile")
        #expect(logs.contains { $0.contains("save ▸") })

        // In-place LaunchGame merge preserves identity, lastPlayedAt, custom icon & launchArguments
        let incoming = LaunchGame(
            title: targetName,
            exePath: finalized.finalURL.appendingPathComponent("Game_v2.exe").path,
            gameDirectory: finalized.finalURL.path,
            bottleName: targetName,
            appID: "123456",
            source: .patchPipeline
        )
        let merged = knownGame.merged(with: incoming, preferIncomingMetadata: true)
        #expect(merged.id == existingGameID)
        #expect(merged.lastPlayedAt == lastPlayed)
        #expect(merged.customIconPath == "/custom/icon.png")
        #expect(merged.iconPreference == .custom)
        #expect(merged.launchArguments == "-dx11")
        #expect(merged.exePath == finalized.finalURL.appendingPathComponent("Game_v2.exe").path)
        #expect(merged.gameDirectory == finalized.finalURL.path)
    }

    @Test
    func testFailedUnpackKeepsExistingDirectoryAndCleansStaging() async throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }

        let existingDir = root.appendingPathComponent("Broken Archive Game", isDirectory: true)
        try fm.createDirectory(at: existingDir.appendingPathComponent("Saves", isDirectory: true), withIntermediateDirectories: true)
        try Data("intact-exe".utf8).write(to: existingDir.appendingPathComponent("Game.exe"))
        try Data("intact-save".utf8).write(to: existingDir.appendingPathComponent("Saves/slot1.dat"))

        let corruptArchive = root.appendingPathComponent("Broken Archive Game.zip")
        try Data("not-a-valid-zip-payload".utf8).write(to: corruptArchive)

        let outcome = await UnpackService().executeUnpack(
            taskID: UUID(),
            archivePath: corruptArchive.path,
            candidatePasswords: [],
            deleteArchiveAfterUnpack: false,
            knownGames: [],
            onProgress: { _, _ in },
            onLog: { _, _ in }
        )

        if case .failed = outcome {
            // Expected failure
        } else {
            Issue.record("Expected failed unpack outcome for corrupt archive")
        }

        // Old directory must remain intact and all staging folders cleaned up
        #expect(try String(contentsOf: existingDir.appendingPathComponent("Game.exe"), encoding: .utf8) == "intact-exe")
        #expect(try String(contentsOf: existingDir.appendingPathComponent("Saves/slot1.dat"), encoding: .utf8) == "intact-save")
        let leftovers = (try fm.contentsOfDirectory(atPath: root.path)).filter { $0.hasPrefix(".chrysa-unpack-") }
        #expect(leftovers.isEmpty)
    }

    @Test
    func testSteamDLCParsingGoldbergAndThirdPartyINIMerge() {
        let appDetailsJSON = """
        {
          "1091500": {
            "success": true,
            "data": {
              "dlc": [2138330, "2138331", 2138330]
            }
          }
        }
        """.data(using: .utf8)!
        #expect(SteamAppIDLookup.parseAppDetailsDLCIDs(from: appDetailsJSON, appID: "1091500") == [2138330, 2138331])

        let failedDetailsJSON = #"{"1091500":{"success":false}}"#.data(using: .utf8)!
        #expect(SteamAppIDLookup.parseAppDetailsDLCIDs(from: failedDetailsJSON, appID: "1091500") == nil)

        let storeBrowseJSON = """
        {
          "response": {
            "store_items": [
              { "appid": 2138330, "name": "Phantom Liberty" },
              { "id": 2138331, "name": "Bonus Soundtrack" }
            ]
          }
        }
        """.data(using: .utf8)!
        let names = SteamAppIDLookup.parseStoreBrowseItemNames(from: storeBrowseJSON)
        #expect(names == [2138330: "Phantom Liberty", 2138331: "Bonus Soundtrack"])

        let dlcs = [
            SteamDLCItem(id: "2138330", name: "Phantom Liberty"),
            SteamDLCItem(id: "2138331", name: "Bonus Soundtrack")
        ]

        // Goldberg configs.app.ini [app::dlcs] section
        let existingConfigsAppINI = """
        [app::dlcs]
        unlock_all=0
        999999=Old Entry

        [app::paths]
        999=./dlc
        """
        let mergedGoldberg = PatchService.mergeGoldbergAppDLCs(existing: existingConfigsAppINI, dlcs: dlcs)
        #expect(mergedGoldberg.contains("[app::dlcs]"))
        #expect(mergedGoldberg.contains("unlock_all=1"))
        #expect(mergedGoldberg.contains("2138330=Phantom Liberty"))
        #expect(mergedGoldberg.contains("2138331=Bonus Soundtrack"))
        #expect(!mergedGoldberg.contains("unlock_all=0"))
        #expect(mergedGoldberg.contains("[app::paths]\n999=./dlc"))

        // Third-party INI (steam_emu.ini unquoted vs tenoke.ini quoted)
        let steamEmuINI = """
        [Settings]
        AppId=1091500

        [DLC]
        UnlockAll=0
        2138330 = Phantom Liberty
        """
        let mergedSteamEmu = PatchService.appendMissingDLCsToEmulatorINI(text: steamEmuINI, dlcs: dlcs)
        #expect(mergedSteamEmu != nil)
        #expect(mergedSteamEmu!.contains("2138331 = Bonus Soundtrack"))
        // Existing entry should not be duplicated
        #expect(mergedSteamEmu!.components(separatedBy: "2138330").count == 2)

        let tenokeINI = """
        [DLC]
        "2138330" = "Phantom Liberty"
        """
        let mergedTenoke = PatchService.appendMissingDLCsToEmulatorINI(text: tenokeINI, dlcs: dlcs)
        #expect(mergedTenoke?.contains(#""2138331" = "Bonus Soundtrack""#) == true)

        // INI without [DLC] section stays untouched
        #expect(PatchService.appendMissingDLCsToEmulatorINI(text: "[Settings]\nLanguage=english\n", dlcs: dlcs) == nil)
    }

    @Test
    func testWrapperUnwrapUEBarePakModsAndCaseInsensitiveDotfiles() async throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }

        // Case A: Unreal Engine bare .pak / .utoc / .ucas auto-routed to <Project>/Content/Paks/~mods/
        let ueGameRoot = root.appendingPathComponent("UEGame", isDirectory: true)
        let paksDir = ueGameRoot.appendingPathComponent("Stellar/Content/Paks", isDirectory: true)
        try fm.createDirectory(at: paksDir, withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: ueGameRoot.appendingPathComponent("Stellar.exe"))
        try Data("base".utf8).write(to: paksDir.appendingPathComponent("Stellar-Windows.pak"))

        let bareModDrop = root.appendingPathComponent("BareModDrop", isDirectory: true)
        let innerWrapper = bareModDrop.appendingPathComponent("ChineseMod_v1", isDirectory: true)
        try fm.createDirectory(at: innerWrapper, withIntermediateDirectories: true)
        try Data("pak".utf8).write(to: innerWrapper.appendingPathComponent("CHS_Patch_P.pak"))
        try Data("utoc".utf8).write(to: innerWrapper.appendingPathComponent("CHS_Patch_P.utoc"))
        try Data("ucas".utf8).write(to: innerWrapper.appendingPathComponent("CHS_Patch_P.ucas"))

        let unwrappedMod = GamePatchApplier.unwrapRedundantSingleWrapperDirectory(from: bareModDrop, gameRoot: ueGameRoot)
        #expect(unwrappedMod.lastPathComponent == "ChineseMod_v1")

        let ueGame = LaunchGame(title: "Stellar", exePath: ueGameRoot.appendingPathComponent("Stellar.exe").path, gameDirectory: ueGameRoot.path)
        let applier = GamePatchApplier()
        let ueReport = try await applier.mergePreparedPayload(payloadRoot: unwrappedMod, intoGameRoot: ueGameRoot, game: ueGame)
        #expect(ueReport.routedUEPaksModsRelative == "Stellar/Content/Paks/~mods")
        #expect(ueReport.requiresFileOpenLogFlag == true)
        #expect(ueReport.mergedFileCount == 3)
        #expect(fm.fileExists(atPath: paksDir.appendingPathComponent("~mods/CHS_Patch_P.pak").path))
        #expect(fm.fileExists(atPath: paksDir.appendingPathComponent("~mods/CHS_Patch_P.utoc").path))
        #expect(fm.fileExists(atPath: paksDir.appendingPathComponent("~mods/CHS_Patch_P.ucas").path))

        var argGame = ueGame
        argGame.launchArguments = argGame.appendingLaunchArgument("-fileopenlog")
        argGame.launchArguments = argGame.appendingLaunchArgument("-fileopenlog")
        #expect(LaunchGame.parseLaunchArguments(argGame.launchArguments) == ["-fileopenlog"])

        // Case B: Incremental case-insensitive merge preserving dotfiles (.doorstop_version) & existing mods,
        // and NOT stripping structural folders such as BepInEx
        let bepGameRoot = root.appendingPathComponent("UnityGame", isDirectory: true)
        try fm.createDirectory(at: bepGameRoot.appendingPathComponent("BepInEx/plugins", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: bepGameRoot.appendingPathComponent("Data", isDirectory: true), withIntermediateDirectories: true)
        try Data("unity".utf8).write(to: bepGameRoot.appendingPathComponent("UnityGame.exe"))
        try Data("keep-existing-mod".utf8).write(to: bepGameRoot.appendingPathComponent("BepInEx/plugins/existing.dll"))
        try Data("old-cfg".utf8).write(to: bepGameRoot.appendingPathComponent("Data/Config.txt"))

        let doorstopPatch = root.appendingPathComponent("DoorstopPatch", isDirectory: true)
        let modWrapper = doorstopPatch.appendingPathComponent("CHS_Translation_Pack", isDirectory: true)
        try fm.createDirectory(at: modWrapper.appendingPathComponent("bepinex/plugins", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: modWrapper.appendingPathComponent("data", isDirectory: true), withIntermediateDirectories: true)
        try Data("4.0".utf8).write(to: modWrapper.appendingPathComponent(".doorstop_version"))
        try Data("new-chs".utf8).write(to: modWrapper.appendingPathComponent("bepinex/plugins/chs.dll"))
        try Data("new-cfg".utf8).write(to: modWrapper.appendingPathComponent("data/CONFIG.txt"))

        let unwrappedDoorstop = GamePatchApplier.unwrapRedundantSingleWrapperDirectory(from: doorstopPatch, gameRoot: bepGameRoot)
        #expect(unwrappedDoorstop.lastPathComponent == "CHS_Translation_Pack")
        // Passing modWrapper (whose single child would be skipped if BepInEx wasn't structural) must NOT strip BepInEx
        let bepOnlyDrop = root.appendingPathComponent("BepOnlyDrop", isDirectory: true)
        try fm.createDirectory(at: bepOnlyDrop.appendingPathComponent("BepInEx/plugins", isDirectory: true), withIntermediateDirectories: true)
        #expect(GamePatchApplier.unwrapRedundantSingleWrapperDirectory(from: bepOnlyDrop, gameRoot: bepGameRoot) == bepOnlyDrop)

        let unityGame = LaunchGame(title: "UnityGame", exePath: bepGameRoot.appendingPathComponent("UnityGame.exe").path, gameDirectory: bepGameRoot.path)
        let mergeReport = try await applier.mergePreparedPayload(payloadRoot: unwrappedDoorstop, intoGameRoot: bepGameRoot, game: unityGame)
        #expect(mergeReport.routedUEPaksModsRelative == nil)
        #expect(mergeReport.mergedFileCount == 3)
        #expect(try String(contentsOf: bepGameRoot.appendingPathComponent(".doorstop_version"), encoding: .utf8) == "4.0")
        #expect(try String(contentsOf: bepGameRoot.appendingPathComponent("BepInEx/plugins/existing.dll"), encoding: .utf8) == "keep-existing-mod")
        #expect(try String(contentsOf: bepGameRoot.appendingPathComponent("BepInEx/plugins/chs.dll"), encoding: .utf8) == "new-chs")
        #expect(try String(contentsOf: bepGameRoot.appendingPathComponent("Data/Config.txt"), encoding: .utf8) == "new-cfg")
    }

    @Test
    func testProxyHookDLLDetectionRegistryFontsAndWindowsLaunch() throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }

        let gameDir = root.appendingPathComponent("HookedGame", isDirectory: true)
        let binDir = gameDir.appendingPathComponent("Bin", isDirectory: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let exeURL = binDir.appendingPathComponent("Game.exe")
        try makeSyntheticPE32Plus(signedByMicrosoft: false).write(to: exeURL)

        // Unsigned whitelist hooks -> detected
        try makeSyntheticPE32Plus(signedByMicrosoft: false).write(to: binDir.appendingPathComponent("winhttp.dll"))
        try makeSyntheticPE32Plus(signedByMicrosoft: false).write(to: gameDir.appendingPathComponent("dinput8.dll"))
        // Intact Microsoft-signed whitelist DLL -> ignored
        try makeSyntheticPE32Plus(signedByMicrosoft: true).write(to: binDir.appendingPathComponent("version.dll"))
        // Unsigned non-whitelist DirectX DLLs -> never auto-overridden
        try makeSyntheticPE32Plus(signedByMicrosoft: false).write(to: binDir.appendingPathComponent("dxgi.dll"))
        try makeSyntheticPE32Plus(signedByMicrosoft: false).write(to: binDir.appendingPathComponent("d3d12.dll"))
        // Garbage non-PE DLL -> ignored
        try Data(repeating: 0xAA, count: 64).write(to: binDir.appendingPathComponent("dsound.dll"))

        let detected = PEBinaryInspector.detectProxyHookDLLs(nearExecutable: exeURL.path, gameDirectory: gameDir.path)
        #expect(detected == ["dinput8", "winhttp"])

        // Pre-launch bottle sync: symlink, cxbottle.conf WINEDLLOVERRIDES, user.reg DllOverrides + FontSubstitutes
        let bottlesRoot = root.appendingPathComponent("Bottles", isDirectory: true)
        let bottleName = "HookedGame"
        let bottleDir = bottlesRoot.appendingPathComponent(bottleName, isDirectory: true)
        try fm.createDirectory(at: bottleDir.appendingPathComponent("drive_c/windows/Fonts", isDirectory: true), withIntermediateDirectories: true)
        try """
        [Bottle]
        "MenuCreated" = "1"

        [EnvironmentVariables]
        "WINEDLLOVERRIDES" = "custom=n,b"
        """.write(to: bottleDir.appendingPathComponent("cxbottle.conf"), atomically: true, encoding: .utf8)
        try "WINE REGISTRY Version 2\n".write(to: bottleDir.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)

        let syncResult = CrossOverBottleConfigurator.syncPreLaunchEnvironment(
            gameTitle: "HookedGame",
            bottleName: bottleName,
            executablePath: exeURL.path,
            gameDirectory: gameDir.path,
            bottlesDirectory: bottlesRoot.path
        )
        #expect(syncResult?.bottleName == bottleName)
        #expect(syncResult?.detectedProxyStems == ["dinput8", "winhttp"])

        let driveCSymlink = bottleDir.appendingPathComponent("drive_c/\(bottleName)")
        #expect(driveCSymlink.resolvingSymlinksInPath().path == gameDir.resolvingSymlinksInPath().path)

        let confText = try String(contentsOf: bottleDir.appendingPathComponent("cxbottle.conf"), encoding: .utf8)
        #expect(confText.contains("custom=n,b"))
        #expect(confText.contains("dinput8=n,b"))
        #expect(confText.contains("winhttp=n,b"))
        #expect(!confText.contains("dxgi=n,b"))

        let userReg = try String(contentsOf: bottleDir.appendingPathComponent("user.reg"), encoding: .utf8)
        #expect(userReg.contains("[Software\\\\Wine\\\\DllOverrides]"))
        #expect(userReg.contains(#""dinput8"="native,builtin""#))
        #expect(userReg.contains(#""winhttp"="native,builtin""#))
        #expect(userReg.contains("[Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\FontSubstitutes]"))
        #expect(userReg.contains(#""Microsoft YaHei"="#))
        #expect(userReg.contains(#""SimSun"="#))
        #expect(userReg.contains(#""SimHei"="#))

        try CrossOverRegistryHelper.ensureSteamAppInstallLocation(inBottlePath: bottleDir.path, appID: "123456", bottleName: bottleName)
        let systemReg = try String(contentsOf: bottleDir.appendingPathComponent("system.reg"), encoding: .utf8)
        #expect(systemReg.contains("Steam App 123456"))
        #expect(systemReg.contains(#""InstallLocation"="C:\\HookedGame""#))

        let windowsTarget = CrossOverRegistryHelper.windowsLaunchTarget(
            exePath: exeURL.path,
            gameDirectory: gameDir.path,
            bottlePath: bottleDir.path,
            bottleName: bottleName
        )
        #expect(windowsTarget == #"C:\HookedGame\Bin\Game.exe"#)

        let launchArgs = GameLauncher.buildWineLaunchArguments(
            bottleName: bottleName,
            gameEXE: exeURL.path,
            windowsTarget: windowsTarget,
            launchArguments: "-fileopenlog -dx12"
        )
        #expect(launchArgs == [
            "--bottle", "HookedGame",
            "--check",
            "--wait-children",
            "--workdir",
            #"C:\HookedGame\Bin"#,
            #"C:\HookedGame\Bin\Game.exe"#,
            "-fileopenlog", "-dx12"
        ])

        let rootLaunchArgs = GameLauncher.buildWineLaunchArguments(
            bottleName: bottleName,
            gameEXE: gameDir.appendingPathComponent("Game.exe").path,
            windowsTarget: #"C:\HookedGame\Game.exe"#,
            launchArguments: nil
        )
        #expect(rootLaunchArgs == [
            "--bottle", "HookedGame",
            "--check",
            "--wait-children",
            "--workdir",
            #"C:\HookedGame"#,
            #"C:\HookedGame\Game.exe"#
        ])
        #expect(CrossOverRegistryHelper.isBottleWineserverResident(bottlePath: bottleDir.path) == false)
    }

    @Test
    func testAPFSSnapshotAndIncrementalFallbackRestore() async throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }

        let bottlesRoot = root.appendingPathComponent("Bottles", isDirectory: true)
        let bottleName = "SnapshotGame"
        let bottleDir = bottlesRoot.appendingPathComponent(bottleName, isDirectory: true)
        try fm.createDirectory(at: bottleDir.appendingPathComponent("drive_c/windows/Fonts", isDirectory: true), withIntermediateDirectories: true)
        try "[EnvironmentVariables]\n".write(to: bottleDir.appendingPathComponent("cxbottle.conf"), atomically: true, encoding: .utf8)
        try "WINE REGISTRY Version 2\n".write(to: bottleDir.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)

        let gameDir = root.appendingPathComponent("SnapshotGame", isDirectory: true)
        let dataDir = gameDir.appendingPathComponent("Data", isDirectory: true)
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let exeURL = gameDir.appendingPathComponent("Game.exe")
        try Data("orig-exe".utf8).write(to: exeURL)
        try Data("orig-core".utf8).write(to: dataDir.appendingPathComponent("core.pak"))

        let game = LaunchGame(
            title: "SnapshotGame",
            exePath: exeURL.path,
            gameDirectory: gameDir.path,
            bottleName: bottleName,
            appID: nil,
            launchArguments: "-windowed"
        )
        let settings = AppSettings(patch: PatchSettings(bottlesDirectory: bottlesRoot.path, defaultLanguage: .schinese))

        // 1. APFS CoW clonefile snapshot + full GamePatchApplier flow + atomic restore
        let apfsStorage = root.appendingPathComponent("SnapshotsAPFS", isDirectory: true)
        let apfsManager = GameSnapshotManager(storageRoot: apfsStorage, forceIncrementalFallback: false)
        let applier = GamePatchApplier(snapshotManager: apfsManager)

        let modFolder = root.appendingPathComponent("IncomingPatch", isDirectory: true)
        try fm.createDirectory(at: modFolder.appendingPathComponent("Data", isDirectory: true), withIntermediateDirectories: true)
        try Data("v2-core".utf8).write(to: modFolder.appendingPathComponent("Data/core.pak"))
        try Data("doorstop".utf8).write(to: modFolder.appendingPathComponent(".doorstop_version"))
        try makeSyntheticPE32Plus(signedByMicrosoft: false).write(to: modFolder.appendingPathComponent("winhttp.dll"))

        let applyOutcome = await applier.apply(game: game, sourceURL: modFolder, settings: settings) { _ in }
        guard case .applied = applyOutcome else {
            Issue.record("Expected GamePatchApplier.apply to succeed")
            return
        }

        #expect(apfsManager.hasSnapshot(for: game) == true)
        #expect(try String(contentsOf: dataDir.appendingPathComponent("core.pak"), encoding: .utf8) == "v2-core")
        #expect(fm.fileExists(atPath: gameDir.appendingPathComponent(".doorstop_version").path))
        #expect(fm.fileExists(atPath: gameDir.appendingPathComponent("winhttp.dll").path))
        #expect(CrossOverRegistryHelper.activeWhitelistOverrides(inBottlePath: bottleDir.path).contains("winhttp"))

        let mutatedExeGame = LaunchGame(
            id: game.id,
            title: game.title,
            exePath: gameDir.appendingPathComponent("ModLauncher.exe").path,
            gameDirectory: game.gameDirectory,
            bottleName: game.bottleName,
            launchArguments: "-windowed -mod"
        )
        let restored = try await apfsManager.restoreBaseline(for: mutatedExeGame, bottlesDirectory: bottlesRoot.path) { _, _ in }
        #expect(restored.restoredExePath == exeURL.path)
        #expect(restored.restoredLaunchArguments == "-windowed")
        #expect(try String(contentsOf: dataDir.appendingPathComponent("core.pak"), encoding: .utf8) == "orig-core")
        #expect(try String(contentsOf: exeURL, encoding: .utf8) == "orig-exe")
        #expect(!fm.fileExists(atPath: gameDir.appendingPathComponent(".doorstop_version").path))
        #expect(!fm.fileExists(atPath: gameDir.appendingPathComponent("winhttp.dll").path))
        #expect(!CrossOverRegistryHelper.activeWhitelistOverrides(inBottlePath: bottleDir.path).contains("winhttp"))
        #expect(apfsManager.hasSnapshot(for: game) == false)

        // 2. Non-clonefile fallback (ExFAT / cross-volume simulation) + opaque process mutation diffing
        let secondaryFile = gameDir.appendingPathComponent("config.cfg")
        try Data("orig-cfg".utf8).write(to: secondaryFile)

        let fallbackStorage = root.appendingPathComponent("SnapshotsFallback", isDirectory: true)
        let fallbackManager = GameSnapshotManager(storageRoot: fallbackStorage, preferAPFSClone: false)
        let manifest = try await fallbackManager.ensureBaselineSnapshot(for: game, bottlePath: bottleDir.path) { _, _ in }
        #expect(manifest.mode == .incrementalDiff)
        #expect(manifest.baselineExePath == exeURL.path)

        try await fallbackManager.recordIncomingChange(relativePath: "Data/core.pak", gameID: game.id, gameDirectory: gameDir.path)
        try Data("mutated-core".utf8).write(to: dataDir.appendingPathComponent("core.pak"))
        try await fallbackManager.recordIncomingChange(relativePath: "newmod.txt", gameID: game.id, gameDirectory: gameDir.path)
        try Data("extra".utf8).write(to: gameDir.appendingPathComponent("newmod.txt"))

        // Also test opaque external process mutation tracking (modify existing file, add file, delete file)
        let opaqueToken = await fallbackManager.prepareForOpaqueProcessMutation(for: game)
        #expect(opaqueToken != nil)
        try Data("patcheddll".utf8).write(to: gameDir.appendingPathComponent("opaque_added.dll"))
        try Data("orig-exe-modified-len".utf8).write(to: exeURL)
        try? fm.removeItem(at: secondaryFile)
        await fallbackManager.finalizeOpaqueProcessMutation(opaqueToken)

        let fallbackRestored = try await fallbackManager.restoreBaseline(for: game, bottlesDirectory: bottlesRoot.path) { _, _ in }
        #expect(fallbackRestored.restoredExePath == exeURL.path)
        #expect(try String(contentsOf: dataDir.appendingPathComponent("core.pak"), encoding: .utf8) == "orig-core")
        #expect(try String(contentsOf: exeURL, encoding: .utf8) == "orig-exe")
        #expect(try String(contentsOf: secondaryFile, encoding: .utf8) == "orig-cfg")
        #expect(!fm.fileExists(atPath: gameDir.appendingPathComponent("opaque_added.dll").path))
        #expect(!fm.fileExists(atPath: gameDir.appendingPathComponent("newmod.txt").path))
        #expect(fallbackManager.hasSnapshot(for: game) == false)
    }

    @Test
    func testStandalonePatchPackAndCrossDirProtectionInFinalize() async throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }

        let parentDir = root.appendingPathComponent("Games", isDirectory: true)
        let otherDir = root.appendingPathComponent("OtherDrive", isDirectory: true)
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: otherDir, withIntermediateDirectories: true)

        // Existing runnable game in parentDir
        let existingGameDir = parentDir.appendingPathComponent("ExistingRPG", isDirectory: true)
        try fm.createDirectory(at: existingGameDir, withIntermediateDirectories: true)
        try makeSyntheticPE32Plus(signedByMicrosoft: false).write(to: existingGameDir.appendingPathComponent("ExistingRPG.exe"))
        try Data("base-asset".utf8).write(to: existingGameDir.appendingPathComponent("assets.pak"))

        // Same-title game on a different parent directory (must never be trashed!)
        let externalGameDir = otherDir.appendingPathComponent("ExistingRPG_External", isDirectory: true)
        try fm.createDirectory(at: externalGameDir, withIntermediateDirectories: true)
        try makeSyntheticPE32Plus(signedByMicrosoft: false).write(to: externalGameDir.appendingPathComponent("ExistingRPG.exe"))

        // Case 1: Standalone crack/patch staging (no .exe) must NOT trash or overwrite existingGameDir
        let crackStaging = parentDir.appendingPathComponent(".staging_crack_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: crackStaging, withIntermediateDirectories: true)
        try Data("crack-dll".utf8).write(to: crackStaging.appendingPathComponent("steam_api64.dll"))

        let finalizedCrack = try await UnpackService.finalizeStagedDirectory(
            stagingURL: crackStaging,
            parentURL: parentDir,
            targetName: "ExistingRPG",
            knownGames: []
        ) { _, _ in }

        #expect(finalizedCrack.replacedOld == false)
        #expect(finalizedCrack.finalURL.path != existingGameDir.path)
        #expect(fm.fileExists(atPath: existingGameDir.appendingPathComponent("ExistingRPG.exe").path))
        #expect(fm.fileExists(atPath: existingGameDir.appendingPathComponent("assets.pak").path))

        // Case 2: Full game staging in parentDir with a matching LaunchGame in otherDir must NOT touch otherDir
        let fullStaging = parentDir.appendingPathComponent(".staging_full_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: fullStaging, withIntermediateDirectories: true)
        try makeSyntheticPE32Plus(signedByMicrosoft: false).write(to: fullStaging.appendingPathComponent("NewGame.exe"))

        let externalKnown = LaunchGame(
            title: "NewGame",
            exePath: externalGameDir.appendingPathComponent("ExistingRPG.exe").path,
            gameDirectory: externalGameDir.path
        )
        let finalizedCross = try await UnpackService.finalizeStagedDirectory(
            stagingURL: fullStaging,
            parentURL: parentDir,
            targetName: "NewGame",
            knownGames: [externalKnown]
        ) { _, _ in }

        #expect(finalizedCross.replacedOld == false)
        #expect(fm.fileExists(atPath: externalGameDir.appendingPathComponent("ExistingRPG.exe").path))
    }

    @Test
    func testSingleBarePakAutoCompanionCollectionAndSelfDropGuard() async throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }

        let gameDir = root.appendingPathComponent("UE5Game", isDirectory: true)
        let paksDir = gameDir.appendingPathComponent("MyTitle/Content/Paks", isDirectory: true)
        try fm.createDirectory(at: paksDir, withIntermediateDirectories: true)
        try makeSyntheticPE32Plus(signedByMicrosoft: false).write(to: gameDir.appendingPathComponent("MyTitle.exe"))

        let snapStorage = root.appendingPathComponent("Snapshots", isDirectory: true)
        let snapManager = GameSnapshotManager(storageRoot: snapStorage)
        let applier = GamePatchApplier(snapshotManager: snapManager)

        let game = LaunchGame(
            title: "UE5Game",
            exePath: gameDir.appendingPathComponent("MyTitle.exe").path,
            gameDirectory: gameDir.path
        )
        let settings = AppSettings()

        // Self-drop (gameDir itself and child file inside gameDir) must fail BEFORE creating snapshot
        let selfDirOutcome = await applier.apply(game: game, sourceURL: gameDir, settings: settings) { _ in }
        guard case .failed = selfDirOutcome else {
            Issue.record("Expected self-drop of gameDir to fail")
            return
        }
        #expect(snapManager.hasSnapshot(for: game) == false)

        let selfChildOutcome = await applier.apply(
            game: game,
            sourceURL: gameDir.appendingPathComponent("MyTitle.exe"),
            settings: settings
        ) { _ in }
        guard case .failed = selfChildOutcome else {
            Issue.record("Expected self-drop of inner file to fail")
            return
        }
        #expect(snapManager.hasSnapshot(for: game) == false)

        // Single bare .pak drop with sibling .utoc and .ucas (mixed case stem) auto-collects companions
        let modsSourceDir = root.appendingPathComponent("Downloads", isDirectory: true)
        try fm.createDirectory(at: modsSourceDir, withIntermediateDirectories: true)
        let pakURL = modsSourceDir.appendingPathComponent("CHS_Patch_P.pak")
        let utocURL = modsSourceDir.appendingPathComponent("chs_patch_p.utoc")
        let ucasURL = modsSourceDir.appendingPathComponent("CHS_Patch_P.UCAS")
        try Data("pak-bytes".utf8).write(to: pakURL)
        try Data("utoc-bytes".utf8).write(to: utocURL)
        try Data("ucas-bytes".utf8).write(to: ucasURL)

        let pakOutcome = await applier.apply(game: game, sourceURL: pakURL, settings: settings) { _ in }
        guard case .applied(let updatedGame, _) = pakOutcome else {
            Issue.record("Expected single bare .pak with companions to apply cleanly")
            return
        }

        let modsDest = paksDir.appendingPathComponent("~mods", isDirectory: true)
        #expect(fm.fileExists(atPath: modsDest.appendingPathComponent("CHS_Patch_P.pak").path))
        #expect(fm.fileExists(atPath: modsDest.appendingPathComponent("chs_patch_p.utoc").path))
        #expect(fm.fileExists(atPath: modsDest.appendingPathComponent("CHS_Patch_P.UCAS").path))
        #expect(LaunchGame.parseLaunchArguments(updatedGame.launchArguments).contains("-fileopenlog"))
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-lifecycle-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSyntheticPE32Plus(signedByMicrosoft: Bool) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x200)
        // DOS signature "MZ" and PE header offset 0x40
        bytes[0] = 0x4D
        bytes[1] = 0x5A
        writeUInt32(&bytes, 0x40, at: 0x3C)

        let peOff = 0x40
        bytes[peOff + 0] = 0x50 // 'P'
        bytes[peOff + 1] = 0x45 // 'E'
        writeUInt16(&bytes, 0xF0, at: peOff + 20) // SizeOfOptionalHeader = 240

        let optOff = peOff + 24 // 0x58
        writeUInt16(&bytes, 0x20B, at: optOff) // PE32+ Magic
        let checksumOff = optOff + 64 // 0x98
        writeUInt32(&bytes, 16, at: optOff + 108) // NumberOfRvaAndSizes
        let certDirOff = optOff + 112 + 32 // 0xE8

        guard signedByMicrosoft else {
            return Data(bytes)
        }

        let publisherBytes = Array("Microsoft Corporation DigiCert".utf8)
        let certOff = bytes.count
        let certSize = 8 + publisherBytes.count + 32
        writeUInt32(&bytes, UInt32(certOff), at: certDirOff)
        writeUInt32(&bytes, UInt32(certSize), at: certDirOff + 4)

        var sha256 = SHA256()
        sha256.update(data: bytes[0 ..< checksumOff])
        sha256.update(data: bytes[(checksumOff + 4) ..< certDirOff])
        sha256.update(data: bytes[(certDirOff + 8) ..< certOff])
        let digest = Array(sha256.finalize())

        var cert = [UInt8](repeating: 0, count: certSize)
        writeUInt32(&cert, UInt32(certSize), at: 0)
        writeUInt16(&cert, 0x0200, at: 4) // WIN_CERT_REVISION_2_0
        writeUInt16(&cert, 0x0002, at: 6) // WIN_CERT_TYPE_PKCS_SIGNED_DATA
        cert.replaceSubrange(8 ..< (8 + publisherBytes.count), with: publisherBytes)
        cert.replaceSubrange((8 + publisherBytes.count) ..< certSize, with: digest)

        bytes.append(contentsOf: cert)
        return Data(bytes)
    }

    @Test
    func testToolchainLocatorPrefersBundledExecutableOverSystemFallback() throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }

        let fakeBundle = root.appendingPathComponent("Portable.app", isDirectory: true)
        let fakeBundleMacOS = fakeBundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let fakeInstalled = root.appendingPathComponent("Installed.app", isDirectory: true)
        let fakeInstalledMacOS = fakeInstalled.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let fakeSystemDir = root.appendingPathComponent("homebrew/bin", isDirectory: true)

        try fm.createDirectory(at: fakeBundleMacOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: fakeInstalledMacOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: fakeSystemDir, withIntermediateDirectories: true)

        let systemBin = fakeSystemDir.appendingPathComponent("7zz")
        try Data("#!/bin/sh\n".utf8).write(to: systemBin)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: systemBin.path)

        // 1. Falls back to system path when neither bundle contains the binary
        let fallbackHit = ToolchainLocator.locateBundledOrSystemBinary(
            bundledName: "7zz",
            bundlePath: fakeBundle.path,
            installedAppPath: fakeInstalled.path,
            systemCandidates: [systemBin.path]
        )
        #expect(fallbackHit == systemBin.path)

        // 2. Ignores non-executable placeholders inside the app bundle
        let bundleBin = fakeBundleMacOS.appendingPathComponent("7zz")
        try Data("not-executable".utf8).write(to: bundleBin)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bundleBin.path)
        let nonExecFallback = ToolchainLocator.locateBundledOrSystemBinary(
            bundledName: "7zz",
            bundlePath: fakeBundle.path,
            installedAppPath: fakeInstalled.path,
            systemCandidates: [systemBin.path]
        )
        #expect(nonExecFallback == systemBin.path)

        // 3. Prefers executable inside Bundle.main over installed app and system fallback
        let installedBin = fakeInstalledMacOS.appendingPathComponent("7zz")
        try Data("#!/bin/sh\n".utf8).write(to: installedBin)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedBin.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundleBin.path)

        let bundledHit = ToolchainLocator.locateBundledOrSystemBinary(
            bundledName: "7zz",
            bundlePath: fakeBundle.path,
            installedAppPath: fakeInstalled.path,
            systemCandidates: [systemBin.path]
        )
        #expect(bundledHit == bundleBin.path)

        // 4. Falls back to installed app bundle when current Bundle.main lacks the helper
        try fm.removeItem(at: bundleBin)
        let installedHit = ToolchainLocator.locateBundledOrSystemBinary(
            bundledName: "7zz",
            bundlePath: fakeBundle.path,
            installedAppPath: fakeInstalled.path,
            systemCandidates: [systemBin.path]
        )
        #expect(installedHit == installedBin.path)
    }

    private func writeUInt16(_ buffer: inout [UInt8], _ value: UInt16, at offset: Int) {
        let le = value.littleEndian
        buffer[offset] = UInt8(truncatingIfNeeded: le)
        buffer[offset + 1] = UInt8(truncatingIfNeeded: le >> 8)
    }

    private func writeUInt32(_ buffer: inout [UInt8], _ value: UInt32, at offset: Int) {
        let le = value.littleEndian
        buffer[offset] = UInt8(truncatingIfNeeded: le)
        buffer[offset + 1] = UInt8(truncatingIfNeeded: le >> 8)
        buffer[offset + 2] = UInt8(truncatingIfNeeded: le >> 16)
        buffer[offset + 3] = UInt8(truncatingIfNeeded: le >> 24)
    }
}

private actor LogBox {
    private var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
    func snapshot() -> [String] { entries }
}
