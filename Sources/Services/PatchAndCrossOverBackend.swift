import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
extension StudioViewModel {
    // MARK: - 3. PATCH BACKEND (Three-Way Steam DLL + CSF steamapps/common + Unity/Unreal + PE Import Scanner + Auto AppID + schinese + CrossOver Bottle)
    func startPatch(folderPath: String) {
        let gameTitle = Self.cleanGameTitle(from: (folderPath as NSString).lastPathComponent)
        let taskID = UUID()
        let newTask = StudioTask(
            id: taskID,
            title: gameTitle,
            status: .running(0.35),
            pill: "扫描中",
            rightText: "处理中",
            localPath: folderPath,
            expanded: true
        )
        patchTasks.insert(newTask, at: 0)
        appendLog("pe-scan ▸ 开始扫描目录与 PE 导入表: \(gameTitle)", highlight: false)

        Task.detached { [weak self] in
            await self?.runGoldbergPatch(taskID: taskID, folderPath: folderPath, cleanTitle: gameTitle)
        }
    }

    nonisolated static func cleanGameTitle(from raw: String) -> String {
        var s = raw
        if let r = try? NSRegularExpression(pattern: #"^[0-9]{4,8}_[0-9]+$"#),
           r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
            return s
        }
        if s.lowercased().hasPrefix("setup_") {
            s = String(s.dropFirst("setup_".count))
        }
        s = s.replacingOccurrences(of: "_", with: " ")
        // Strip bracketed/parenthesized scene tags like [Goldberg], [CSF], [FitGirl], (Steam), (90164), etc.
        if let bracketRegex = try? NSRegularExpression(pattern: #"\s*(\[[^\]]+\]|\([^\)]+\))"#) {
            s = bracketRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        if let regex = try? NSRegularExpression(pattern: #"\s*(v?[0-9]+\.[0-9]+.*|Build\s*[0-9]+.*|b[0-9]{6,}.*)$"#, options: .caseInsensitive) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated func runGoldbergPatch(taskID: UUID, folderPath: String, cleanTitle: String) async {
        let fm = FileManager.default
        var existingSteamDLLs: [(String, Bool)] = []
        var candidateEXEs: [String] = []
        var unityDataDirs: [String] = []
        var unrealSteamworksDirs: [String] = []
        var existingAppID: String? = nil
        var discoveredGameTitle: String? = nil
        var hasD3D12 = false
        var hasWinHTTP = false

        // 1. Check for CSF standard layout: steamapps/common/<GameName>
        let commonDir = (folderPath as NSString).appendingPathComponent("steamapps/common")
        if let items = try? fm.contentsOfDirectory(atPath: commonDir) {
            for item in items where !item.hasPrefix(".") {
                var isDir: ObjCBool = false
                let fullSub = (commonDir as NSString).appendingPathComponent(item)
                if fm.fileExists(atPath: fullSub, isDirectory: &isDir), isDir.boolValue {
                    discoveredGameTitle = item
                    break
                }
            }
        }

        // 2. If not CSF, check if folderPath contains a single top-level game subfolder
        if discoveredGameTitle == nil,
           let topItems = try? fm.contentsOfDirectory(atPath: folderPath).filter({ !$0.hasPrefix(".") }),
           topItems.count == 1 {
            let singleSub = (folderPath as NSString).appendingPathComponent(topItems[0])
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: singleSub, isDirectory: &isDir), isDir.boolValue,
               topItems[0].lowercased() != "steamapps" && !topItems[0].lowercased().hasSuffix("_data") {
                discoveredGameTitle = Self.cleanGameTitle(from: topItems[0])
            }
        }

        if let enumerator = fm.enumerator(atPath: folderPath) {
            while let rel = enumerator.nextObject() as? String {
                let relLower = rel.lowercased()
                let lastComp = (rel as NSString).lastPathComponent
                let lower = lastComp.lowercased()
                let full = (folderPath as NSString).appendingPathComponent(rel)

                if lower == "steam_api64.dll" {
                    existingSteamDLLs.append((full, true))
                } else if lower == "steam_api.dll" {
                    existingSteamDLLs.append((full, false))
                } else if lower == "winhttp.dll" {
                    hasWinHTTP = true
                } else if lower.hasSuffix("_data") {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                        unityDataDirs.append(full)
                    }
                } else if relLower.contains("engine/binaries/thirdparty/steamworks") {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                        unrealSteamworksDirs.append(full)
                    }
                } else if lower == "steam_appid.txt" {
                    if let content = try? String(contentsOfFile: full, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !content.isEmpty {
                        existingAppID = content
                    }
                } else if lower.hasPrefix("appmanifest_") && lower.hasSuffix(".acf") {
                    if let m = try? NSRegularExpression(pattern: #"appmanifest_([0-9]+)\.acf"#).firstMatch(
                        in: lower, range: NSRange(lower.startIndex..., in: lower)
                    ), let r = Range(m.range(at: 1), in: lower) {
                        existingAppID = String(lower[r])
                    }
                    if let acfText = try? String(contentsOfFile: full, encoding: .utf8),
                       let nmMatch = try? NSRegularExpression(pattern: #""name"\s+"([^"]+)""#).firstMatch(
                        in: acfText, range: NSRange(acfText.startIndex..., in: acfText)
                       ), let nr = Range(nmMatch.range(at: 1), in: acfText) {
                        discoveredGameTitle = String(acfText[nr])
                    }
                } else if lower == "d3d12" || lower == "d3d12core.dll" {
                    hasD3D12 = true
                } else if lower.hasSuffix(".exe")
                            && !relLower.contains("__redist")
                            && !relLower.contains("/redist/")
                            && !lower.contains("scriptinterpreter")
                            && !lower.contains("unitycrashhandler")
                            && !lower.contains("unins")
                            && !lower.contains("vc_redist")
                            && !lower.contains("dxsetup")
                            && !lower.contains("crashreport")
                            && !lower.contains("crs-handler")
                            && !lower.contains("goggalaxy")
                            && !lower.contains("dosbox")
                            && !lower.hasPrefix("setup_") {
                    candidateEXEs.append(full)
                }
            }
        }

        // Priority 1: Exact Unity <Name>_Data -> <Name>.exe match (prevents picking helper EXEs over thin Unity 600KB bootstrapper)
        var matchedUnityEXE: String? = nil
        for dataDir in unityDataDirs {
            let dirName = (dataDir as NSString).lastPathComponent
            if dirName.lowercased().hasSuffix("_data") {
                let prefix = String(dirName.dropLast("_data".count))
                let parent = (dataDir as NSString).deletingLastPathComponent
                let expectedEXE = (parent as NSString).appendingPathComponent("\(prefix).exe")
                if fm.fileExists(atPath: expectedEXE) {
                    matchedUnityEXE = expectedEXE
                    break
                }
                if let ciMatch = candidateEXEs.first(where: {
                    (($0 as NSString).lastPathComponent as NSString).deletingPathExtension.caseInsensitiveCompare(prefix) == .orderedSame
                }) {
                    matchedUnityEXE = ciMatch
                    break
                }
            }
        }

        // Priority 2: Shallowest directory depth first, then largest file size
        let mainEXE = matchedUnityEXE ?? candidateEXEs.max { a, b in
            let depthA = a.components(separatedBy: "/").count
            let depthB = b.components(separatedBy: "/").count
            if depthA != depthB {
                return depthA > depthB
            }
            let sa = (try? fm.attributesOfItem(atPath: a)[.size] as? Int64) ?? 0
            let sb = (try? fm.attributesOfItem(atPath: b)[.size] as? Int64) ?? 0
            return sa < sb
        }

        let effectiveTitle = discoveredGameTitle ?? cleanTitle

        var resolvedAppID = existingAppID
        if resolvedAppID == nil {
            let folderName = (folderPath as NSString).lastPathComponent
            if let m = try? NSRegularExpression(pattern: #"^([0-9]{4,8})"#).firstMatch(
                in: folderName, range: NSRange(folderName.startIndex..., in: folderName)
            ), let r = Range(m.range(at: 1), in: folderName) {
                resolvedAppID = String(folderName[r])
            }
        }
        if resolvedAppID == nil {
            resolvedAppID = await Self.fetchSteamAppID(for: effectiveTitle)
        }
        let finalAppID = resolvedAppID ?? "480"

        let gbe64 = Self.locateGbeDLL(is64Bit: true)
        let gbe32 = Self.locateGbeDLL(is64Bit: false)

        // Scan PE binary + sibling UnityPlayer.dll for architecture, Steam API, D3D12, and WinHTTP
        var peInfo = PEImportInfo(is64Bit: true, importsSteamAPI: false, importsD3D12: false)
        if let exe = mainEXE {
            peInfo = Self.scanPEBinary(exePath: exe)
            if peInfo.importsD3D12 { hasD3D12 = true }
            let unityPlayerPath = ((exe as NSString).deletingLastPathComponent as NSString).appendingPathComponent("UnityPlayer.dll")
            if fm.fileExists(atPath: unityPlayerPath) {
                let upInfo = Self.scanPEBinary(exePath: unityPlayerPath)
                if upInfo.importsD3D12 { hasD3D12 = true }
            }
        }

        var patchModePill = "Goldberg x64"
        var targetDLLDirs: [String] = []

        if !existingSteamDLLs.isEmpty {
            // Path 1: Existing steam_api64.dll / steam_api.dll found
            for (dllPath, is64) in existingSteamDLLs {
                let dllSize = (try? fm.attributesOfItem(atPath: dllPath)[.size] as? Int64) ?? 0
                let hasOrigBackup = fm.fileExists(atPath: dllPath + ".original")
                    || fm.fileExists(atPath: dllPath + ".orig")
                    || fm.fileExists(atPath: dllPath + ".bak")
                let isAlreadyGoldberg = hasOrigBackup || dllSize > 2_000_000

                if isAlreadyGoldberg {
                    // Preserve pre-cracked Goldberg / Experimental Overlay DLL without overwriting
                    patchModePill = dllSize > 10_000_000 ? "Goldberg Overlay" : (is64 ? "Goldberg x64" : "Goldberg x86")
                    targetDLLDirs.append((dllPath as NSString).deletingLastPathComponent)
                } else {
                    let bakPath = dllPath + ".bak"
                    if !fm.fileExists(atPath: bakPath) {
                        try? fm.copyItem(atPath: dllPath, toPath: bakPath)
                    }
                    if let src = is64 ? gbe64 : gbe32 {
                        try? fm.removeItem(atPath: dllPath)
                        try? fm.copyItem(atPath: src, toPath: dllPath)
                    }
                    patchModePill = is64 ? "Goldberg x64" : "Goldberg x86"
                    targetDLLDirs.append((dllPath as NSString).deletingLastPathComponent)
                }
            }
            let finalPillSnapshot = patchModePill
            await MainActor.run {
                self.appendLog("gbe_fork ▸ [\(effectiveTitle)] 已就绪 (\(finalPillSnapshot), AppID: \(finalAppID))", highlight: true)
            }
        } else if let firstUnityData = unityDataDirs.first {
            // Path 2A: Unity game where original steam_api*.dll was stripped -> inject into <Game>_Data/Plugins/x86_64 (or x86) + next to .exe
            let is64 = peInfo.is64Bit
            let archFolder = is64 ? "x86_64" : "x86"
            let dllName = is64 ? "steam_api64.dll" : "steam_api.dll"
            let pluginDir = (firstUnityData as NSString).appendingPathComponent("Plugins/\(archFolder)")
            try? fm.createDirectory(atPath: pluginDir, withIntermediateDirectories: true)
            let destPluginDLL = (pluginDir as NSString).appendingPathComponent(dllName)
            if let src = is64 ? gbe64 : gbe32 {
                try? fm.removeItem(atPath: destPluginDLL)
                try? fm.copyItem(atPath: src, toPath: destPluginDLL)
                targetDLLDirs.append(pluginDir)
                if let exe = mainEXE {
                    let exeDir = (exe as NSString).deletingLastPathComponent
                    let exeDLL = (exeDir as NSString).appendingPathComponent(dllName)
                    try? fm.copyItem(atPath: src, toPath: exeDLL)
                    targetDLLDirs.append(exeDir)
                }
                patchModePill = is64 ? "Unity 补全 x64" : "Unity 补全 x86"
                await MainActor.run {
                    self.appendLog("unity-fix ▸ 检测到 Unity 游戏缺失 \(dllName)，已自动注入 Plugins/\(archFolder)！", highlight: true)
                }
            }
        } else if let firstUE = unrealSteamworksDirs.first {
            // Path 2B: Unreal Engine game where original steam_api*.dll was stripped
            let is64 = peInfo.is64Bit
            let dllName = is64 ? "steam_api64.dll" : "steam_api.dll"
            let destDLL = (firstUE as NSString).appendingPathComponent(dllName)
            if let src = is64 ? gbe64 : gbe32 {
                try? fm.copyItem(atPath: src, toPath: destDLL)
                targetDLLDirs.append(firstUE)
                patchModePill = is64 ? "UE 补全 x64" : "UE 补全 x86"
                await MainActor.run {
                    self.appendLog("ue-fix ▸ 检测到 Unreal 游戏缺失 \(dllName)，已自动注入 Steamworks 目录！", highlight: true)
                }
            }
        } else if let exe = mainEXE {
            // Path 2C: Native C++ / Custom Engine game (e.g. Order of the Sinking Star) -> PE Import Table injection next to .exe
            let exeDir = (exe as NSString).deletingLastPathComponent
            let is64 = peInfo.is64Bit
            let dllName = is64 ? "steam_api64.dll" : "steam_api.dll"
            let destDLL = (exeDir as NSString).appendingPathComponent(dllName)

            if let src = is64 ? gbe64 : gbe32 {
                try? fm.copyItem(atPath: src, toPath: destDLL)
                targetDLLDirs.append(exeDir)
                patchModePill = is64 ? "PE 补全 x64" : "PE 补全 x86"
                await MainActor.run {
                    self.appendLog("pe-scan ▸ 检测到 .exe 导入 \(dllName) 但原包缺失，已自动补全 Goldberg DLL！", highlight: true)
                }
            }
        }

        if let exe = mainEXE {
            let exeDir = (exe as NSString).deletingLastPathComponent
            if !targetDLLDirs.contains(exeDir) {
                targetDLLDirs.append(exeDir)
            }
        }
        for dir in targetDLLDirs {
            let settingsDir = (dir as NSString).appendingPathComponent("steam_settings")
            try? fm.createDirectory(atPath: settingsDir, withIntermediateDirectories: true)
            let appIdFile1 = (settingsDir as NSString).appendingPathComponent("steam_appid.txt")
            let appIdFile2 = (dir as NSString).appendingPathComponent("steam_appid.txt")
            let cfgFile = (settingsDir as NSString).appendingPathComponent("configs.user.ini")
            try? "\(finalAppID)\n".write(toFile: appIdFile1, atomically: true, encoding: .utf8)
            try? "\(finalAppID)\n".write(toFile: appIdFile2, atomically: true, encoding: .utf8)

            // Non-destructively update existing configs.user.ini in-place if present
            if var existingCfg = try? String(contentsOfFile: cfgFile, encoding: .utf8), !existingCfg.isEmpty {
                if let langRegex = try? NSRegularExpression(pattern: #"(?m)^language\s*=\s*[^\r\n]+"#) {
                    let range = NSRange(existingCfg.startIndex..., in: existingCfg)
                    if langRegex.firstMatch(in: existingCfg, range: range) != nil {
                        existingCfg = langRegex.stringByReplacingMatches(in: existingCfg, range: range, withTemplate: "language=schinese")
                    } else {
                        existingCfg += "\nlanguage=schinese\n"
                    }
                }
                if let countryRegex = try? NSRegularExpression(pattern: #"(?m)^ip_country\s*=\s*[^\r\n]+"#) {
                    let range = NSRange(existingCfg.startIndex..., in: existingCfg)
                    existingCfg = countryRegex.stringByReplacingMatches(in: existingCfg, range: range, withTemplate: "ip_country=CN")
                }
                try? existingCfg.write(toFile: cfgFile, atomically: true, encoding: .utf8)
            } else {
                let iniContent = "[user::general]\nlanguage=schinese\nip_country=CN\n"
                try? iniContent.write(toFile: cfgFile, atomically: true, encoding: .utf8)
            }
        }

        let isStandalonePatchPack = (mainEXE == nil)
        let configuredBottle = isStandalonePatchPack ? "独立补丁包" : Self.configureCrossOverBottle(
            gameTitle: effectiveTitle,
            exePath: mainEXE,
            hasD3D12: hasD3D12,
            hasWinHTTP: hasWinHTTP
        )

        let d3d12Flag = hasD3D12
        let winhttpFlag = hasWinHTTP
        let modePill = patchModePill
        let displayTitle = effectiveTitle
        await MainActor.run {
            guard let idx = self.patchTasks.firstIndex(where: { $0.id == taskID }) else { return }
            self.patchTasks[idx].title = displayTitle
            self.patchTasks[idx].status = .done
            self.patchTasks[idx].pill = modePill
            self.patchTasks[idx].rightText = isStandalonePatchPack ? "打开目录" : "▶ 启动"
            self.patchTasks[idx].exePath = mainEXE
            self.patchTasks[idx].appID = finalAppID
            let gfxDesc = d3d12Flag ? "D3DMetal" : "DXMT"
            let dllOverrideDesc = winhttpFlag ? " + winhttp" : ""
            if isStandalonePatchPack {
                self.patchTasks[idx].checklist = [
                    CheckItem(title: "Goldberg 补丁 (\(finalAppID)) · 已切换简中配置", isChecked: true),
                    CheckItem(title: "独立补丁包 (不含主程序 .exe，请覆盖至游戏目录)", isChecked: true)
                ]
            } else {
                self.patchTasks[idx].checklist = [
                    CheckItem(title: "steam_api64.dll ➔ Goldberg (\(finalAppID)) · 简中", isChecked: true),
                    CheckItem(title: "CrossOver 容器环境 (\(gfxDesc) + MSync\(dllOverrideDesc))", isChecked: true)
                ]
            }
            self.appendLog("config ▸ [\(displayTitle)] 已写入 AppID=\(finalAppID)、简中配置及 [\(configuredBottle)]", highlight: false)
        }
    }

    struct PEImportInfo: Sendable {
        let is64Bit: Bool
        let importsSteamAPI: Bool
        let importsD3D12: Bool
    }

    nonisolated static func scanPEBinary(exePath: String) -> PEImportInfo {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: exePath), options: .mappedIfSafe),
              data.count > 0x200 else {
            return PEImportInfo(is64Bit: true, importsSteamAPI: false, importsD3D12: false)
        }

        var is64 = true
        let peOffset = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.loadUnaligned(fromByteOffset: 0x3C, as: UInt32.self)
        }
        if Int(peOffset) + 26 < data.count {
            let magic = data.withUnsafeBytes { ptr -> UInt16 in
                ptr.loadUnaligned(fromByteOffset: Int(peOffset) + 24, as: UInt16.self)
            }
            is64 = (magic == 0x20B)
        }

        let ascii = String(decoding: data, as: UTF8.self).lowercased()
        let hasSteam = ascii.contains("steam_api64.dll") || ascii.contains("steam_api.dll")
        let hasD3D12 = ascii.contains("d3d12.dll") || ascii.contains("d3d12core.dll")
        return PEImportInfo(is64Bit: is64, importsSteamAPI: hasSteam, importsD3D12: hasD3D12)
    }

    nonisolated static func configureCrossOverBottle(
        gameTitle: String,
        exePath: String?,
        hasD3D12: Bool,
        hasWinHTTP: Bool
    ) -> String {
        let fm = FileManager.default
        let bottlesRoot = ("~/Library/Application Support/CrossOver/Bottles" as NSString).expandingTildeInPath
        guard fm.fileExists(atPath: bottlesRoot) else { return "Default" }

        let isTempTest = (exePath?.hasPrefix("/tmp/") == true) || (exePath?.hasPrefix("/private/tmp/") == true)
        let normalizedTitle: String = {
            let trimmed = gameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == trimmed.lowercased() {
                return trimmed.capitalized
            }
            return trimmed
        }()

        // 1. If exePath is already inside a CrossOver Bottle, use that bottle name
        var targetBottleName: String? = nil
        if let exe = exePath, exe.hasPrefix(bottlesRoot + "/") {
            let rel = String(exe.dropFirst((bottlesRoot + "/").count))
            targetBottleName = rel.components(separatedBy: "/").first
        }

        // 2. Otherwise check if a bottle matching gameTitle exists, or create a dedicated Win10_64 bottle
        if targetBottleName == nil {
            if let existingBottles = try? fm.contentsOfDirectory(atPath: bottlesRoot),
               let match = existingBottles.first(where: { $0.caseInsensitiveCompare(normalizedTitle) == .orderedSame }) {
                targetBottleName = match
            } else if !isTempTest {
                let cxBottleBin = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/cxbottle"
                if fm.fileExists(atPath: cxBottleBin) {
                    let createProc = Process()
                    createProc.executableURL = URL(fileURLWithPath: cxBottleBin)
                    createProc.arguments = [
                        "--bottle", normalizedTitle,
                        "--create",
                        "--template", "win10_64",
                        "--description", normalizedTitle
                    ]
                    createProc.standardOutput = FileHandle.nullDevice
                    createProc.standardError = FileHandle.nullDevice
                    try? createProc.run()
                    createProc.waitUntilExit()
                    let createdPath = (bottlesRoot as NSString).appendingPathComponent(normalizedTitle)
                    if fm.fileExists(atPath: createdPath) {
                        targetBottleName = normalizedTitle
                    }
                }
            }
            if targetBottleName == nil, let existingBottles = try? fm.contentsOfDirectory(atPath: bottlesRoot) {
                if existingBottles.contains("Order of the Sinking Star") {
                    targetBottleName = "Order of the Sinking Star"
                } else if existingBottles.contains("Esoteric Ebb") {
                    targetBottleName = "Esoteric Ebb"
                }
            }
        }

        guard let bottleName = targetBottleName else { return "Default" }
        let bottlePath = (bottlesRoot as NSString).appendingPathComponent(bottleName)
        let confPath = (bottlePath as NSString).appendingPathComponent("cxbottle.conf")

        // 3. Symlink external game folder into bottle's drive_c/<bottleName> so Wine C:/ path works seamlessly
        if let exe = exePath, !exe.hasPrefix(bottlesRoot) {
            let exeDir = (exe as NSString).deletingLastPathComponent
            let driveCDir = (bottlePath as NSString).appendingPathComponent("drive_c")
            let linkPath = (driveCDir as NSString).appendingPathComponent(bottleName)
            if fm.fileExists(atPath: driveCDir) {
                if let dest = try? fm.destinationOfSymbolicLink(atPath: linkPath), dest != exeDir {
                    try? fm.removeItem(atPath: linkPath)
                }
                if !fm.fileExists(atPath: linkPath) {
                    try? fm.createSymbolicLink(atPath: linkPath, withDestinationPath: exeDir)
                }
            }

            // 4. Register Windows Start Menu shortcut (.lnk) + sync CrossOver menu & icon
            if !isTempTest {
                let cxMenuConf = (bottlePath as NSString).appendingPathComponent("cxmenu.conf")
                let existingMenu = (try? String(contentsOfFile: cxMenuConf, encoding: .utf8)) ?? ""
                if !existingMenu.localizedCaseInsensitiveContains(bottleName) {
                    let exeFileName = (exe as NSString).lastPathComponent
                    let vbsPath = "/tmp/steamflow_lnk_\(UUID().uuidString).vbs"
                    let vbsContent = """
                    Set oWS = WScript.CreateObject("WScript.Shell")
                    Set oLink = oWS.CreateShortcut("C:\\users\\crossover\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\\(bottleName).lnk")
                    oLink.TargetPath = "C:\\\(bottleName)\\\(exeFileName)"
                    oLink.WorkingDirectory = "C:\\\(bottleName)"
                    oLink.Description = "\(bottleName)"
                    oLink.Save
                    """
                    try? vbsContent.write(toFile: vbsPath, atomically: true, encoding: .utf8)
                    let cxWine = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"
                    let cxMenu = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/cxmenu"
                    if fm.fileExists(atPath: cxWine) && fm.fileExists(atPath: cxMenu) {
                        let lnkProc = Process()
                        lnkProc.executableURL = URL(fileURLWithPath: cxWine)
                        lnkProc.arguments = ["--bottle", bottleName, "cscript.exe", "//NoLogo", "Z:\\" + vbsPath.replacingOccurrences(of: "/", with: "\\")]
                        lnkProc.standardOutput = FileHandle.nullDevice
                        lnkProc.standardError = FileHandle.nullDevice
                        try? lnkProc.run()
                        lnkProc.waitUntilExit()

                        for args in [["--bottle", bottleName, "--sync", "--mode", "install"], ["--bottle", bottleName, "--install"]] {
                            let menuProc = Process()
                            menuProc.executableURL = URL(fileURLWithPath: cxMenu)
                            menuProc.arguments = args
                            menuProc.standardOutput = FileHandle.nullDevice
                            menuProc.standardError = FileHandle.nullDevice
                            try? menuProc.run()
                            menuProc.waitUntilExit()
                        }

                        // If CrossOver.app is currently open, relaunch it so it reloads the new bottle & generates ~/Applications/CrossOver/<Game>.app
                        let refreshProc = Process()
                        refreshProc.executableURL = URL(fileURLWithPath: "/bin/sh")
                        refreshProc.arguments = ["-c", "if pgrep -x CrossOver >/dev/null 2>&1; then killall CrossOver && sleep 0.8 && open -g -a /Applications/CrossOver.app; fi"]
                        refreshProc.standardOutput = FileHandle.nullDevice
                        refreshProc.standardError = FileHandle.nullDevice
                        try? refreshProc.run()
                        refreshProc.waitUntilExit()
                    }
                    try? fm.removeItem(atPath: vbsPath)
                }
            }
        }

        // 5. Ensure [EnvironmentVariables] in cxbottle.conf has WINEMSYNC=1 (+ d3dmetal / winhttp if detected)
        if var confText = try? String(contentsOfFile: confPath, encoding: .utf8) {
            var changed = false
            if !confText.contains("\"WINEMSYNC\"") {
                confText += "\n\"WINEMSYNC\" = \"1\"\n"
                changed = true
            }
            if hasD3D12 && !confText.contains("\"d3dmetal\"") {
                confText += "\"CX_GRAPHICS_BACKEND\" = \"d3dmetal\"\n"
                changed = true
            }
            if hasWinHTTP && !confText.contains("winhttp=n,b") {
                confText += "\"WINEDLLOVERRIDES\" = \"winhttp=n,b\"\n"
                changed = true
            }
            if changed {
                try? confText.write(toFile: confPath, atomically: true, encoding: .utf8)
            }
        }

        return bottleName
    }

    nonisolated static func locateGbeDLL(is64Bit: Bool) -> String? {
        let sub = is64Bit ? "x64/steam_api64.dll" : "x86/steam_api.dll"
        if let resPath = Bundle.main.resourcePath {
            let bundled = (resPath as NSString).appendingPathComponent("gbe_fork/\(sub)")
            if FileManager.default.fileExists(atPath: bundled) { return bundled }
        }
        let appBundled = ("~/Applications/Chrysa.app/Contents/Resources/gbe_fork/\(sub)" as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: appBundled) { return appBundled }
        let localPath = ("~/gbe_fork_downloads/extract_2026_05_30/release/regular/\(sub)" as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: localPath) { return localPath }
        return nil
    }

    nonisolated static func fetchSteamAppID(for gameName: String) async -> String? {
        guard let encoded = gameName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://store.steampowered.com/api/storesearch/?term=\(encoded)&l=schinese&cc=CN") else {
            return nil
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]],
              let first = items.first,
              let idVal = first["id"] as? Int else {
            return nil
        }
        return String(idVal)
    }

    // MARK: - Launch in CrossOver (Direct Shortcut or Silent `wine --bottle` Launch)
    func launchGame(_ task: StudioTask) {
        let fm = FileManager.default
        let cxAppsDir = ("~/Applications/CrossOver" as NSString).expandingTildeInPath
        let shortcutApp = (cxAppsDir as NSString).appendingPathComponent("\(task.title).app")

        // 1. If a dedicated CrossOver Menu Helper .app exists in ~/Applications/CrossOver/<Title>.app, launch it directly
        if fm.fileExists(atPath: shortcutApp) {
            appendLog("crossover ▸ 正在通过容器快捷方式启动: \(task.title).app", highlight: true)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = [shortcutApp]
            try? proc.run()
            return
        }

        // 2. Otherwise launch directly via CrossOver's `wine --bottle <BottleName>` without wizard popups
        if let exe = task.exePath, fm.fileExists(atPath: exe) {
            let cxWine = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"
            let bottleName = Self.configureCrossOverBottle(
                gameTitle: task.title,
                exePath: exe,
                hasD3D12: false,
                hasWinHTTP: false
            )
            if fm.fileExists(atPath: cxWine) && bottleName != "Default" {
                appendLog("wine ▸ 正在通过容器 [\(bottleName)] 直接静默启动: \((exe as NSString).lastPathComponent)", highlight: true)
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: cxWine)
                proc.currentDirectoryURL = URL(fileURLWithPath: (exe as NSString).deletingLastPathComponent)
                proc.arguments = ["--bottle", bottleName, "--check", "--wait-children", exe]
                try? proc.run()
            } else {
                appendLog("crossover ▸ 正在通过 CrossOver 打开: \((exe as NSString).lastPathComponent)", highlight: true)
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                proc.arguments = ["-a", "/Applications/CrossOver.app", exe]
                try? proc.run()
            }
        } else if let dir = task.localPath, fm.fileExists(atPath: dir) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir)
            appendLog("finder ▸ 已在访达中打开游戏目录: \(task.title)", highlight: false)
        } else {
            appendLog("crossover ▸ 启动 \(task.title) (AppID: \(task.appID ?? "2057760"))", highlight: true)
        }
    }

    func pickFileForActiveTab() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        switch activeTab {
        case .download:
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.message = "选择种子文件 (.torrent) 或包含下载链接的文本"
            if panel.runModal() == .OK, let url = panel.url {
                startDownload(urlString: url.path)
            }
        case .unpack:
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.message = "选择需要解压的 .7z / .rar / .zip 压缩包"
            if panel.runModal() == .OK, let url = panel.url {
                startUnpack(filePath: url.path)
            }
        case .patch, .settings:
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.message = "选择游戏文件夹或主程序 .exe"
            if panel.runModal() == .OK, let url = panel.url {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                let folder = isDir.boolValue ? url.path : url.deletingLastPathComponent().path
                activeTab = .patch
                startPatch(folderPath: folder)
            }
        }
    }

    func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let fileURL = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        self.routeDroppedFile(url: fileURL)
                    }
                }
                return true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    if let text = item as? String {
                        Task { @MainActor in
                            self.activeTab = .download
                            self.startDownload(urlString: text)
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    private func routeDroppedFile(url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        if isDir.boolValue {
            if let items = try? FileManager.default.contentsOfDirectory(atPath: url.path),
               let archiveItem = items.sorted().first(where: { Self.isArchiveFile($0) }) {
                let fullArchive = (url.path as NSString).appendingPathComponent(archiveItem)
                activeTab = .unpack
                startUnpack(filePath: fullArchive)
                return
            }
            activeTab = .patch
            startPatch(folderPath: url.path)
        } else if Self.isArchiveFile(url.path) || Self.isInnoSetupInstaller(url.path) {
            activeTab = .unpack
            startUnpack(filePath: url.path)
        } else if url.pathExtension.lowercased() == "exe" {
            activeTab = .patch
            startPatch(folderPath: url.deletingLastPathComponent().path)
        } else {
            activeTab = .download
            startDownload(urlString: url.path)
        }
    }
}
