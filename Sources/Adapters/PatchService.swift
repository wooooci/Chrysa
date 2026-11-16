import ChrysaCore
import ChrysaApplication
import Foundation

package struct PatchResultPayload: Sendable {
    package let displayTitle: String
    package let pill: String
    package let rightText: String
    package let exePath: String?
    package let appID: String
    package let bottleName: String?
    package let checklist: [CheckItem]
    package let defaultLaunchArguments: String?
}

package actor PatchService {
    private let bottleConfigurator: CrossOverBottleConfigurator

    package init(bottleConfigurator: CrossOverBottleConfigurator = CrossOverBottleConfigurator()) {
        self.bottleConfigurator = bottleConfigurator
    }

    package func executePatch(
        taskID: UUID,
        folderPath: String,
        cleanTitle: String,
        settings: AppSettings,
        isCancelled: @escaping @Sendable () async -> Bool = { Task.isCancelled },
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> PatchResultPayload {
        let fm = FileManager.default

        @Sendable func cancellationRequested() async -> Bool {
            if Task.isCancelled { return true }
            return await isCancelled()
        }

        func checkCancellation() async throws {
            if await cancellationRequested() { throw CancellationError() }
        }

        try await checkCancellation()
        let root = URL(fileURLWithPath: folderPath).resolvingSymlinksInPath().standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
        guard rootValues.isDirectory == true, rootValues.isReadable == true else {
            throw CocoaError(.fileReadNoPermission)
        }
        let writer = PatchFileWriter(root: root)

        let inspection = try await GameDirectoryInspector.inspect(
            directory: folderPath,
            fallbackTitle: cleanTitle,
            cancellationRequested: cancellationRequested
        )
        let existingSteamDLLs = inspection.existingSteamDLLs
        let unityDataDirs = inspection.unityDataDirectories
        let unrealSteamworksDirs = inspection.unrealSteamworksDirectories
        var hasD3D12 = inspection.hasD3D12
        let hasWinHTTP = inspection.hasWinHTTP
        let mainEXE = inspection.mainExecutable
        let effectiveTitle = inspection.resolvedTitle

        var resolvedAppID = inspection.existingAppID
        if resolvedAppID == nil {
            let folderName = (folderPath as NSString).lastPathComponent
            if let m = try? NSRegularExpression(pattern: #"^([0-9]{4,8})"#).firstMatch(
                in: folderName, range: NSRange(folderName.startIndex..., in: folderName)
            ), let r = Range(m.range(at: 1), in: folderName) {
                resolvedAppID = String(folderName[r])
            }
        }
        if resolvedAppID == nil {
            try await checkCancellation()
            resolvedAppID = await SteamAppIDLookup.fetch(for: effectiveTitle)
            if resolvedAppID == nil,
               let hint = inspection.executableTitleHint,
               hint.caseInsensitiveCompare(effectiveTitle) != .orderedSame,
               !GameDirectoryInspector.genericExecutableStems.contains(hint.lowercased()) {
                resolvedAppID = await SteamAppIDLookup.fetch(for: hint)
            }
            try await checkCancellation()
        }
        let finalAppID = resolvedAppID ?? "480"

        func requiredDLL(is64Bit: Bool) throws -> String {
            guard let path = ToolchainLocator.locateGbeDLL(is64Bit: is64Bit) else {
                throw PatchError.missingDLL(is64Bit: is64Bit)
            }
            return path
        }

        // Inspect PE Import Table on main EXE, UnityPlayer.dll, and IL2CPP GameAssembly.dll
        var peInfo = PEImportInfo(is64Bit: true, importsSteamAPI: false, importsD3D12: false, importsWinHTTP: false)
        var gameAssemblyImportsSteam = false
        if let exe = mainEXE {
            try await checkCancellation()
            peInfo = PEBinaryInspector.inspect(exePath: exe)
            if peInfo.importsD3D12 { hasD3D12 = true }
            let exeDir = (exe as NSString).deletingLastPathComponent
            let unityPlayerPath = (exeDir as NSString).appendingPathComponent("UnityPlayer.dll")
            if fm.fileExists(atPath: unityPlayerPath) {
                try await checkCancellation()
                let upInfo = PEBinaryInspector.inspect(exePath: unityPlayerPath)
                if upInfo.importsD3D12 { hasD3D12 = true }
            }
            let gameAssemblyPath = (exeDir as NSString).appendingPathComponent("GameAssembly.dll")
            if fm.fileExists(atPath: gameAssemblyPath) {
                try await checkCancellation()
                let gaInfo = PEBinaryInspector.inspect(exePath: gameAssemblyPath)
                if gaInfo.importsSteamAPI { gameAssemblyImportsSteam = true }
            }
        }

        let unityManagedUsesSteam = unityDataDirs.contains { dataDir in
            let managedDir = (dataDir as NSString).appendingPathComponent("Managed")
            guard let files = try? fm.contentsOfDirectory(atPath: managedDir) else { return false }
            return files.contains { $0.lowercased().contains("steam") }
        }
        let requiresSteamWhenDLLMissing = !peInfo.isValidPE
            || peInfo.importsSteamAPI
            || gameAssemblyImportsSteam
            || unityManagedUsesSteam
            || !unrealSteamworksDirs.isEmpty
            || inspection.existingAppID != nil

        enum PatchRoutingMode {
            case goldberg
            case preservedThirdPartyCrack(syncedINI: Bool)
            case drmFreePassthrough
        }

        let langValue = settings.patch.defaultLanguage.rawValue
        let countryValue = settings.patch.defaultLanguage.ipCountry
        let langShort = settings.patch.defaultLanguage.shortLabel

        var routingMode: PatchRoutingMode = .goldberg
        var patchModePill = "Goldberg x64"
        var targetDLLDirs: [String] = []

        if !existingSteamDLLs.isEmpty {
            var classified: [(path: String, is64: Bool, size: Int64, disposition: SteamDLLDisposition)] = []
            for (dllPath, is64) in existingSteamDLLs {
                try await checkCancellation()
                let dllSize = (try? fm.attributesOfItem(atPath: dllPath)[.size] as? Int64) ?? 0
                let hasOrigBackup = [".original", ".orig", ".bak"].contains { suffix in
                    let backup = dllPath + suffix
                    return fm.fileExists(atPath: backup) && !fm.contentsEqual(atPath: dllPath, andPath: backup)
                }
                let disposition = PEBinaryInspector.classifySteamDLL(atPath: dllPath, hasOriginalBackup: hasOrigBackup)
                classified.append((dllPath, is64, dllSize, disposition))
            }

            if classified.contains(where: { $0.disposition == .thirdPartyEmulator }) {
                let primaryIs64 = classified.contains(where: \.is64)
                patchModePill = primaryIs64 ? "原包已修补 x64" : "原包已修补 x86"
                var candidateINIDirs: [String] = classified.map { ($0.path as NSString).deletingLastPathComponent }
                if let exe = mainEXE {
                    candidateINIDirs.append((exe as NSString).deletingLastPathComponent)
                }
                candidateINIDirs.append(root.path)
                let syncedINI = try syncExistingEmulatorINILanguage(
                    inDirectories: candidateINIDirs,
                    language: langValue,
                    writer: writer
                )
                targetDLLDirs.append(contentsOf: candidateINIDirs)
                routingMode = .preservedThirdPartyCrack(syncedINI: syncedINI)
                onLog("passthrough ▸ [\(effectiveTitle)] 检测到非 Valve 官方签名 DLL，已保留原包补丁直通 (\(patchModePill))", true)
            } else {
                for item in classified {
                    try await checkCancellation()
                    if item.disposition == .goldberg {
                        patchModePill = item.size > 10_000_000 ? "Goldberg Overlay" : (item.is64 ? "Goldberg x64" : "Goldberg x86")
                        targetDLLDirs.append((item.path as NSString).deletingLastPathComponent)
                    } else {
                        let src = try requiredDLL(is64Bit: item.is64)
                        try writer.backUpDLL(at: item.path)
                        try writer.installDLL(from: src, to: item.path)
                        patchModePill = item.is64 ? "Goldberg x64" : "Goldberg x86"
                        targetDLLDirs.append((item.path as NSString).deletingLastPathComponent)
                    }
                }
                onLog("gbe_fork ▸ [\(effectiveTitle)] 已就绪 (\(patchModePill), AppID: \(finalAppID))", true)
            }
        } else if mainEXE != nil && !requiresSteamWhenDLLMissing {
            routingMode = .drmFreePassthrough
            patchModePill = peInfo.is64Bit ? "免补丁直装 x64" : "免补丁直装 x86"
            onLog("passthrough ▸ [\(effectiveTitle)] 未检测到 Steam API 依赖，跳过补丁直接配置容器 (\(patchModePill))", true)
        } else if let firstUnityData = unityDataDirs.first {
            try await checkCancellation()
            let is64 = peInfo.is64Bit
            let archFolder = is64 ? "x86_64" : "x86"
            let dllName = is64 ? "steam_api64.dll" : "steam_api.dll"
            let pluginDir = (firstUnityData as NSString).appendingPathComponent("Plugins/\(archFolder)")
            try writer.createDirectory(at: pluginDir)
            let destPluginDLL = (pluginDir as NSString).appendingPathComponent(dllName)
            let src = try requiredDLL(is64Bit: is64)
            try writer.installDLL(from: src, to: destPluginDLL)
            targetDLLDirs.append(pluginDir)
            if let exe = mainEXE {
                let exeDir = (exe as NSString).deletingLastPathComponent
                let exeDLL = (exeDir as NSString).appendingPathComponent(dllName)
                try writer.installDLL(from: src, to: exeDLL)
                targetDLLDirs.append(exeDir)
            }
            patchModePill = is64 ? "Unity 补全 x64" : "Unity 补全 x86"
            onLog("unity-fix ▸ 检测到 Unity 游戏缺失 \(dllName)，已自动注入 Plugins/\(archFolder)！", true)
        } else if let firstUE = unrealSteamworksDirs.first {
            try await checkCancellation()
            let is64 = peInfo.is64Bit
            let dllName = is64 ? "steam_api64.dll" : "steam_api.dll"
            let destDLL = (firstUE as NSString).appendingPathComponent(dllName)
            let src = try requiredDLL(is64Bit: is64)
            try writer.installDLL(from: src, to: destDLL)
            targetDLLDirs.append(firstUE)
            patchModePill = is64 ? "UE 补全 x64" : "UE 补全 x86"
            onLog("ue-fix ▸ 检测到 Unreal 游戏缺失 \(dllName)，已自动注入 Steamworks 目录！", true)
        } else if let exe = mainEXE {
            try await checkCancellation()
            let exeDir = (exe as NSString).deletingLastPathComponent
            let is64 = peInfo.is64Bit
            let dllName = is64 ? "steam_api64.dll" : "steam_api.dll"
            let destDLL = (exeDir as NSString).appendingPathComponent(dllName)
            let src = try requiredDLL(is64Bit: is64)
            try writer.installDLL(from: src, to: destDLL)
            targetDLLDirs.append(exeDir)
            patchModePill = is64 ? "PE 补全 x64" : "PE 补全 x86"
            onLog("pe-scan ▸ 检测到 .exe 导入 \(dllName) 但原包缺失，已自动补全 Goldberg DLL！", true)
        }

        let fetchedDLCs: [SteamDLCItem]
        switch routingMode {
        case .goldberg, .preservedThirdPartyCrack:
            try await checkCancellation()
            fetchedDLCs = (finalAppID != "480") ? await SteamAppIDLookup.fetchDLCs(appID: finalAppID) : []
        case .drmFreePassthrough:
            fetchedDLCs = []
        }

        if case .goldberg = routingMode {
            if let exe = mainEXE {
                let exeDir = (exe as NSString).deletingLastPathComponent
                if !targetDLLDirs.contains(exeDir) {
                    targetDLLDirs.append(exeDir)
                }
            }

            for dir in targetDLLDirs {
                try await checkCancellation()
                let settingsDir = (dir as NSString).appendingPathComponent("steam_settings")
                try writer.createDirectory(at: settingsDir)
                let appIdFile1 = (settingsDir as NSString).appendingPathComponent("steam_appid.txt")
                let appIdFile2 = (dir as NSString).appendingPathComponent("steam_appid.txt")
                let cfgFile = (settingsDir as NSString).appendingPathComponent("configs.user.ini")
                try await checkCancellation()
                try writer.write("\(finalAppID)\n", to: appIdFile1)
                try await checkCancellation()
                try writer.write("\(finalAppID)\n", to: appIdFile2)

                var existingCfg = try writer.readConfiguration(at: cfgFile)
                if !existingCfg.isEmpty {
                    if let langRegex = try? NSRegularExpression(pattern: #"(?m)^language\s*=\s*[^\r\n]+"#) {
                        let range = NSRange(existingCfg.startIndex..., in: existingCfg)
                        if langRegex.firstMatch(in: existingCfg, range: range) != nil {
                            existingCfg = langRegex.stringByReplacingMatches(in: existingCfg, range: range, withTemplate: "language=\(langValue)")
                        } else {
                            existingCfg += "\nlanguage=\(langValue)\n"
                        }
                    }
                    if let countryRegex = try? NSRegularExpression(pattern: #"(?m)^ip_country\s*=\s*[^\r\n]+"#) {
                        let range = NSRange(existingCfg.startIndex..., in: existingCfg)
                        if countryRegex.firstMatch(in: existingCfg, range: range) != nil {
                            existingCfg = countryRegex.stringByReplacingMatches(in: existingCfg, range: range, withTemplate: "ip_country=\(countryValue)")
                        } else {
                            existingCfg += (existingCfg.hasSuffix("\n") ? "" : "\n") + "ip_country=\(countryValue)\n"
                        }
                    }
                    try writer.write(existingCfg, to: cfgFile)
                } else {
                    let iniContent = "[user::general]\nlanguage=\(langValue)\nip_country=\(countryValue)\n"
                    try writer.write(iniContent, to: cfgFile)
                }
            }
            let syncedDLCCount = try writeGoldbergAppDLCs(
                inDirectories: targetDLLDirs,
                dlcs: fetchedDLCs,
                writer: writer,
                requireExistingSettingsDir: false
            )
            if syncedDLCCount > 0 {
                onLog("dlc ▸ 已写入 \(fetchedDLCs.count) 条 Steam DLC 解锁清单至 steam_settings/configs.app.ini", false)
            }
        } else if case .preservedThirdPartyCrack = routingMode, !fetchedDLCs.isEmpty {
            let updatedDLCFiles = try syncExistingEmulatorINIDLCs(
                inDirectories: targetDLLDirs,
                dlcs: fetchedDLCs,
                writer: writer
            )
            if updatedDLCFiles > 0 {
                onLog("dlc ▸ 已向原包 .ini [DLC] 段增量同步 \(fetchedDLCs.count) 条 Steam DLC 信息", false)
            }
        }

        var defaultLaunchArguments: String? = nil
        if inspection.hasEasyAntiCheat {
            defaultLaunchArguments = "-eac-nop-loaded"
            if let exe = mainEXE {
                let exeDir = (exe as NSString).deletingLastPathComponent
                let siblingAppIDFile = (exeDir as NSString).appendingPathComponent("steam_appid.txt")
                let existingText = (try? String(contentsOfFile: siblingAppIDFile, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if existingText == nil || existingText?.isEmpty == true || (existingText == "480" && finalAppID != "480") {
                    try await checkCancellation()
                    try writer.write("\(finalAppID)\n", to: siblingAppIDFile)
                }
            }
            onLog("eac ▸ [\(effectiveTitle)] 检测到 EAC 反作弊壳，已定位真实主程序并附带 -eac-nop-loaded", true)
        }

        let isStandalonePatchPack = (mainEXE == nil)
        let configuredBottle = isStandalonePatchPack
            ? "独立补丁包"
            : try await bottleConfigurator.configure(
                taskID: taskID,
                gameTitle: effectiveTitle,
                exePath: mainEXE,
                gameDirectory: root.path,
                bottlesDirectory: settings.patch.bottlesDirectory,
                hasD3D12: hasD3D12,
                hasWinHTTP: hasWinHTTP,
                isCancelled: isCancelled
            )
        try await checkCancellation()

        let bottlePath = ((settings.patch.bottlesDirectory as NSString).expandingTildeInPath as NSString)
            .appendingPathComponent(configuredBottle)
        let bottleReady = configuredBottle != "Default" && fm.fileExists(atPath: bottlePath)
        let gfxDesc = hasD3D12 ? "D3DMetal" : "DXMT"
        let dllOverrideDesc = hasWinHTTP ? " + winhttp" : ""
        let primaryDLLLabel = patchModePill.hasSuffix("x86") ? "steam_api.dll" : "steam_api64.dll"
        let checklist: [CheckItem]
        switch routingMode {
        case .goldberg:
            checklist = isStandalonePatchPack
                ? [
                    CheckItem(title: "Goldberg 补丁 (\(finalAppID)) · 已切换\(langShort)配置", isChecked: true),
                    CheckItem(title: "独立补丁包 (不含主程序 .exe，请覆盖至游戏目录)", isChecked: true)
                ]
                : [
                    CheckItem(title: "\(primaryDLLLabel) ➔ Goldberg (\(finalAppID)) · \(langShort)", isChecked: true),
                    CheckItem(title: "CrossOver 容器环境 (\(gfxDesc) + MSync\(dllOverrideDesc))", isChecked: bottleReady)
                ]
            onLog("config ▸ [\(effectiveTitle)] 已写入 AppID=\(finalAppID)、\(langShort)配置及 [\(configuredBottle)]", false)
        case .preservedThirdPartyCrack(let syncedINI):
            let langNote = syncedINI ? " · 已同步\(langShort)配置" : " · 免覆盖直通"
            checklist = [
                CheckItem(title: "保留原包补丁 (\(primaryDLLLabel))\(langNote)", isChecked: true),
                CheckItem(title: "CrossOver 容器环境 (\(gfxDesc) + MSync\(dllOverrideDesc))", isChecked: bottleReady)
            ]
            onLog("config ▸ [\(effectiveTitle)] 已保留原包补丁并配置容器 [\(configuredBottle)]", false)
        case .drmFreePassthrough:
            checklist = [
                CheckItem(title: "免加密原版 · 无需替换 Steam DLL", isChecked: true),
                CheckItem(title: "CrossOver 容器环境 (\(gfxDesc) + MSync\(dllOverrideDesc))", isChecked: bottleReady)
            ]
            onLog("config ▸ [\(effectiveTitle)] 已完成免补丁直通容器配置 [\(configuredBottle)]", false)
        }

        return PatchResultPayload(
            displayTitle: effectiveTitle,
            pill: patchModePill,
            rightText: isStandalonePatchPack ? "打开目录" : "已入库",
            exePath: mainEXE,
            appID: finalAppID,
            bottleName: isStandalonePatchPack ? nil : configuredBottle,
            checklist: checklist,
            defaultLaunchArguments: isStandalonePatchPack ? nil : defaultLaunchArguments
        )
    }

    private func forEachEmulatorINI(
        inDirectories directories: [String],
        writer: PatchFileWriter,
        transform: (String, String) -> String?
    ) throws -> Int {
        let fm = FileManager.default
        var seenDirs = Set<String>()
        var updatedCount = 0

        for dir in directories where seenDirs.insert(dir).inserted {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.lowercased().hasSuffix(".ini") {
                let fullPath = (dir as NSString).appendingPathComponent(entry)
                let rawURL = URL(fileURLWithPath: fullPath)
                let values = try? rawURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                if values?.isSymbolicLink == true {
                    _ = try writer.destination(fullPath)
                    continue
                }
                guard values?.isRegularFile == true,
                      let fileSize = values?.fileSize,
                      fileSize > 0,
                      fileSize <= 262_144 else {
                    continue
                }
                let safeURL = try writer.destination(fullPath)
                let usedLatin1: Bool
                let original: String
                if let utf8 = try? String(contentsOf: safeURL, encoding: .utf8) {
                    original = utf8
                    usedLatin1 = false
                } else if let latin1 = try? String(contentsOf: safeURL, encoding: .isoLatin1) {
                    original = latin1
                    usedLatin1 = true
                } else {
                    continue
                }

                guard let rewritten = transform(entry, original),
                      rewritten != original else {
                    continue
                }
                let encoding: String.Encoding = usedLatin1 ? .isoLatin1 : .utf8
                try rewritten.write(to: safeURL, atomically: true, encoding: encoding)
                updatedCount += 1
            }
        }
        return updatedCount
    }

    /// Gently updates `Language=` / `language = "..."` in any existing shallow `.ini` file alongside a third-party
    /// Steam emulator DLL without maintaining crack-group filename lists or creating new config files.
    private func syncExistingEmulatorINILanguage(
        inDirectories directories: [String],
        language: String,
        writer: PatchFileWriter
    ) throws -> Bool {
        try forEachEmulatorINI(inDirectories: directories, writer: writer) { _, original in
            Self.rewriteINILanguageValue(in: original, to: language)
        } > 0
    }

    private func syncExistingEmulatorINIDLCs(
        inDirectories directories: [String],
        dlcs: [SteamDLCItem],
        writer: PatchFileWriter
    ) throws -> Int {
        guard !dlcs.isEmpty else { return 0 }
        let knownINIs = GameDirectoryInspector.emulatorINIFileNameSet.union([
            "rune.ini", "smartsteame.ini", "sse.ini", "lumaemu.ini", "hoodlum.ini", "empress.ini"
        ])
        return try forEachEmulatorINI(inDirectories: directories, writer: writer) { fileName, original in
            let isKnown = knownINIs.contains(fileName.lowercased())
            let looksLikeSteamINI = isKnown
                || original.range(of: #"(?im)^\s*(AppId|UserName|AccountId|Language)\s*="#, options: .regularExpression) != nil
            guard looksLikeSteamINI else { return nil }
            return Self.appendMissingDLCsToEmulatorINI(text: original, dlcs: dlcs)
        }
    }

    private func writeGoldbergAppDLCs(
        inDirectories directories: [String],
        dlcs: [SteamDLCItem],
        writer: PatchFileWriter,
        requireExistingSettingsDir: Bool
    ) throws -> Int {
        let fm = FileManager.default
        var updatedCount = 0
        for dir in directories {
            let settingsDir = (dir as NSString).appendingPathComponent("steam_settings")
            if requireExistingSettingsDir && !fm.fileExists(atPath: settingsDir) {
                continue
            }
            let appCfgFile = (settingsDir as NSString).appendingPathComponent("configs.app.ini")
            let existingAppCfg = try writer.readConfiguration(at: appCfgFile)
            let mergedAppCfg = Self.mergeGoldbergAppDLCs(existing: existingAppCfg, dlcs: dlcs)
            if mergedAppCfg != existingAppCfg {
                try writer.write(mergedAppCfg, to: appCfgFile)
                updatedCount += 1
            }
        }
        return updatedCount
    }

    /// Re-queries Steam DLCs and updates `configs.app.ini` / third-party `[DLC]` INI sections inside an already-patched game directory.
    package func refreshDLCConfiguration(
        directory: String,
        explicitAppID: String? = nil,
        onLog: @escaping @Sendable (String, Bool) async -> Void
    ) async {
        guard let rootURL = try? PathSafety.existingCanonicalDirectory(directory),
              let inspection = GameDirectoryInspector.inspect(directory: rootURL.path) else {
            return
        }
        let writer = PatchFileWriter(root: rootURL)
        let resolvedAppID = [explicitAppID, inspection.existingAppID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != "480" && Int($0) != nil }
        guard let appID = resolvedAppID else { return }

        let dlcs = await SteamAppIDLookup.fetchDLCs(appID: appID)
        guard !dlcs.isEmpty else { return }

        var candidateDirs = inspection.existingSteamDLLs.map { ($0.path as NSString).deletingLastPathComponent }
        if let exe = inspection.mainExecutable {
            candidateDirs.append((exe as NSString).deletingLastPathComponent)
        }
        candidateDirs.append(contentsOf: inspection.unityDataDirectories.flatMap { dataDir in
            ["x86_64", "x86"].map { ((dataDir as NSString).appendingPathComponent("Plugins") as NSString).appendingPathComponent($0) }
        })
        candidateDirs.append(contentsOf: inspection.unrealSteamworksDirectories)
        candidateDirs.append(rootURL.path)

        var seen = Set<String>()
        let uniqueDirs = candidateDirs.filter { seen.insert($0).inserted }

        let goldbergUpdated = (try? writeGoldbergAppDLCs(
            inDirectories: uniqueDirs,
            dlcs: dlcs,
            writer: writer,
            requireExistingSettingsDir: true
        )) ?? 0
        let iniUpdated = (try? syncExistingEmulatorINIDLCs(inDirectories: uniqueDirs, dlcs: dlcs, writer: writer)) ?? 0
        if goldbergUpdated > 0 || iniUpdated > 0 {
            await onLog("dlc ▸ 已同步 \(dlcs.count) 条 Steam DLC 配置 (AppID \(appID))", false)
        }
    }

    package static func mergeGoldbergAppDLCs(existing: String, dlcs: [SteamDLCItem]) -> String {
        let usesCRLF = existing.contains("\r\n")
        let lineBreak = usesCRLF ? "\r\n" : "\n"
        let normalized = usesCRLF ? existing.replacingOccurrences(of: "\r\n", with: "\n") : existing

        let cleanedDLCs: [(id: String, name: String)] = dlcs.compactMap { item in
            let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Int(id) != nil else { return nil }
            let cleanName = item.name
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (id, cleanName.isEmpty ? "DLC \(id)" : cleanName)
        }

        if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var lines = ["[app::dlcs]", "unlock_all=1"]
            for dlc in cleanedDLCs {
                lines.append("\(dlc.id)=\(dlc.name)")
            }
            return lines.joined(separator: lineBreak) + lineBreak
        }

        var lines = normalized.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }

        if let range = PathSafety.findSectionRange(in: lines, header: "[app::dlcs]") {
            let bodyStart = range.start + 1
            var existingMap: [String: String] = [:]
            var orderedExistingIDs: [String] = []
            var otherLines: [String] = []

            for i in bodyStart..<range.end {
                let rawLine = lines[i]
                let stripped = rawLine.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespaces)
                if stripped.isEmpty { continue }
                if stripped.hasPrefix(";") || stripped.hasPrefix("#") || stripped.hasPrefix("//") {
                    otherLines.append(rawLine)
                    continue
                }
                if let eqIdx = rawLine.firstIndex(of: "=") {
                    let key = rawLine[..<eqIdx].replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespaces)
                    let val = rawLine[rawLine.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
                    if key.lowercased() == "unlock_all" {
                        continue
                    }
                    if Int(key) != nil {
                        if existingMap[key] == nil {
                            orderedExistingIDs.append(key)
                        }
                        existingMap[key] = val
                        continue
                    }
                }
                otherLines.append(rawLine)
            }

            for dlc in cleanedDLCs {
                if existingMap[dlc.id] == nil {
                    orderedExistingIDs.append(dlc.id)
                }
                existingMap[dlc.id] = dlc.name
            }

            var rebuiltSection = ["unlock_all=1"]
            rebuiltSection.append(contentsOf: otherLines)
            for id in orderedExistingIDs {
                if let name = existingMap[id] {
                    rebuiltSection.append("\(id)=\(name)")
                }
            }
            lines.replaceSubrange(bodyStart..<range.end, with: rebuiltSection)
        } else {
            if !lines.isEmpty, !lines.last!.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("")
            }
            lines.append("[app::dlcs]")
            lines.append("unlock_all=1")
            for dlc in cleanedDLCs {
                lines.append("\(dlc.id)=\(dlc.name)")
            }
        }

        return lines.joined(separator: lineBreak) + lineBreak
    }

    package static func appendMissingDLCsToEmulatorINI(text: String, dlcs: [SteamDLCItem]) -> String? {
        guard !dlcs.isEmpty else { return nil }
        let usesCRLF = text.contains("\r\n")
        let lineBreak = usesCRLF ? "\r\n" : "\n"
        let normalized = usesCRLF ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
        let hadTrailingNewline = normalized.hasSuffix("\n")
        var lines = normalized.components(separatedBy: "\n")
        if hadTrailingNewline, lines.last == "" {
            lines.removeLast()
        }

        guard let range = PathSafety.findSectionRange(in: lines, header: "[dlc]") else {
            return nil
        }
        let bodyStart = range.start + 1

        var existingDLCIDs = Set<String>()
        var numberedPrefix: String?
        var numberedWidth = 5
        var maxNumberedIndex = 0
        var separator = " = "
        var fallbackSeparator: String?
        var detectedDLCSeparator = false
        var keyQuoted = false
        var valueQuoted = false

        for i in bodyStart..<range.end {
            let line = lines[i]
            let trimmed = line.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(";") || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
                continue
            }
            guard let eqIdx = line.firstIndex(of: "=") else { continue }
            let rawKeySide = String(line[..<eqIdx])
            let rawValSide = String(line[line.index(after: eqIdx)...])
            let cleanKey = rawKeySide.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespaces)
            let cleanVal = rawValSide.trimmingCharacters(in: .whitespaces)

            let beforeEqHasSpace = rawKeySide.last == " " || rawKeySide.last == "\t"
            let afterEqHasSpace = rawValSide.first == " " || rawValSide.first == "\t"
            let lineSeparator = (beforeEqHasSpace || afterEqHasSpace) ? " = " : "="
            if fallbackSeparator == nil {
                fallbackSeparator = lineSeparator
            }

            let unquotedKey = unquoteINIAtom(cleanKey)
            let unquotedVal = unquoteINIAtom(cleanVal)

            if Int(unquotedKey) != nil {
                existingDLCIDs.insert(unquotedKey)
                keyQuoted = cleanKey.hasPrefix("\"") && cleanKey.hasSuffix("\"")
                valueQuoted = cleanVal.hasPrefix("\"") && cleanVal.hasSuffix("\"")
                if !detectedDLCSeparator {
                    separator = lineSeparator
                    detectedDLCSeparator = true
                }
            } else if let match = parseNumberedDLCKey(unquotedKey), Int(unquotedVal) != nil {
                existingDLCIDs.insert(unquotedVal)
                numberedPrefix = numberedPrefix ?? match.prefix
                numberedWidth = max(numberedWidth, match.width)
                maxNumberedIndex = max(maxNumberedIndex, match.index)
                valueQuoted = cleanVal.hasPrefix("\"") && cleanVal.hasSuffix("\"")
                if !detectedDLCSeparator {
                    separator = lineSeparator
                    detectedDLCSeparator = true
                }
            }
        }

        if !detectedDLCSeparator {
            if let fallbackSeparator {
                separator = fallbackSeparator
            } else {
                for line in lines {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || t.hasPrefix(";") || t.hasPrefix("#") || t.hasPrefix("[") { continue }
                    if let eq = line.firstIndex(of: "=") {
                        let before = line[..<eq].last
                        let after = line[line.index(after: eq)...].first
                        separator = (before == " " || before == "\t" || after == " " || after == "\t") ? " = " : "="
                        break
                    }
                }
            }
        }

        let missingDLCs = dlcs.filter { item in
            let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(id) != nil && !existingDLCIDs.contains(id)
        }
        guard !missingDLCs.isEmpty else { return nil }

        var newLines: [String] = []
        if let prefix = numberedPrefix {
            var nextIdx = maxNumberedIndex + 1
            for dlc in missingDLCs {
                let padded = String(format: "%0\(numberedWidth)d", nextIdx)
                nextIdx += 1
                let formattedID = valueQuoted ? "\"\(dlc.id)\"" : dlc.id
                newLines.append("\(prefix)\(padded)\(separator)\(formattedID)")
            }
        } else {
            for dlc in missingDLCs {
                let cleanName = dlc.name
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let finalName = cleanName.isEmpty ? "DLC \(dlc.id)" : cleanName
                let formattedKey = keyQuoted ? "\"\(dlc.id)\"" : dlc.id
                let formattedVal = valueQuoted ? "\"\(finalName)\"" : finalName
                newLines.append("\(formattedKey)\(separator)\(formattedVal)")
            }
        }

        var insertAt = bodyStart
        for idx in (bodyStart..<range.end).reversed() {
            if !lines[idx].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt = idx + 1
                break
            }
        }
        lines.insert(contentsOf: newLines, at: insertAt)
        return lines.joined(separator: lineBreak) + (hadTrailingNewline ? lineBreak : "")
    }

    private static func unquoteINIAtom(_ atom: String) -> String {
        if atom.count >= 2 && atom.hasPrefix("\"") && atom.hasSuffix("\"") {
            return String(atom.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return atom
    }

    private static func parseNumberedDLCKey(_ key: String) -> (prefix: String, index: Int, width: Int)? {
        let lower = key.lowercased()
        for prefix in ["dlc", "app"] where lower.hasPrefix(prefix) {
            let suffix = String(key.dropFirst(prefix.count))
            guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let num = Int(suffix) else { continue }
            return (String(key.prefix(prefix.count)), num, suffix.count)
        }
        return nil
    }

    private static func rewriteINILanguageValue(in text: String, to newLanguage: String) -> String? {
        let usesCRLF = text.contains("\r\n")
        let lineBreak = usesCRLF ? "\r\n" : "\n"
        let normalized = usesCRLF ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
        var lines = normalized.components(separatedBy: "\n")
        var changed = false

        for idx in lines.indices {
            let line = lines[idx]
            let trimmed = line.replacingOccurrences(of: "\u{FEFF}", with: "")
                .trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(";") || trimmed.hasPrefix("#") || trimmed.hasPrefix("[") || trimmed.hasPrefix("//") {
                continue
            }
            guard let eqIdx = line.firstIndex(of: "=") else { continue }
            let rawKey = line[..<eqIdx]
                .replacingOccurrences(of: "\u{FEFF}", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard rawKey.lowercased() == "language" else { continue }

            let prefix = String(line[...eqIdx])
            let rhs = String(line[line.index(after: eqIdx)...])

            // Split value portion from any trailing inline `;` or `#` comment outside quotes
            var inQuotes = false
            var commentStart: String.Index? = nil
            for cIdx in rhs.indices {
                let ch = rhs[cIdx]
                if ch == "\"" {
                    inQuotes.toggle()
                } else if !inQuotes && (ch == ";" || ch == "#") {
                    commentStart = cIdx
                    break
                }
            }

            let valueSegment = commentStart.map { String(rhs[..<$0]) } ?? rhs
            let commentSegment = commentStart.map { String(rhs[$0...]) } ?? ""

            let leadingWSCount = valueSegment.prefix(while: { $0 == " " || $0 == "\t" }).count
            let trailingWSCount = valueSegment.reversed().prefix(while: { $0 == " " || $0 == "\t" }).count
            let leadingWS = String(valueSegment.prefix(leadingWSCount))
            let trailingWS = trailingWSCount > 0 && trailingWSCount < valueSegment.count
                ? String(valueSegment.suffix(trailingWSCount))
                : ""
            let coreValue = valueSegment.trimmingCharacters(in: .whitespaces)
            let isQuoted = coreValue.count >= 2 && coreValue.hasPrefix("\"") && coreValue.hasSuffix("\"")
            let replacementCore = isQuoted ? "\"\(newLanguage)\"" : newLanguage
            let rebuilt = prefix + leadingWS + replacementCore + trailingWS + commentSegment
            if rebuilt != line {
                lines[idx] = rebuilt
                changed = true
            }
        }

        return changed ? lines.joined(separator: lineBreak) : nil
    }
}

package enum PatchError: LocalizedError {
    case missingDLL(is64Bit: Bool)
    case outsideGameDirectory(String)
    case bottleCommandFailed(String, Int32, String = "")

    package var errorDescription: String? {
        switch self {
        case .missingDLL(let is64Bit):
            return "缺少 Goldberg \(is64Bit ? "x64" : "x86") DLL"
        case .outsideGameDirectory(let path):
            return "补丁目标超出所选游戏目录 \(path)"
        case .bottleCommandFailed(let command, let exitCode, _):
            return "CrossOver \(command) 执行失败，退出码 \(exitCode)"
        }
    }

    package var rawDiagnostic: String? {
        switch self {
        case .bottleCommandFailed(_, _, let raw):
            return LogEntry.sanitizeRawOutput(raw)
        case .missingDLL, .outsideGameDirectory:
            return nil
        }
    }
}

/// Publishes each replacement atomically and confines all patch writes to the selected directory.
private struct PatchFileWriter {
    package let root: URL

    package func destination(_ path: String) throws -> URL {
        guard let url = PathSafety.containedURL(URL(fileURLWithPath: path), in: root) else {
            throw PatchError.outsideGameDirectory(path)
        }
        return url
    }

    package func createDirectory(at path: String) throws {
        try FileManager.default.createDirectory(at: destination(path), withIntermediateDirectories: true)
    }

    package func backUpDLL(at path: String) throws {
        let backup = try destination(path + ".bak")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try FileManager.default.copyItem(at: destination(path), to: backup)
    }

    package func installDLL(from source: String, to path: String) throws {
        let target = try destination(path)
        let data = try Data(contentsOf: URL(fileURLWithPath: source))
        try data.write(to: target, options: .atomic)
    }

    package func readConfiguration(at path: String) throws -> String {
        let target = try destination(path)
        guard FileManager.default.fileExists(atPath: target.path) else { return "" }
        return try String(contentsOf: target, encoding: .utf8)
    }

    package func write(_ text: String, to path: String) throws {
        try text.write(to: destination(path), atomically: true, encoding: .utf8)
    }
}
