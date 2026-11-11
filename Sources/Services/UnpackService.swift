import Foundation

enum UnpackOutcome: Sendable {
    case completed(outDir: String, baseName: String, pill: String)
    case cancelled
    case failed(pill: String)
}

actor UnpackService {
    private let supervisor: ProcessSupervisor

    init(supervisor: ProcessSupervisor = .shared) {
        self.supervisor = supervisor
    }

    static func isArchiveFile(_ path: String) -> Bool {
        let lower = path.lowercased()
        let base = (lower as NSString).lastPathComponent
        let exts = [".7z", ".rar", ".zip", ".tar.zst", ".tar.xz", ".iso", ".001"]
        if exts.contains(where: { lower.hasSuffix($0) }) {
            return true
        }
        if let decoded = HostResolverRegistry.decodeBase64FilenameIfPossible((path as NSString).lastPathComponent),
           exts.contains(where: { decoded.lowercased().hasSuffix($0) }) {
            return true
        }
        if base.hasPrefix("setup_") && (base.hasSuffix(".exe") || base.hasSuffix(".bin")) {
            return true
        }
        return false
    }

    static func isInnoSetupInstaller(_ path: String) -> Bool {
        guard path.lowercased().hasSuffix(".exe"),
              let innoBin = ToolchainLocator.locateInnoextract(),
              FileManager.default.fileExists(atPath: path) else {
            return false
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: innoBin)
        proc.arguments = ["-i", "-s", path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    static func normalizeMultipartArchivePath(_ path: String) -> String {
        let lastComp = (path as NSString).lastPathComponent
        if let decodedName = HostResolverRegistry.decodeBase64FilenameIfPossible(lastComp) {
            let parent = (path as NSString).deletingLastPathComponent
            let renamedPath = (parent as NSString).appendingPathComponent(decodedName)
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: renamedPath)
                if (try? FileManager.default.moveItem(atPath: path, toPath: renamedPath)) != nil {
                    return renamedPath
                }
            } else if FileManager.default.fileExists(atPath: renamedPath) {
                return renamedPath
            }
        }
        let range = NSRange(path.startIndex..., in: path)
        // 1. .7z.002 -> .7z.001
        if let regex = try? NSRegularExpression(pattern: #"\.7z\.[0-9]{3}$"#, options: .caseInsensitive),
           regex.firstMatch(in: path, range: range) != nil {
            let firstVol = regex.stringByReplacingMatches(in: path, range: range, withTemplate: ".7z.001")
            if FileManager.default.fileExists(atPath: firstVol) { return firstVol }
        }
        // 2. .part2.rar / .part02.rar -> .part1.rar / .part01.rar
        if let rarRegex = try? NSRegularExpression(pattern: #"\.part([0-9]+)\.rar$"#, options: .caseInsensitive),
           let m = rarRegex.firstMatch(in: path, range: range),
           let numRange = Range(m.range(at: 1), in: path) {
            let digits = path[numRange].count
            let oneStr = String(repeating: "0", count: max(0, digits - 1)) + "1"
            let firstRar = rarRegex.stringByReplacingMatches(in: path, range: range, withTemplate: ".part\(oneStr).rar")
            if FileManager.default.fileExists(atPath: firstRar) { return firstRar }
        }
        // 3. GOG Inno Setup data slice: setup_xxx-1.bin -> setup_xxx.exe
        if let binRegex = try? NSRegularExpression(pattern: #"-[0-9]+\.bin$"#, options: .caseInsensitive),
           binRegex.firstMatch(in: path, range: range) != nil {
            let setupExe = binRegex.stringByReplacingMatches(in: path, range: range, withTemplate: ".exe")
            if FileManager.default.fileExists(atPath: setupExe) { return setupExe }
        }
        return path
    }

    func mergeGOGDLCInstaller(dlcExePath: String, intoDir outDir: String, taskID: UUID? = nil) async -> Bool {
        guard let innoBin = ToolchainLocator.locateInnoextract() else { return false }
        let res = try? await supervisor.run(
            executable: innoBin,
            arguments: ["-e", "-m", "-g", "--collisions=overwrite", "-s", "-d", outDir, dlcExePath],
            taskID: taskID
        )
        return res?.exitCode == 0
    }

    func executeUnpack(
        taskID: UUID,
        archivePath: String,
        candidatePasswords: [String],
        deleteArchiveAfterUnpack: Bool = false,
        onProgress: @escaping @Sendable (Double, String?) -> Void,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async -> UnpackOutcome {
        await supervisor.clearCancellation(for: taskID)

        let parentDir = (archivePath as NSString).deletingLastPathComponent
        var rawBase = ((archivePath as NSString).lastPathComponent as NSString).deletingPathExtension
        if rawBase.lowercased().hasPrefix("setup_") {
            rawBase = String(rawBase.dropFirst("setup_".count))
        }
        if rawBase.lowercased().hasSuffix(".7z") || rawBase.lowercased().hasSuffix(".tar") || rawBase.lowercased().hasSuffix(".part1") || rawBase.lowercased().hasSuffix(".part01") {
            rawBase = (rawBase as NSString).deletingPathExtension
        }
        let baseName = PatchAndBottleService.cleanGameTitle(from: rawBase)
        let outDir = (parentDir as NSString).appendingPathComponent(baseName)

        // Branch 1: GOG / Inno Setup Installer (.exe + .bin)
        if Self.isInnoSetupInstaller(archivePath), let innoBin = ToolchainLocator.locateInnoextract() {
            try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            onLog("innoextract ▸ 检测到 GOG Inno Setup 安装包，开始原生免安装解包至 [\(baseName)]...", true)

            var installersToExtract: [String] = [archivePath]
            if let siblings = try? FileManager.default.contentsOfDirectory(atPath: parentDir) {
                let dlcSetupExes = siblings
                    .filter { $0.lowercased().hasPrefix("setup_") && $0.lowercased().hasSuffix(".exe") }
                    .map { (parentDir as NSString).appendingPathComponent($0) }
                    .filter {
                        $0 != archivePath
                            && !FileManager.default.fileExists(atPath: $0 + ".aria2")
                            && Self.isInnoSetupInstaller($0)
                    }
                    .sorted()
                installersToExtract.append(contentsOf: dlcSetupExes)
            }

            var allOK = true
            for (idx, instPath) in installersToExtract.enumerated() {
                if await supervisor.isCancelled(taskID) { return .cancelled }
                let instName = (instPath as NSString).lastPathComponent
                let totalCount = installersToExtract.count
                let pillText = totalCount > 1 ? "GOG \(idx + 1)/\(totalCount)" : "GOG 解包中"
                onProgress(max(0.1, Double(idx) / Double(totalCount)), pillText)
                if idx > 0 {
                    onLog("innoextract ▸ 自动合并同目录 DLC 安装包: \(instName)", true)
                }

                let res = try? await supervisor.run(
                    executable: innoBin,
                    arguments: ["-e", "-m", "-g", "--collisions=overwrite", "-s", "-d", outDir, instPath],
                    taskID: taskID
                )
                if res?.exitCode != 0 {
                    allOK = false
                    break
                }
            }

            if await supervisor.isCancelled(taskID) { return .cancelled }

            let extractedItems = (try? FileManager.default.contentsOfDirectory(atPath: outDir))?.filter { !$0.hasPrefix(".") } ?? []
            guard allOK && !extractedItems.isEmpty else {
                if extractedItems.isEmpty {
                    try? FileManager.default.removeItem(atPath: outDir)
                }
                onLog("error ▸ GOG 安装包解包未完成 (可能缺少配套的 -1.bin 数据卷)！", true)
                return .failed(pill: "缺少 .bin 分卷")
            }

            await repairMacOSPermissions(outDir: outDir)
            if deleteArchiveAfterUnpack {
                cleanupSourceArchive(archivePath: archivePath, onLog: onLog)
            }
            onLog("innoextract ▸ GOG 游戏与 DLC 解包完成并已修复权限: \(baseName)", true)
            return .completed(outDir: outDir, baseName: baseName, pill: "GOG 已解包")
        }

        // Branch 2: Standard 7zz / unrar / unar pipeline
        guard let sevenZip = ToolchainLocator.locateSevenZip() else {
            onLog("error ▸ 未找到 7zz 解压内核 (/opt/homebrew/bin/7zz)", true)
            return .failed(pill: "缺少 7zz")
        }

        let unrarBin = ToolchainLocator.locateUnrar()
        let isRarArchive = archivePath.lowercased().hasSuffix(".rar")

        // Instant 5ms Password Header / Smallest-File Probe
        var foundPwd: String? = nil
        var foundIdx: Int = 0
        for (idx, pwd) in candidatePasswords.enumerated() {
            if await supervisor.isCancelled(taskID) { return .cancelled }
            guard let listRes = try? await supervisor.run(
                executable: sevenZip,
                arguments: ["l", "-slt", "-p\(pwd)", "-y", archivePath],
                taskID: taskID,
                captureOutput: true
            ) else { continue }

            if listRes.exitCode == 0 {
                let outText = listRes.outputString
                if !pwd.isEmpty || !outText.contains("Encrypted = +") {
                    foundPwd = pwd
                    foundIdx = idx
                    break
                } else {
                    var sampleFile: String? = nil
                    for line in outText.components(separatedBy: .newlines) {
                        if line.hasPrefix("Path = ") && !line.hasSuffix(".7z") && !line.hasSuffix(".rar") && !line.hasSuffix(".zip") {
                            let candidate = String(line.dropFirst("Path = ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                            if candidate.contains(".") {
                                sampleFile = candidate
                                break
                            }
                        }
                    }
                    if let sf = sampleFile {
                        for (pIdx, cPwd) in candidatePasswords.enumerated() where !cPwd.isEmpty {
                            if await supervisor.isCancelled(taskID) { return .cancelled }
                            let exe = (isRarArchive && unrarBin != nil) ? unrarBin! : sevenZip
                            let args = (isRarArchive && unrarBin != nil)
                                ? ["t", "-y", "-p\(cPwd)", archivePath, sf]
                                : ["t", "-p\(cPwd)", "-bso0", "-bse0", "-y", archivePath, sf]
                            if let tRes = try? await supervisor.run(executable: exe, arguments: args, taskID: taskID),
                               tRes.exitCode == 0 {
                                foundPwd = cPwd
                                foundIdx = pIdx
                                break
                            }
                        }
                    }
                    break
                }
            }
        }

        let finalPwd = foundPwd ?? ""
        let engineLabel = (isRarArchive && unrarBin != nil) ? "unrar" : "7zz"
        if foundPwd != nil {
            if finalPwd.isEmpty {
                onLog("\(engineLabel) ▸ 检测到无加密压缩包，开始高速解压...", false)
            } else {
                onLog("\(engineLabel) ▸ 密码本第 #\(String(format: "%02d", foundIdx)) 项毫秒级命中 (已隐藏明文)，开始解压...", true)
            }
        } else {
            onLog("\(engineLabel) ▸ 默认密码本未命中，尝试使用空密码或切换备用引擎解压...", false)
        }

        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let mainExe = (isRarArchive && unrarBin != nil) ? unrarBin! : sevenZip
        let mainArgs: [String] = {
            if isRarArchive && unrarBin != nil {
                let pwdArg = finalPwd.isEmpty ? "-p-" : "-p\(finalPwd)"
                return ["x", "-y", "-o+", pwdArg, archivePath, "\(outDir)/"]
            } else {
                return ["x", "-p\(finalPwd)", "-bsp1", "-y", "-o\(outDir)", archivePath]
            }
        }()

        do {
            let mainRes = try await supervisor.run(
                executable: mainExe,
                arguments: mainArgs,
                taskID: taskID,
                captureOutput: false,
                mergeStderr: true
            ) { chunk in
                if let m = try? NSRegularExpression(pattern: #"([0-9]{1,3})%"#).firstMatch(
                    in: chunk, range: NSRange(chunk.startIndex..., in: chunk)
                ), let r = Range(m.range(at: 1), in: chunk), let pct = Double(chunk[r]) {
                    onProgress(max(0.05, min(0.99, pct / 100.0)), nil)
                }
            }

            if await supervisor.isCancelled(taskID) { return .cancelled }

            var extractOK = (mainRes.exitCode == 0)

            // Fallback Engine 1: unar
            if !extractOK, let unarBin = ToolchainLocator.locateUnar() {
                onLog("unar ▸ 主引擎退出码 \(mainRes.exitCode)，自动切换 unar 引擎兜底解压...", true)
                var unarArgs = ["-f", "-q", "-o", outDir]
                if !finalPwd.isEmpty {
                    unarArgs.append(contentsOf: ["-p", finalPwd])
                }
                unarArgs.append(archivePath)
                if let unarRes = try? await supervisor.run(executable: unarBin, arguments: unarArgs, taskID: taskID) {
                    extractOK = (unarRes.exitCode == 0)
                }
            }

            // Fallback Engine 2: unrar if not already tried
            if !extractOK, isRarArchive, let unrar = unrarBin, mainExe != unrar {
                let pwdArg = finalPwd.isEmpty ? "-p-" : "-p\(finalPwd)"
                if let rarRes = try? await supervisor.run(
                    executable: unrar,
                    arguments: ["x", "-y", "-o+", pwdArg, archivePath, "\(outDir)/"],
                    taskID: taskID
                ) {
                    extractOK = (rarRes.exitCode == 0)
                }
            }

            if await supervisor.isCancelled(taskID) { return .cancelled }

            var totalExtractedBytes: Int64 = 0
            if let enumerator = FileManager.default.enumerator(atPath: outDir) {
                while let rel = enumerator.nextObject() as? String {
                    if (rel as NSString).lastPathComponent.hasPrefix(".") { continue }
                    let full = (outDir as NSString).appendingPathComponent(rel)
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
                       (attrs[.type] as? FileAttributeType) == .typeRegular,
                       let sz = attrs[.size] as? Int64 {
                        totalExtractedBytes += sz
                    }
                }
            }
            let hasExtractedFiles = totalExtractedBytes > 0

            guard extractOK && hasExtractedFiles else {
                if !hasExtractedFiles {
                    try? FileManager.default.removeItem(atPath: outDir)
                }
                onLog("error ▸ 解压未成功 (7zz/unrar/unar 退出异常或密码不匹配)，已中止流转！", true)
                return .failed(pill: "密码错误/失败")
            }

            await repairMacOSPermissions(outDir: outDir)
            onLog("perm ▸ 已修复读写权限 (chmod u+rwX) 并清除隔离锁 (xattr -cr)", false)

            if deleteArchiveAfterUnpack {
                cleanupSourceArchive(archivePath: archivePath, onLog: onLog)
            }

            return .completed(outDir: outDir, baseName: baseName, pill: "已解锁")
        } catch {
            if await supervisor.isCancelled(taskID) { return .cancelled }
            onLog("error ▸ 解压异常: \(error.localizedDescription)", false)
            return .failed(pill: "解压异常")
        }
    }

    private func repairMacOSPermissions(outDir: String) async {
        _ = try? await supervisor.run(executable: "/bin/chmod", arguments: ["-R", "u+rwX", outDir])
        _ = try? await supervisor.run(executable: "/usr/bin/xattr", arguments: ["-cr", outDir])
    }

    private func cleanupSourceArchive(archivePath: String, onLog: @Sendable (String, Bool) -> Void) {
        let fm = FileManager.default
        let parent = (archivePath as NSString).deletingLastPathComponent
        let fileName = (archivePath as NSString).lastPathComponent
        // Handle multipart volumes (.7z.001/.002, .part1.rar/.part2.rar, setup_*.bin) cleanly
        if fileName.lowercased().hasSuffix(".7z.001") {
            let prefix = String(fileName.dropLast(3)) // keep ".7z."
            if let items = try? fm.contentsOfDirectory(atPath: parent) {
                for item in items where item.hasPrefix(prefix) {
                    try? fm.removeItem(atPath: (parent as NSString).appendingPathComponent(item))
                }
            }
        } else if let rarMatch = try? NSRegularExpression(pattern: #"^(.+)\.part0*1\.rar$"#, options: .caseInsensitive)
            .firstMatch(in: fileName, range: NSRange(fileName.startIndex..., in: fileName)),
                  let prefixRange = Range(rarMatch.range(at: 1), in: fileName) {
            let basePrefix = String(fileName[prefixRange]) + ".part"
            if let items = try? fm.contentsOfDirectory(atPath: parent) {
                for item in items where item.lowercased().hasPrefix(basePrefix.lowercased()) && item.lowercased().hasSuffix(".rar") {
                    try? fm.removeItem(atPath: (parent as NSString).appendingPathComponent(item))
                }
            }
        } else {
            try? fm.removeItem(atPath: archivePath)
        }
        onLog("clean ▸ 已按设置自动清理源压缩包: \(fileName)", false)
    }
}
