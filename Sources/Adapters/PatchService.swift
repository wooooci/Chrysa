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

        // Inspect PE Import Table on main EXE and UnityPlayer.dll
        var peInfo = PEImportInfo(is64Bit: true, importsSteamAPI: false, importsD3D12: false, importsWinHTTP: false)
        if let exe = mainEXE {
            try await checkCancellation()
            peInfo = PEBinaryInspector.inspect(exePath: exe)
            if peInfo.importsD3D12 { hasD3D12 = true }
            let unityPlayerPath = ((exe as NSString).deletingLastPathComponent as NSString).appendingPathComponent("UnityPlayer.dll")
            if fm.fileExists(atPath: unityPlayerPath) {
                try await checkCancellation()
                let upInfo = PEBinaryInspector.inspect(exePath: unityPlayerPath)
                if upInfo.importsD3D12 { hasD3D12 = true }
            }
        }

        var patchModePill = "Goldberg x64"
        var targetDLLDirs: [String] = []

        if !existingSteamDLLs.isEmpty {
            for (dllPath, is64) in existingSteamDLLs {
                try await checkCancellation()
                let dllSize = (try? fm.attributesOfItem(atPath: dllPath)[.size] as? Int64) ?? 0
                let hasOrigBackup = [".original", ".orig", ".bak"].contains { suffix in
                    let backup = dllPath + suffix
                    return fm.fileExists(atPath: backup) && !fm.contentsEqual(atPath: dllPath, andPath: backup)
                }
                let isAlreadyGoldberg = hasOrigBackup || dllSize > 2_000_000

                if isAlreadyGoldberg {
                    patchModePill = dllSize > 10_000_000 ? "Goldberg Overlay" : (is64 ? "Goldberg x64" : "Goldberg x86")
                    targetDLLDirs.append((dllPath as NSString).deletingLastPathComponent)
                } else {
                    let src = try requiredDLL(is64Bit: is64)
                    try writer.backUpDLL(at: dllPath)
                    try writer.installDLL(from: src, to: dllPath)
                    patchModePill = is64 ? "Goldberg x64" : "Goldberg x86"
                    targetDLLDirs.append((dllPath as NSString).deletingLastPathComponent)
                }
            }
            onLog("gbe_fork ▸ [\(effectiveTitle)] 已就绪 (\(patchModePill), AppID: \(finalAppID))", true)
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

        if let exe = mainEXE {
            let exeDir = (exe as NSString).deletingLastPathComponent
            if !targetDLLDirs.contains(exeDir) {
                targetDLLDirs.append(exeDir)
            }
        }

        let langValue = settings.patch.defaultLanguage.rawValue
        let countryValue = settings.patch.defaultLanguage.ipCountry
        let langShort = settings.patch.defaultLanguage.shortLabel

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

        let isStandalonePatchPack = (mainEXE == nil)
        let configuredBottle = isStandalonePatchPack
            ? "独立补丁包"
            : try await bottleConfigurator.configure(
                taskID: taskID,
                gameTitle: effectiveTitle,
                exePath: mainEXE,
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
        let checklist: [CheckItem] = isStandalonePatchPack
            ? [
                CheckItem(title: "Goldberg 补丁 (\(finalAppID)) · 已切换\(langShort)配置", isChecked: true),
                CheckItem(title: "独立补丁包 (不含主程序 .exe，请覆盖至游戏目录)", isChecked: true)
            ]
            : [
                CheckItem(title: "\(primaryDLLLabel) ➔ Goldberg (\(finalAppID)) · \(langShort)", isChecked: true),
                CheckItem(title: "CrossOver 容器环境 (\(gfxDesc) + MSync\(dllOverrideDesc))", isChecked: bottleReady)
            ]

        onLog("config ▸ [\(effectiveTitle)] 已写入 AppID=\(finalAppID)、\(langShort)配置及 [\(configuredBottle)]", false)

        return PatchResultPayload(
            displayTitle: effectiveTitle,
            pill: patchModePill,
            rightText: isStandalonePatchPack ? "打开目录" : "已入库",
            exePath: mainEXE,
            appID: finalAppID,
            bottleName: isStandalonePatchPack ? nil : configuredBottle,
            checklist: checklist
        )
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
