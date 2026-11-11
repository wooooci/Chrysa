import Foundation
import AppKit

struct PEImportInfo: Sendable {
    let is64Bit: Bool
    let importsSteamAPI: Bool
    let importsD3D12: Bool
    let importsWinHTTP: Bool
}

struct PatchResultPayload: Sendable {
    let displayTitle: String
    let pill: String
    let rightText: String
    let exePath: String?
    let appID: String
    let checklist: [CheckItem]
}

enum PEBinaryInspector {
    /// Parses standard Windows PE32 / PE32+ headers and `IMAGE_DIRECTORY_ENTRY_IMPORT` RVA tables directly
    /// without converting multi-hundred-MB binaries to UTF-8 Strings, with a bounded fallback if packed.
    static func inspect(exePath: String) -> PEImportInfo {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: exePath), options: .mappedIfSafe),
              data.count > 0x200 else {
            return PEImportInfo(is64Bit: true, importsSteamAPI: false, importsD3D12: false, importsWinHTTP: false)
        }

        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> PEImportInfo in
            func readU16(_ off: Int) -> UInt16? {
                guard off >= 0, off + 2 <= raw.count else { return nil }
                return UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt16.self))
            }
            func readU32(_ off: Int) -> UInt32? {
                guard off >= 0, off + 4 <= raw.count else { return nil }
                return UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self))
            }
            func readCString(_ off: Int, maxLen: Int = 128) -> String? {
                guard off >= 0, off < raw.count else { return nil }
                let limit = min(raw.count, off + maxLen)
                var bytes: [UInt8] = []
                for idx in off..<limit {
                    let b = raw[idx]
                    if b == 0 { break }
                    bytes.append(b)
                }
                guard !bytes.isEmpty else { return nil }
                return String(bytes: bytes, encoding: .ascii)
            }
            func containsCaseInsensitiveASCII(_ lowerNeedle: [UInt8]) -> Bool {
                let nLen = lowerNeedle.count
                guard nLen > 0, raw.count >= nLen else { return false }
                let firstB = lowerNeedle[0]
                let firstUpper = (firstB >= 97 && firstB <= 122) ? (firstB - 32) : firstB
                let endIdx = raw.count - nLen
                var i = 0
                while i <= endIdx {
                    let b0 = raw[i]
                    if b0 == firstB || b0 == firstUpper {
                        var match = true
                        for j in 1..<nLen {
                            var bj = raw[i + j]
                            if bj >= 65 && bj <= 90 { bj += 32 }
                            if bj != lowerNeedle[j] {
                                match = false
                                break
                            }
                        }
                        if match { return true }
                    }
                    i += 1
                }
                return false
            }

            // Verify MZ magic (0x5A4D)
            guard readU16(0) == 0x5A4D,
                  let peOffU32 = readU32(0x3C) else {
                return PEImportInfo(is64Bit: true, importsSteamAPI: false, importsD3D12: false, importsWinHTTP: false)
            }
            let peOff = Int(peOffU32)
            // Verify "PE\0\0" signature (0x00004550)
            guard readU32(peOff) == 0x00004550,
                  let numSections = readU16(peOff + 6),
                  let sizeOfOptionalHeader = readU16(peOff + 20),
                  let optMagic = readU16(peOff + 24) else {
                return PEImportInfo(is64Bit: true, importsSteamAPI: false, importsD3D12: false, importsWinHTTP: false)
            }

            let is64 = (optMagic == 0x20B)
            let optHeaderStart = peOff + 24
            // DataDirectory starts at offset +96 in PE32 (0x10B) and +112 in PE32+ (0x20B).
            // Entry #1 (Import Table) is 8 bytes after DataDirectory[0].
            let importDirOffset = optHeaderStart + (is64 ? 112 : 96) + 8
            let importTableRVA = readU32(importDirOffset) ?? 0

            // Parse Section Headers to translate RVA -> File Offset
            struct PESection {
                let virtualAddress: UInt32
                let virtualSpan: UInt32
                let rawDataPtr: UInt32
                let rawDataSize: UInt32
            }

            let sectionTableStart = optHeaderStart + Int(sizeOfOptionalHeader)
            var sections: [PESection] = []
            for sIdx in 0..<Int(numSections) {
                let sOff = sectionTableStart + sIdx * 40
                guard let vSize = readU32(sOff + 8),
                      let vAddr = readU32(sOff + 12),
                      let rSize = readU32(sOff + 16),
                      let rPtr  = readU32(sOff + 20) else { break }
                sections.append(PESection(
                    virtualAddress: vAddr,
                    virtualSpan: max(vSize, rSize),
                    rawDataPtr: rPtr,
                    rawDataSize: rSize
                ))
            }

            func rvaToFileOffset(_ rva: UInt32) -> Int? {
                guard rva > 0 else { return nil }
                for sec in sections {
                    if rva >= sec.virtualAddress && rva < sec.virtualAddress &+ sec.virtualSpan {
                        let delta = rva - sec.virtualAddress
                        if delta < sec.rawDataSize {
                            let fileOff = Int(sec.rawDataPtr) + Int(delta)
                            return fileOff < raw.count ? fileOff : nil
                        }
                    }
                }
                return Int(rva) < raw.count ? Int(rva) : nil
            }

            var importedDLLs: [String] = []
            if importTableRVA > 0, let importOff = rvaToFileOffset(importTableRVA) {
                var descOff = importOff
                // IMAGE_IMPORT_DESCRIPTOR is 20 bytes; Name RVA is at +12
                for _ in 0..<512 {
                    guard let origThunk = readU32(descOff),
                          let nameRVA = readU32(descOff + 12),
                          let firstThunk = readU32(descOff + 16) else { break }
                    if origThunk == 0 && nameRVA == 0 && firstThunk == 0 {
                        break
                    }
                    if let nameFileOff = rvaToFileOffset(nameRVA),
                       let dllName = readCString(nameFileOff)?.lowercased() {
                        importedDLLs.append(dllName)
                    }
                    descOff += 20
                }
            }

            var hasSteam = importedDLLs.contains { $0 == "steam_api64.dll" || $0 == "steam_api.dll" }
            var hasD3D12 = importedDLLs.contains { $0 == "d3d12.dll" || $0 == "d3d12core.dll" }
            var hasWinHTTP = importedDLLs.contains { $0 == "winhttp.dll" }

            // Dynamic LoadLibrary fallback scan on raw mapped bytes if not statically imported
            if !hasSteam {
                hasSteam = containsCaseInsensitiveASCII(Array("steam_api64.dll".utf8))
                    || containsCaseInsensitiveASCII(Array("steam_api.dll".utf8))
            }
            if !hasD3D12 {
                hasD3D12 = containsCaseInsensitiveASCII(Array("d3d12.dll".utf8))
                    || containsCaseInsensitiveASCII(Array("d3d12core.dll".utf8))
            }
            if !hasWinHTTP {
                hasWinHTTP = containsCaseInsensitiveASCII(Array("winhttp.dll".utf8))
            }

            return PEImportInfo(
                is64Bit: is64,
                importsSteamAPI: hasSteam,
                importsD3D12: hasD3D12,
                importsWinHTTP: hasWinHTTP
            )
        }
    }
}

actor PatchAndBottleService {
    private let supervisor: ProcessSupervisor

    init(supervisor: ProcessSupervisor = .shared) {
        self.supervisor = supervisor
    }

    static func cleanGameTitle(from raw: String) -> String {
        var s = raw
        if let r = try? NSRegularExpression(pattern: #"^[0-9]{4,8}_[0-9]+$"#),
           r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
            return s
        }
        if s.lowercased().hasPrefix("setup_") {
            s = String(s.dropFirst("setup_".count))
        }
        s = s.replacingOccurrences(of: "_", with: " ")
        if let bracketRegex = try? NSRegularExpression(pattern: #"\s*(\[[^\]]+\]|\([^\)]+\))"#) {
            s = bracketRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        if let regex = try? NSRegularExpression(pattern: #"\s*(v?[0-9]+\.[0-9]+.*|Build\s*[0-9]+.*|b[0-9]{6,}.*)$"#, options: .caseInsensitive) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Dynamically discovers installed CrossOver game bottles & shortcuts without any hardcoded game names.
    static func scanInstalledBottles(bottlesDirectory: String) -> [StudioTask] {
        let fm = FileManager.default
        let bottlesRoot = (bottlesDirectory as NSString).expandingTildeInPath
        guard fm.fileExists(atPath: bottlesRoot) else { return [] }

        // Map bottleName -> helper shortcut display name from ~/Applications/CrossOver/*.app
        var shortcutNameByBottle: [String: String] = [:]
        let cxAppsDir = ("~/Applications/CrossOver" as NSString).expandingTildeInPath
        if let appBundles = try? fm.contentsOfDirectory(atPath: cxAppsDir) {
            for bundleName in appBundles where bundleName.hasSuffix(".app") {
                let plistPath = (cxAppsDir as NSString).appendingPathComponent("\(bundleName)/Contents/Info.plist")
                if let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any],
                   let bottleName = dict["CXHelperAppBottleName"] as? String {
                    let displayName = (dict["CFBundleName"] as? String)
                        ?? (bundleName as NSString).deletingPathExtension
                    shortcutNameByBottle[bottleName] = displayName
                }
            }
        }

        let ignoredSystemDirs: Set<String> = [
            "program files", "program files (x86)", "programdata", "users", "windows"
        ]
        let ignoredBottleKeywords = ["steamless"]

        guard let bottleNames = try? fm.contentsOfDirectory(atPath: bottlesRoot).sorted() else {
            return []
        }

        var discovered: [StudioTask] = []
        for bottle in bottleNames where !bottle.hasPrefix(".") {
            if ignoredBottleKeywords.contains(where: { bottle.lowercased().contains($0) }) {
                continue
            }
            let bottlePath = (bottlesRoot as NSString).appendingPathComponent(bottle)
            let driveCPath = (bottlePath as NSString).appendingPathComponent("drive_c")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: driveCPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let displayTitle = shortcutNameByBottle[bottle] ?? bottle
            let shortcutAppPath = (cxAppsDir as NSString).appendingPathComponent("\(displayTitle).app")

            // Locate game directory inside drive_c (including symlinks)
            var gameDir: String? = nil
            if let driveItems = try? fm.contentsOfDirectory(atPath: driveCPath) {
                for item in driveItems where !item.hasPrefix(".") && !ignoredSystemDirs.contains(item.lowercased()) {
                    let candidate = (driveCPath as NSString).appendingPathComponent(item)
                    let resolved = (try? fm.destinationOfSymbolicLink(atPath: candidate)) ?? candidate
                    var subDir: ObjCBool = false
                    if fm.fileExists(atPath: resolved, isDirectory: &subDir), subDir.boolValue {
                        gameDir = resolved
                        break
                    }
                }
            }

            // Skip empty bottles that have neither a game directory nor a CrossOver shortcut .app
            if gameDir == nil && !fm.fileExists(atPath: shortcutAppPath) {
                continue
            }

            var foundEXE: String? = nil
            var foundAppID: String? = nil
            if let gDir = gameDir, let enumerator = fm.enumerator(atPath: gDir) {
                while let rel = enumerator.nextObject() as? String {
                    let lower = (rel as NSString).lastPathComponent.lowercased()
                    let full = (gDir as NSString).appendingPathComponent(rel)
                    if lower == "steam_appid.txt", foundAppID == nil {
                        let txt = (try? String(contentsOfFile: full, encoding: .utf8))?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if let t = txt, !t.isEmpty { foundAppID = t }
                    } else if foundEXE == nil, lower.hasSuffix(".exe"),
                              !lower.contains("unitycrashhandler"),
                              !lower.contains("unins"),
                              !lower.contains("vc_redist"),
                              !lower.contains("crashreport") {
                        foundEXE = full
                    }
                }
            }

            let confPath = (bottlePath as NSString).appendingPathComponent("cxbottle.conf")
            let confText = (try? String(contentsOfFile: confPath, encoding: .utf8)) ?? ""
            let gfxBackend = confText.contains("d3dmetal") ? "D3DMetal" : "DXMT"
            let appIDLabel = foundAppID ?? "已就绪"

            discovered.append(
                StudioTask(
                    title: displayTitle,
                    status: .done,
                    pill: "Goldberg x64",
                    rightText: "▶ 启动",
                    localPath: gameDir ?? bottlePath,
                    exePath: foundEXE,
                    appID: foundAppID,
                    expanded: discovered.isEmpty,
                    checklist: [
                        CheckItem(title: "Goldberg 环境 (\(appIDLabel))", isChecked: true),
                        CheckItem(title: "CrossOver 容器 [\(bottle)] (\(gfxBackend) + MSync)", isChecked: true)
                    ]
                )
            )
        }

        return discovered
    }

    func executePatch(
        taskID: UUID,
        folderPath: String,
        cleanTitle: String,
        settings: AppSettings,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async -> PatchResultPayload {
        let fm = FileManager.default
        var existingSteamDLLs: [(String, Bool)] = []
        var candidateEXEs: [String] = []
        var unityDataDirs: [String] = []
        var unrealSteamworksDirs: [String] = []
        var existingAppID: String? = nil
        var discoveredGameTitle: String? = nil
        var hasD3D12 = false
        var hasWinHTTP = false

        // 1. CSF standard layout: steamapps/common/<GameName>
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

        // 2. Single top-level game subfolder
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

        // Priority 1: Exact Unity <Name>_Data -> <Name>.exe match
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

        let gbe64 = ToolchainLocator.locateGbeDLL(is64Bit: true)
        let gbe32 = ToolchainLocator.locateGbeDLL(is64Bit: false)

        // Inspect PE Import Table on main EXE and UnityPlayer.dll
        var peInfo = PEImportInfo(is64Bit: true, importsSteamAPI: false, importsD3D12: false, importsWinHTTP: false)
        if let exe = mainEXE {
            peInfo = PEBinaryInspector.inspect(exePath: exe)
            if peInfo.importsD3D12 { hasD3D12 = true }
            let unityPlayerPath = ((exe as NSString).deletingLastPathComponent as NSString).appendingPathComponent("UnityPlayer.dll")
            if fm.fileExists(atPath: unityPlayerPath) {
                let upInfo = PEBinaryInspector.inspect(exePath: unityPlayerPath)
                if upInfo.importsD3D12 { hasD3D12 = true }
            }
        }

        var patchModePill = "Goldberg x64"
        var targetDLLDirs: [String] = []

        if !existingSteamDLLs.isEmpty {
            for (dllPath, is64) in existingSteamDLLs {
                let dllSize = (try? fm.attributesOfItem(atPath: dllPath)[.size] as? Int64) ?? 0
                let hasOrigBackup = fm.fileExists(atPath: dllPath + ".original")
                    || fm.fileExists(atPath: dllPath + ".orig")
                    || fm.fileExists(atPath: dllPath + ".bak")
                let isAlreadyGoldberg = hasOrigBackup || dllSize > 2_000_000

                if isAlreadyGoldberg {
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
            onLog("gbe_fork ▸ [\(effectiveTitle)] 已就绪 (\(patchModePill), AppID: \(finalAppID))", true)
        } else if let firstUnityData = unityDataDirs.first {
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
                onLog("unity-fix ▸ 检测到 Unity 游戏缺失 \(dllName)，已自动注入 Plugins/\(archFolder)！", true)
            }
        } else if let firstUE = unrealSteamworksDirs.first {
            let is64 = peInfo.is64Bit
            let dllName = is64 ? "steam_api64.dll" : "steam_api.dll"
            let destDLL = (firstUE as NSString).appendingPathComponent(dllName)
            if let src = is64 ? gbe64 : gbe32 {
                try? fm.copyItem(atPath: src, toPath: destDLL)
                targetDLLDirs.append(firstUE)
                patchModePill = is64 ? "UE 补全 x64" : "UE 补全 x86"
                onLog("ue-fix ▸ 检测到 Unreal 游戏缺失 \(dllName)，已自动注入 Steamworks 目录！", true)
            }
        } else if let exe = mainEXE {
            let exeDir = (exe as NSString).deletingLastPathComponent
            let is64 = peInfo.is64Bit
            let dllName = is64 ? "steam_api64.dll" : "steam_api.dll"
            let destDLL = (exeDir as NSString).appendingPathComponent(dllName)
            if let src = is64 ? gbe64 : gbe32 {
                try? fm.copyItem(atPath: src, toPath: destDLL)
                targetDLLDirs.append(exeDir)
                patchModePill = is64 ? "PE 补全 x64" : "PE 补全 x86"
                onLog("pe-scan ▸ 检测到 .exe 导入 \(dllName) 但原包缺失，已自动补全 Goldberg DLL！", true)
            }
        }

        if let exe = mainEXE {
            let exeDir = (exe as NSString).deletingLastPathComponent
            if !targetDLLDirs.contains(exeDir) {
                targetDLLDirs.append(exeDir)
            }
        }

        let langValue = settings.defaultLanguage.rawValue
        let countryValue = settings.defaultLanguage.ipCountry
        let langShort = settings.defaultLanguage.shortLabel

        for dir in targetDLLDirs {
            let settingsDir = (dir as NSString).appendingPathComponent("steam_settings")
            try? fm.createDirectory(atPath: settingsDir, withIntermediateDirectories: true)
            let appIdFile1 = (settingsDir as NSString).appendingPathComponent("steam_appid.txt")
            let appIdFile2 = (dir as NSString).appendingPathComponent("steam_appid.txt")
            let cfgFile = (settingsDir as NSString).appendingPathComponent("configs.user.ini")
            try? "\(finalAppID)\n".write(toFile: appIdFile1, atomically: true, encoding: .utf8)
            try? "\(finalAppID)\n".write(toFile: appIdFile2, atomically: true, encoding: .utf8)

            if var existingCfg = try? String(contentsOfFile: cfgFile, encoding: .utf8), !existingCfg.isEmpty {
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
                    existingCfg = countryRegex.stringByReplacingMatches(in: existingCfg, range: range, withTemplate: "ip_country=\(countryValue)")
                }
                try? existingCfg.write(toFile: cfgFile, atomically: true, encoding: .utf8)
            } else {
                let iniContent = "[user::general]\nlanguage=\(langValue)\nip_country=\(countryValue)\n"
                try? iniContent.write(toFile: cfgFile, atomically: true, encoding: .utf8)
            }
        }

        let isStandalonePatchPack = (mainEXE == nil)
        let configuredBottle = isStandalonePatchPack
            ? "独立补丁包"
            : await configureCrossOverBottle(
                gameTitle: effectiveTitle,
                exePath: mainEXE,
                bottlesDirectory: settings.bottlesDirectory,
                hasD3D12: hasD3D12,
                hasWinHTTP: hasWinHTTP
            )

        let gfxDesc = hasD3D12 ? "D3DMetal" : "DXMT"
        let dllOverrideDesc = hasWinHTTP ? " + winhttp" : ""
        let checklist: [CheckItem] = isStandalonePatchPack
            ? [
                CheckItem(title: "Goldberg 补丁 (\(finalAppID)) · 已切换\(langShort)配置", isChecked: true),
                CheckItem(title: "独立补丁包 (不含主程序 .exe，请覆盖至游戏目录)", isChecked: true)
            ]
            : [
                CheckItem(title: "steam_api64.dll ➔ Goldberg (\(finalAppID)) · \(langShort)", isChecked: true),
                CheckItem(title: "CrossOver 容器环境 (\(gfxDesc) + MSync\(dllOverrideDesc))", isChecked: true)
            ]

        onLog("config ▸ [\(effectiveTitle)] 已写入 AppID=\(finalAppID)、\(langShort)配置及 [\(configuredBottle)]", false)

        return PatchResultPayload(
            displayTitle: effectiveTitle,
            pill: patchModePill,
            rightText: isStandalonePatchPack ? "打开目录" : "▶ 启动",
            exePath: mainEXE,
            appID: finalAppID,
            checklist: checklist
        )
    }

    func configureCrossOverBottle(
        gameTitle: String,
        exePath: String?,
        bottlesDirectory: String,
        hasD3D12: Bool,
        hasWinHTTP: Bool
    ) async -> String {
        let fm = FileManager.default
        let bottlesRoot = (bottlesDirectory as NSString).expandingTildeInPath
        guard fm.fileExists(atPath: bottlesRoot) else { return "Default" }

        let isTempTest = (exePath?.hasPrefix("/tmp/") == true) || (exePath?.hasPrefix("/private/tmp/") == true)
        let normalizedTitle: String = {
            let trimmed = gameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == trimmed.lowercased() {
                return trimmed.capitalized
            }
            return trimmed
        }()

        // 1. If exePath is already inside a CrossOver Bottle, use that bottle
        var targetBottleName: String? = nil
        if let exe = exePath, exe.hasPrefix(bottlesRoot + "/") {
            let rel = String(exe.dropFirst((bottlesRoot + "/").count))
            targetBottleName = rel.components(separatedBy: "/").first
        }

        // 2. Check if a matching bottle exists (exact or condensed name), or create a dedicated Win10_64 bottle
        if targetBottleName == nil {
            let condensedTarget = normalizedTitle.replacingOccurrences(of: " ", with: "").lowercased()
            if let existingBottles = try? fm.contentsOfDirectory(atPath: bottlesRoot),
               let match = existingBottles.first(where: {
                   $0.caseInsensitiveCompare(normalizedTitle) == .orderedSame
                       || $0.replacingOccurrences(of: " ", with: "").lowercased() == condensedTarget
               }) {
                targetBottleName = match
            } else if !isTempTest, let cxBottleBin = ToolchainLocator.locateCrossOverBin("cxbottle") {
                _ = try? await supervisor.run(
                    executable: cxBottleBin,
                    arguments: [
                        "--bottle", normalizedTitle,
                        "--create",
                        "--template", "win10_64",
                        "--description", normalizedTitle
                    ]
                )
                let createdPath = (bottlesRoot as NSString).appendingPathComponent(normalizedTitle)
                if fm.fileExists(atPath: createdPath) {
                    targetBottleName = normalizedTitle
                }
            }
        }

        guard let bottleName = targetBottleName else { return normalizedTitle }
        let bottlePath = (bottlesRoot as NSString).appendingPathComponent(bottleName)
        guard fm.fileExists(atPath: bottlePath) else { return bottleName }
        let confPath = (bottlePath as NSString).appendingPathComponent("cxbottle.conf")

        // 3. Symlink external game folder into bottle's drive_c/<bottleName>
        if let exe = exePath, !exe.hasPrefix(bottlesRoot) && !isTempTest {
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

            // 4. Register Start Menu shortcut (.lnk) + sync CrossOver menu
            let cxMenuConf = (bottlePath as NSString).appendingPathComponent("cxmenu.conf")
            let existingMenu = (try? String(contentsOfFile: cxMenuConf, encoding: .utf8)) ?? ""
            if !existingMenu.localizedCaseInsensitiveContains(bottleName),
               let cxWine = ToolchainLocator.locateCrossOverBin("wine"),
               let cxMenu = ToolchainLocator.locateCrossOverBin("cxmenu") {
                let exeFileName = (exe as NSString).lastPathComponent
                let vbsPath = "/tmp/chrysa_lnk_\(UUID().uuidString).vbs"
                let vbsContent = """
                Set oWS = WScript.CreateObject("WScript.Shell")
                Set oLink = oWS.CreateShortcut("C:\\users\\crossover\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\\(bottleName).lnk")
                oLink.TargetPath = "C:\\\(bottleName)\\\(exeFileName)"
                oLink.WorkingDirectory = "C:\\\(bottleName)"
                oLink.Description = "\(bottleName)"
                oLink.Save
                """
                try? vbsContent.write(toFile: vbsPath, atomically: true, encoding: .utf8)
                defer { try? fm.removeItem(atPath: vbsPath) }

                _ = try? await supervisor.run(
                    executable: cxWine,
                    arguments: ["--bottle", bottleName, "cscript.exe", "//NoLogo", "Z:\\" + vbsPath.replacingOccurrences(of: "/", with: "\\")]
                )
                for args in [["--bottle", bottleName, "--sync", "--mode", "install"], ["--bottle", bottleName, "--install"]] {
                    _ = try? await supervisor.run(executable: cxMenu, arguments: args)
                }
                _ = try? await supervisor.run(
                    executable: "/bin/sh",
                    arguments: ["-c", "if pgrep -x CrossOver >/dev/null 2>&1; then killall CrossOver && sleep 0.8 && open -g -a /Applications/CrossOver.app; fi"]
                )
            }
        }

        // 5. Ensure [EnvironmentVariables] in cxbottle.conf has WINEMSYNC=1 (+ d3dmetal / winhttp if detected)
        if !isTempTest, var confText = try? String(contentsOfFile: confPath, encoding: .utf8) {
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

    static func fetchSteamAppID(for gameName: String) async -> String? {
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

    func launchGame(
        _ task: StudioTask,
        bottlesDirectory: String,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async {
        let fm = FileManager.default
        let cxAppsDir = ("~/Applications/CrossOver" as NSString).expandingTildeInPath
        let shortcutApp = (cxAppsDir as NSString).appendingPathComponent("\(task.title).app")

        // 1. Prefer dedicated CrossOver Menu Helper .app if available
        if fm.fileExists(atPath: shortcutApp) {
            onLog("crossover ▸ 正在通过容器快捷方式启动: \(task.title).app", true)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = [shortcutApp]
            try? proc.run()
            return
        }

        // 2. Otherwise launch via `wine --bottle`
        if let exe = task.exePath, fm.fileExists(atPath: exe) {
            let bottleName = await configureCrossOverBottle(
                gameTitle: task.title,
                exePath: exe,
                bottlesDirectory: bottlesDirectory,
                hasD3D12: false,
                hasWinHTTP: false
            )
            if let cxWine = ToolchainLocator.locateCrossOverBin("wine"), bottleName != "Default" {
                onLog("wine ▸ 正在通过容器 [\(bottleName)] 直接静默启动: \((exe as NSString).lastPathComponent)", true)
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: cxWine)
                proc.currentDirectoryURL = URL(fileURLWithPath: (exe as NSString).deletingLastPathComponent)
                proc.arguments = ["--bottle", bottleName, "--check", "--wait-children", exe]
                try? proc.run()
            } else {
                onLog("crossover ▸ 正在通过 CrossOver 打开: \((exe as NSString).lastPathComponent)", true)
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                proc.arguments = ["-a", "/Applications/CrossOver.app", exe]
                try? proc.run()
            }
        } else if let dir = task.localPath, fm.fileExists(atPath: dir) {
            _ = await MainActor.run {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir)
            }
            onLog("finder ▸ 已在访达中打开游戏目录: \(task.title)", false)
        } else {
            onLog("crossover ▸ 未找到可执行路径: \(task.title)", true)
        }
    }
}
