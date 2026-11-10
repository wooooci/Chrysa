import SwiftUI
import AppKit

@MainActor
extension StudioViewModel {
    // MARK: - 2. UNPACK BACKEND (Silent Password Brute-Force + 7zz/unar/innoextract + chmod/xattr Fix)
    func startUnpack(filePath: String) {
        let normalizedPath = Self.normalizeMultipartArchivePath(filePath)
        let filename = (normalizedPath as NSString).lastPathComponent

        let fileSizeStr: String = {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: normalizedPath),
               let sz = attrs[.size] as? Int64 {
                return ByteCountFormatter.string(fromByteCount: sz, countStyle: .file)
            }
            return ""
        }()

        let taskID = UUID()
        let newTask = StudioTask(
            id: taskID,
            title: filename,
            status: .locked(0.08),
            pill: filename.lowercased().hasPrefix("setup_") ? "GOG 解包" : "试密中",
            rightText: fileSizeStr,
            localPath: normalizedPath
        )
        unpackTasks.insert(newTask, at: 0)
        appendLog("unpack ▸ 准备解压 \(filename)...", highlight: false)

        let candidatePasswords = [""] + passwords
        Task.detached { [weak self] in
            await self?.runSevenZipUnpack(taskID: taskID, archivePath: normalizedPath, candidatePasswords: candidatePasswords)
        }
    }

    nonisolated static func normalizeMultipartArchivePath(_ path: String) -> String {
        // 0. If the file on disk has a Base64-encoded FileDitch JDownloader filename (e.g. MTc5NDMx...), rename it to the decoded .rar/.7z filename!
        let lastComp = (path as NSString).lastPathComponent
        if let decodedName = decodeBase64FilenameIfPossible(lastComp) {
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

    nonisolated func runSevenZipUnpack(taskID: UUID, archivePath: String, candidatePasswords: [String]) async {
        let parentDir = (archivePath as NSString).deletingLastPathComponent
        var rawBase = ((archivePath as NSString).lastPathComponent as NSString).deletingPathExtension
        if rawBase.lowercased().hasPrefix("setup_") {
            rawBase = String(rawBase.dropFirst("setup_".count))
        }
        if rawBase.lowercased().hasSuffix(".7z") || rawBase.lowercased().hasSuffix(".tar") || rawBase.lowercased().hasSuffix(".part1") || rawBase.lowercased().hasSuffix(".part01") {
            rawBase = (rawBase as NSString).deletingPathExtension
        }
        let baseName = Self.cleanGameTitle(from: rawBase)
        let outDir = (parentDir as NSString).appendingPathComponent(baseName)

        // Special Path: GOG / Inno Setup Installer (.exe + .bin) via /opt/homebrew/bin/innoextract
        if Self.isInnoSetupInstaller(archivePath) {
            try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            await MainActor.run {
                self.appendLog("innoextract ▸ 检测到 GOG Inno Setup 安装包，开始原生免安装解包至 [\(baseName)]...", highlight: true)
            }

            // Collect main installer + any sibling DLC setup_*.exe installers that have finished downloading
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
                let instName = (instPath as NSString).lastPathComponent
                let totalCount = installersToExtract.count
                await MainActor.run {
                    if let i = self.unpackTasks.firstIndex(where: { $0.id == taskID }) {
                        self.unpackTasks[i].pill = totalCount > 1 ? "GOG \(idx + 1)/\(totalCount)" : "GOG 解包中"
                        self.unpackTasks[i].status = .locked(max(0.1, Double(idx) / Double(totalCount)))
                    }
                    if idx > 0 {
                        self.appendLog("innoextract ▸ 自动合并同目录 DLC 安装包: \(instName)", highlight: true)
                    }
                }
                let innoProc = Process()
                innoProc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/innoextract")
                innoProc.arguments = ["-e", "-m", "-g", "--collisions=overwrite", "-s", "-d", outDir, instPath]
                innoProc.standardOutput = FileHandle.nullDevice
                innoProc.standardError = FileHandle.nullDevice
                try? innoProc.run()
                await MainActor.run { self.activeProcesses[taskID] = innoProc }
                innoProc.waitUntilExit()
                _ = await MainActor.run { self.activeProcesses.removeValue(forKey: taskID) }
                if innoProc.terminationStatus != 0 {
                    allOK = false
                    break
                }
            }

            let extractedItems = (try? FileManager.default.contentsOfDirectory(atPath: outDir))?.filter { !$0.hasPrefix(".") } ?? []
            guard allOK && !extractedItems.isEmpty else {
                if extractedItems.isEmpty {
                    try? FileManager.default.removeItem(atPath: outDir)
                }
                await MainActor.run {
                    if self.cancelledTaskIDs.contains(taskID) { return }
                    if let i = self.unpackTasks.firstIndex(where: { $0.id == taskID }) {
                        self.unpackTasks[i].status = .failed
                        self.unpackTasks[i].pill = "缺少 .bin 分卷"
                    }
                    self.appendLog("error ▸ GOG 安装包解包未完成 (可能缺少配套的 -1.bin 数据卷)！", highlight: true)
                }
                return
            }

            let chmodProc = Process()
            chmodProc.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmodProc.arguments = ["-R", "u+rwX", outDir]
            try? chmodProc.run()
            chmodProc.waitUntilExit()

            let xattrProc = Process()
            xattrProc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattrProc.arguments = ["-cr", outDir]
            try? xattrProc.run()
            xattrProc.waitUntilExit()

            await MainActor.run {
                guard let idx = self.unpackTasks.firstIndex(where: { $0.id == taskID }) else { return }
                self.unpackTasks[idx].status = .done
                self.unpackTasks[idx].pill = "GOG 已解包"
                self.unpackTasks[idx].localPath = outDir
                self.appendLog("innoextract ▸ GOG 游戏与 DLC 解包完成并已修复权限: \(baseName)", highlight: true)
                if self.autoRelay {
                    self.appendLog("relay ▸ 自动流转至 [补丁]: \(baseName)", highlight: true)
                    self.activeTab = .patch
                    self.startPatch(folderPath: outDir)
                }
            }
            return
        }

        let sevenZip = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/7zz")
            ? "/opt/homebrew/bin/7zz"
            : "/usr/local/bin/7zz"

        guard FileManager.default.fileExists(atPath: sevenZip) else {
            await MainActor.run {
                self.appendLog("error ▸ 未找到 /opt/homebrew/bin/7zz", highlight: true)
            }
            return
        }

        let cxUnrarCandidates = [
            "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/unrar",
            "/opt/homebrew/bin/unrar",
            "/usr/local/bin/unrar"
        ]
        let unrarBin = cxUnrarCandidates.first(where: { FileManager.default.fileExists(atPath: $0) })
        let isRarArchive = archivePath.lowercased().hasSuffix(".rar")

        // 1. Instant 5ms Password Header / Smallest-File Test (uses `7zz l -slt` instead of full-archive `7zz t`)
        var foundPwd: String? = nil
        var foundIdx: Int = 0
        for (idx, pwd) in candidatePasswords.enumerated() {
            let listProc = Process()
            listProc.executableURL = URL(fileURLWithPath: sevenZip)
            listProc.arguments = ["l", "-slt", "-p\(pwd)", "-y", archivePath]
            let listPipe = Pipe()
            listProc.standardOutput = listPipe
            listProc.standardError = FileHandle.nullDevice
            try? listProc.run()
            let outData = listPipe.fileHandleForReading.readDataToEndOfFile()
            listProc.waitUntilExit()
            if listProc.terminationStatus == 0 {
                let outText = String(data: outData, encoding: .utf8) ?? ""
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
                            let tProc = Process()
                            if isRarArchive, let unrar = unrarBin {
                                tProc.executableURL = URL(fileURLWithPath: unrar)
                                tProc.arguments = ["t", "-y", "-p\(cPwd)", archivePath, sf]
                            } else {
                                tProc.executableURL = URL(fileURLWithPath: sevenZip)
                                tProc.arguments = ["t", "-p\(cPwd)", "-bso0", "-bse0", "-y", archivePath, sf]
                            }
                            tProc.standardOutput = FileHandle.nullDevice
                            tProc.standardError = FileHandle.nullDevice
                            try? tProc.run()
                            tProc.waitUntilExit()
                            if tProc.terminationStatus == 0 {
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

        let matchedPassword = foundPwd
        let matchedIndex = foundIdx
        let finalPwd = matchedPassword ?? ""

        await MainActor.run {
            let engineLabel = (isRarArchive && unrarBin != nil) ? "unrar" : "7zz"
            if matchedPassword != nil {
                if finalPwd.isEmpty {
                    self.appendLog("\(engineLabel) ▸ 检测到无加密压缩包，开始高速解压...", highlight: false)
                } else {
                    self.appendLog("\(engineLabel) ▸ 密码本第 #\(String(format: "%02d", matchedIndex)) 项毫秒级命中 (已隐藏明文)，开始解压...", highlight: true)
                }
            } else {
                self.appendLog("\(engineLabel) ▸ 默认密码本未命中，尝试使用空密码或切换备用引擎解压...", highlight: false)
            }
        }

        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let proc = Process()
        if isRarArchive, let unrar = unrarBin {
            proc.executableURL = URL(fileURLWithPath: unrar)
            let pwdArg = finalPwd.isEmpty ? "-p-" : "-p\(finalPwd)"
            proc.arguments = ["x", "-y", "-o+", pwdArg, archivePath, "\(outDir)/"]
        } else {
            proc.executableURL = URL(fileURLWithPath: sevenZip)
            proc.arguments = ["x", "-p\(finalPwd)", "-bsp1", "-y", "-o\(outDir)", archivePath]
        }

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let fh = pipe.fileHandleForReading
        fh.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            if let m = try? NSRegularExpression(pattern: #"([0-9]{1,3})%"#).firstMatch(
                in: chunk, range: NSRange(chunk.startIndex..., in: chunk)
            ), let r = Range(m.range(at: 1), in: chunk), let pct = Double(chunk[r]) {
                Task { @MainActor [weak self] in
                    guard let self = self, let i = self.unpackTasks.firstIndex(where: { $0.id == taskID }) else { return }
                    self.unpackTasks[i].status = .locked(max(0.05, min(0.99, pct / 100.0)))
                }
            }
        }

        do {
            try proc.run()
            await MainActor.run { self.activeProcesses[taskID] = proc }
            proc.waitUntilExit()
            fh.readabilityHandler = nil
            let wasCancelled = await MainActor.run { () -> Bool in
                self.activeProcesses.removeValue(forKey: taskID)
                return self.cancelledTaskIDs.contains(taskID)
            }
            if wasCancelled { return }

            var extractOK = (proc.terminationStatus == 0)

            // Fallback Engine 1: /opt/homebrew/bin/unar
            if !extractOK && FileManager.default.fileExists(atPath: "/opt/homebrew/bin/unar") {
                await MainActor.run {
                    self.appendLog("unar ▸ 主引擎退出码 \(proc.terminationStatus)，自动切换 unar 引擎兜底解压...", highlight: true)
                }
                let unarProc = Process()
                unarProc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/unar")
                var unarArgs = ["-f", "-q", "-o", outDir]
                if !finalPwd.isEmpty {
                    unarArgs.append(contentsOf: ["-p", finalPwd])
                }
                unarArgs.append(archivePath)
                unarProc.arguments = unarArgs
                unarProc.standardOutput = FileHandle.nullDevice
                unarProc.standardError = FileHandle.nullDevice
                try? unarProc.run()
                unarProc.waitUntilExit()
                extractOK = (unarProc.terminationStatus == 0)
            }

            // Fallback Engine 2: CrossOver's bundled unrar if not already tried
            if !extractOK, isRarArchive, let unrar = unrarBin {
                let rarProc = Process()
                rarProc.executableURL = URL(fileURLWithPath: unrar)
                let pwdArg = finalPwd.isEmpty ? "-p-" : "-p\(finalPwd)"
                rarProc.arguments = ["x", "-y", "-o+", pwdArg, archivePath, "\(outDir)/"]
                rarProc.standardOutput = FileHandle.nullDevice
                rarProc.standardError = FileHandle.nullDevice
                try? rarProc.run()
                rarProc.waitUntilExit()
                extractOK = (rarProc.terminationStatus == 0)
            }

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
                await MainActor.run {
                    if let idx = self.unpackTasks.firstIndex(where: { $0.id == taskID }) {
                        self.unpackTasks[idx].status = .failed
                        self.unpackTasks[idx].pill = "密码错误/失败"
                    }
                    self.appendLog("error ▸ 解压未成功 (7zz/unrar/unar 退出异常或密码不匹配)，已中止流转！", highlight: true)
                }
                return
            }

            // 3. Auto Fix macOS Permissions (chmod -R u+rwX & xattr -cr)
            let chmodProc = Process()
            chmodProc.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmodProc.arguments = ["-R", "u+rwX", outDir]
            try? chmodProc.run()
            chmodProc.waitUntilExit()

            let xattrProc = Process()
            xattrProc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattrProc.arguments = ["-cr", outDir]
            try? xattrProc.run()
            xattrProc.waitUntilExit()

            await MainActor.run {
                guard let idx = self.unpackTasks.firstIndex(where: { $0.id == taskID }) else { return }
                self.unpackTasks[idx].status = .done
                self.unpackTasks[idx].pill = "已解锁"
                self.unpackTasks[idx].localPath = outDir
                self.appendLog("perm ▸ 已修复读写权限 (chmod u+rwX) 并清除隔离锁 (xattr -cr)", highlight: false)

                if self.autoRelay {
                    self.appendLog("relay ▸ 自动流转至 [补丁]: \(baseName)", highlight: true)
                    self.activeTab = .patch
                    self.startPatch(folderPath: outDir)
                }
            }
        } catch {
            await MainActor.run {
                self.appendLog("error ▸ 解压异常: \(error.localizedDescription)", highlight: false)
            }
        }
    }

}
