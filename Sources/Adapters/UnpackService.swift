import ChrysaCore
import ChrysaApplication
import Foundation

package enum UnpackOutcome: Sendable {
    case completed(outDir: String, baseName: String, pill: String)
    case cancelled
    case failed(pill: String)
}

package actor UnpackService {
    private let supervisor: ProcessSupervisor
    private let postProcessors: [any UnpackPostProcessor]

    package init(
        supervisor: ProcessSupervisor = .shared,
        postProcessors: [any UnpackPostProcessor] = [MacOSPermissionFixer()]
    ) {
        self.supervisor = supervisor
        self.postProcessors = postProcessors
    }

    package static func isArchiveFile(_ path: String) -> Bool {
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

    package static func isInnoSetupInstaller(_ path: String) -> Bool {
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

    package static func normalizeMultipartArchivePath(_ path: String) -> String {
        let lastComp = (path as NSString).lastPathComponent
        if let decodedName = HostResolverRegistry.decodeBase64FilenameIfPossible(lastComp) {
            let parent = (path as NSString).deletingLastPathComponent
            if let safeName = PathSafety.safeFilename(decodedName) {
                let parentURL = URL(fileURLWithPath: parent, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
                let renamedURL = parentURL.appendingPathComponent(safeName).standardizedFileURL
                if PathSafety.containedURL(renamedURL, in: parentURL) != nil {
                    if FileManager.default.fileExists(atPath: path), !FileManager.default.fileExists(atPath: renamedURL.path) {
                        if (try? FileManager.default.moveItem(atPath: path, toPath: renamedURL.path)) != nil {
                            return renamedURL.path
                        }
                    } else if FileManager.default.fileExists(atPath: renamedURL.path) {
                        return renamedURL.path
                    }
                }
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

    package func mergeGOGDLCInstaller(dlcExePath: String, intoDir outDir: String, taskID: UUID? = nil) async -> Bool {
        guard let innoBin = ToolchainLocator.locateInnoextract(),
              let sourceParent = try? PathSafety.canonicalDirectory(URL(fileURLWithPath: dlcExePath).deletingLastPathComponent().path),
              let target = try? PathSafety.canonicalDirectory(outDir),
              target.path != "/",
              target.path != sourceParent.path,
              PathSafety.containedURL(target, in: sourceParent) != nil else { return false }
        let res = try? await supervisor.run(
            executable: innoBin,
            arguments: ["-e", "-m", "-g", "--collisions=overwrite", "-s", "-d", target.path, dlcExePath],
            taskID: taskID
        )
        return res?.exitCode == 0
    }

    package func executeUnpack(
        taskID: UUID,
        archivePath: String,
        candidatePasswords: [String],
        deleteArchiveAfterUnpack: Bool = false,
        knownGames: [LaunchGame] = [],
        isCancelled: @escaping @Sendable () async -> Bool = { Task.isCancelled },
        onProgress: @escaping @Sendable (Double, String?) async -> Void,
        onLog: @escaping @Sendable (String, Bool) async -> Void,
        onDiagnostic: @escaping @Sendable (StageLog) async -> Void = { _ in }
    ) async -> UnpackOutcome {
        if await supervisor.isCancelled(taskID, checking: isCancelled) { return .cancelled }
        let archiveURL = URL(fileURLWithPath: archivePath).standardizedFileURL
        let parentPath = archiveURL.deletingLastPathComponent().path
        let parentURL: URL
        let targetBaseName: String
        let stagingURL: URL
        do {
            parentURL = try PathSafety.canonicalDirectory(parentPath)
            let archiveValues = try archiveURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard parentURL.path != "/",
                  PathSafety.containedURL(archiveURL, in: parentURL) != nil,
                  archiveValues.isRegularFile == true,
                  archiveValues.isSymbolicLink != true else {
                await onLog("error ▸ 压缩包路径无效", true)
                return .failed(pill: "路径无效")
            }
            let lastComponent = archiveURL.lastPathComponent
            var proposedName = (lastComponent as NSString).deletingPathExtension
            if proposedName.lowercased().hasPrefix("setup_") {
                proposedName = String(proposedName.dropFirst("setup_".count))
            }
            if proposedName.lowercased().hasSuffix(".7z") || proposedName.lowercased().hasSuffix(".tar") || proposedName.lowercased().hasSuffix(".part1") || proposedName.lowercased().hasSuffix(".part01") {
                proposedName = (proposedName as NSString).deletingPathExtension
            }
            proposedName = GameTitle.cleanGameTitle(from: proposedName)
            targetBaseName = Self.resolvedTargetDirectoryName(for: proposedName)
            let stagingName = ".chrysa-unpack-\(UUID().uuidString)"
            stagingURL = parentURL.appendingPathComponent(stagingName, isDirectory: true).standardizedFileURL
            try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        } catch {
            await onLog("error ▸ 无法创建安全解压目录: \(error.localizedDescription)", true)
            return .failed(pill: "目录错误")
        }
        var activeStagingURL = stagingURL
        var secondaryStagingURL: URL? = nil
        var preserveActiveStaging = false
        defer {
            if !preserveActiveStaging || activeStagingURL != stagingURL {
                removeOutputDirectoryIfSafe(stagingURL, parent: parentURL)
            }
            if let secondaryStagingURL, (!preserveActiveStaging || activeStagingURL != secondaryStagingURL) {
                removeOutputDirectoryIfSafe(secondaryStagingURL, parent: parentURL)
            }
        }
        guard PathSafety.containedURL(stagingURL, in: parentURL)?.path == stagingURL.path,
              (try? stagingURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            await onLog("error ▸ 解压目录被替换或不再安全", true)
            return .failed(pill: "路径无效")
        }

        let pass1 = await extractSingleArchivePass(
            taskID: taskID,
            archivePath: archivePath,
            outDir: stagingURL.path,
            baseName: targetBaseName,
            candidatePasswords: candidatePasswords,
            isCancelled: isCancelled,
            onProgress: onProgress,
            onLog: onLog,
            onDiagnostic: onDiagnostic
        )
        switch pass1 {
        case .cancelled:
            return .cancelled
        case .failed(let pill):
            return .failed(pill: pill)
        case .succeeded:
            break
        }

        var usedGOGInstaller = (pass1 == .succeeded(usedGOGInstaller: true))
        var resolvedTargetName = targetBaseName

        // Nested archive auto secondary unpack (max 1 additional pass)
        if let nestedCandidate = Self.detectNestedArchivePayload(in: activeStagingURL) {
            if await supervisor.isCancelled(taskID, checking: isCancelled) { return .cancelled }
            let innerName = ".chrysa-unpack-nested-\(UUID().uuidString)"
            let innerURL = parentURL.appendingPathComponent(innerName, isDirectory: true).standardizedFileURL
            do {
                try FileManager.default.createDirectory(at: innerURL, withIntermediateDirectories: true)
            } catch {
                await onLog("error ▸ 无法创建二次拆包临时目录: \(error.localizedDescription)", true)
                return .failed(pill: "目录错误")
            }
            guard PathSafety.containedURL(innerURL, in: parentURL)?.path == innerURL.path else {
                removeOutputDirectoryIfSafe(innerURL, parent: parentURL)
                await onLog("error ▸ 二次拆包目录路径无效", true)
                return .failed(pill: "路径无效")
            }
            secondaryStagingURL = innerURL

            await onLog("nested ▸ 检测到套娃压缩包 [\(nestedCandidate.primaryArchiveURL.lastPathComponent)]，自动衔接二次拆包...", true)
            await onProgress(0.5, "二次拆包")

            let pass2 = await extractSingleArchivePass(
                taskID: taskID,
                archivePath: nestedCandidate.primaryArchiveURL.path,
                outDir: innerURL.path,
                baseName: targetBaseName,
                candidatePasswords: candidatePasswords,
                isCancelled: isCancelled,
                onProgress: onProgress,
                onLog: onLog,
                onDiagnostic: onDiagnostic
            )
            switch pass2 {
            case .cancelled:
                return .cancelled
            case .failed(let pill):
                return .failed(pill: pill)
            case .succeeded(let nestedUsedGOG):
                usedGOGInstaller = usedGOGInstaller || nestedUsedGOG
                Self.cleanupIntermediateArchives(nestedCandidate.volumeURLs, within: activeStagingURL)
                removeOutputDirectoryIfSafe(activeStagingURL, parent: parentURL)
                activeStagingURL = innerURL
                if resolvedTargetName == "Game", !nestedCandidate.proposedTitle.isEmpty {
                    let fallbackName = Self.resolvedTargetDirectoryName(for: nestedCandidate.proposedTitle)
                    if fallbackName != "Game" {
                        resolvedTargetName = fallbackName
                    }
                }
                await onLog("nested ▸ 二次拆包完成并已移除中间层压缩包: \(nestedCandidate.primaryArchiveURL.lastPathComponent)", false)
            }
        }

        let finalOutDir = activeStagingURL.path
        for processor in postProcessors {
            try? await processor.process(outDir: finalOutDir, parentURL: parentURL)
        }
        if !usedGOGInstaller {
            await onLog("perm ▸ 已修复读写权限 (chmod u+rwX) 并清除隔离锁 (xattr -cr)", false)
        }
        if await supervisor.isCancelled(taskID, checking: isCancelled) { return .cancelled }

        guard let finalized = try? await Self.finalizeStagedDirectory(
            stagingURL: activeStagingURL,
            parentURL: parentURL,
            targetName: resolvedTargetName,
            knownGames: knownGames,
            onLog: onLog
        ) else {
            await onLog("error ▸ 就位新游戏目录失败，已保留原版并清理临时目录", true)
            return .failed(pill: "目录替换失败")
        }
        preserveActiveStaging = true

        if deleteArchiveAfterUnpack {
            await cleanupSourceArchive(archivePath: archivePath, onLog: onLog)
        }

        if usedGOGInstaller {
            await onLog("innoextract ▸ GOG 游戏与 DLC 解包完成并已修复权限: \(finalized.finalName)", true)
            return .completed(
                outDir: finalized.finalURL.path,
                baseName: finalized.finalName,
                pill: finalized.replacedOld ? "已覆盖更新" : "GOG 已解包"
            )
        }
        return .completed(
            outDir: finalized.finalURL.path,
            baseName: finalized.finalName,
            pill: finalized.replacedOld ? "已覆盖更新" : "已解锁"
        )
    }

    private enum SinglePassExtractResult: Equatable {
        case succeeded(usedGOGInstaller: Bool)
        case cancelled
        case failed(pill: String)
    }

    private func extractSingleArchivePass(
        taskID: UUID,
        archivePath: String,
        outDir: String,
        baseName: String,
        candidatePasswords: [String],
        isCancelled: @escaping @Sendable () async -> Bool,
        onProgress: @escaping @Sendable (Double, String?) async -> Void,
        onLog: @escaping @Sendable (String, Bool) async -> Void,
        onDiagnostic: @escaping @Sendable (StageLog) async -> Void
    ) async -> SinglePassExtractResult {
        let archiveURL = URL(fileURLWithPath: archivePath).standardizedFileURL
        let parentDir = archiveURL.deletingLastPathComponent().path

        // Branch 1: GOG / Inno Setup Installer (.exe + .bin)
        if Self.isInnoSetupInstaller(archivePath), let innoBin = ToolchainLocator.locateInnoextract() {
            await onLog("innoextract ▸ 检测到 GOG Inno Setup 安装包，开始原生免安装解包至 [\(baseName)]...", true)

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
            var lastInnoDiag = ""
            for (idx, instPath) in installersToExtract.enumerated() {
                if await supervisor.isCancelled(taskID, checking: isCancelled) { return .cancelled }
                let instName = (instPath as NSString).lastPathComponent
                let totalCount = installersToExtract.count
                let pillText = totalCount > 1 ? "GOG \(idx + 1)/\(totalCount)" : "GOG 解包中"
                await onProgress(max(0.1, Double(idx) / Double(totalCount)), pillText)
                if idx > 0 {
                    await onLog("innoextract ▸ 自动合并同目录 DLC 安装包: \(instName)", true)
                }

                let res = try? await supervisor.run(
                    executable: innoBin,
                    arguments: ["-e", "-m", "-g", "--collisions=overwrite", "-s", "-d", outDir, instPath],
                    taskID: taskID
                )
                if res?.exitCode != 0 {
                    allOK = false
                    lastInnoDiag = res?.diagnosticOutput ?? ""
                    break
                }
            }

            if await supervisor.isCancelled(taskID, checking: isCancelled) { return .cancelled }

            let extractedItems = (try? FileManager.default.contentsOfDirectory(atPath: outDir))?.filter { !$0.hasPrefix(".") } ?? []
            guard allOK && !extractedItems.isEmpty else {
                await onDiagnostic(StageLog(
                    "error ▸ GOG 安装包解包未完成 (可能缺少配套的 -1.bin 数据卷)",
                    level: .error,
                    rawOutput: LogEntry.sanitizeRawOutput(lastInnoDiag)
                ))
                return .failed(pill: "缺少 .bin 分卷")
            }
            return .succeeded(usedGOGInstaller: true)
        }

        // Branch 2: Standard 7zz / unrar / unar pipeline
        guard let sevenZip = ToolchainLocator.locateSevenZip() else {
            await onLog("error ▸ 未找到 7zz 解压内核 (应用内置或 Homebrew 7zz)", true)
            return .failed(pill: "缺少 7zz")
        }

        let unrarBin = ToolchainLocator.locateUnrar()
        let isRarArchive = archivePath.lowercased().hasSuffix(".rar")

        let probeResult = await probeArchivePassword(
            archivePath: archivePath,
            candidatePasswords: candidatePasswords,
            sevenZip: sevenZip,
            unrarBin: unrarBin,
            isRarArchive: isRarArchive,
            taskID: taskID,
            isCancelled: isCancelled
        )
        if probeResult.cancelled { return .cancelled }

        let foundPwd = probeResult.foundPassword
        let foundIdx = probeResult.foundIndex
        let finalPwd = foundPwd ?? ""
        let engineLabel = (isRarArchive && unrarBin != nil) ? "unrar" : "7zz"
        if foundPwd != nil {
            if finalPwd.isEmpty {
                await onLog("\(engineLabel) ▸ 检测到无加密压缩包，开始高速解压...", false)
            } else {
                await onLog("\(engineLabel) ▸ 密码本第 #\(String(format: "%02d", foundIdx)) 项毫秒级命中 (已隐藏明文)，开始解压...", true)
            }
        } else {
            await onLog("\(engineLabel) ▸ 默认密码本未命中，尝试使用空密码或切换备用引擎解压...", false)
        }

        let progressEvents = StageEventQueue<(Double, String?)> { event in
            await onProgress(event.0, event.1)
        }
        do {
            let result = try await runArchiveExtractionWithFallbacks(
                archivePath: archivePath,
                outDir: outDir,
                password: finalPwd,
                sevenZip: sevenZip,
                unrarBin: unrarBin,
                isRarArchive: isRarArchive,
                isZipArchive: archivePath.lowercased().hasSuffix(".zip"),
                allowDittoFallback: false,
                taskID: taskID,
                isCancelled: isCancelled,
                onLog: onLog,
                onChunk: { chunk in
                    if let m = try? NSRegularExpression(pattern: #"([0-9]{1,3})%"#).firstMatch(
                        in: chunk, range: NSRange(chunk.startIndex..., in: chunk)
                    ), let r = Range(m.range(at: 1), in: chunk), let pct = Double(chunk[r]) {
                        progressEvents.submit((max(0.05, min(0.99, pct / 100.0)), nil))
                    }
                }
            )
            await progressEvents.drain()

            let cancelledAfterExtract = await supervisor.isCancelled(taskID, checking: isCancelled)
            if result.cancelled || cancelledAfterExtract {
                return .cancelled
            }

            var totalExtractedBytes: Int64 = 0
            try? PathSafety.walkDirectory(
                at: URL(fileURLWithPath: outDir, isDirectory: true),
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                includeSymlinks: false
            ) { _, rel, vals in
                if (rel as NSString).lastPathComponent.hasPrefix(".") { return }
                if vals.isRegularFile == true, let sz = vals.fileSize {
                    totalExtractedBytes += Int64(sz)
                }
            }
            let hasExtractedFiles = totalExtractedBytes > 0

            guard result.ok && hasExtractedFiles else {
                let rawDiag = LogEntry.sanitizeRawOutput(
                    result.diagnostics.joined(separator: "\n\n"),
                    redact: candidatePasswords
                )
                await onDiagnostic(StageLog(
                    "error ▸ 解压未成功 (7zz/unrar/unar 退出异常或密码不匹配)，已中止流转",
                    level: .error,
                    rawOutput: rawDiag
                ))
                return .failed(pill: "密码错误/失败")
            }

            return .succeeded(usedGOGInstaller: false)
        } catch {
            await progressEvents.drain()
            if await supervisor.isCancelled(taskID, checking: isCancelled) { return .cancelled }
            await onLog("error ▸ 解压异常: \(error.localizedDescription)", false)
            return .failed(pill: "解压异常")
        }
    }

    package struct NestedArchivePayload: Sendable {
        package let primaryArchiveURL: URL
        package let volumeURLs: [URL]
        package let proposedTitle: String
    }

    private enum NestedArchiveGroupKind {
        case single
        case sevenZipMultipart
        case rarMultipart
    }

    private static let nestedIgnorableSidecarExtensions: Set<String> = [
        "txt", "nfo", "url", "md", "sfv", "md5", "sha256", "log"
    ]

    private static let nestedSevenZipVolumeRegex = try? NSRegularExpression(
        pattern: #"^(.+\.7z)\.([0-9]{3})$"#,
        options: .caseInsensitive
    )

    private static let nestedRarPartRegex = try? NSRegularExpression(
        pattern: #"^(.+)\.part([0-9]+)\.rar$"#,
        options: .caseInsensitive
    )

    package static func detectNestedArchivePayload(in directoryURL: URL) -> NestedArchivePayload? {
        guard let canonicalDir = try? PathSafety.existingCanonicalDirectory(directoryURL.path) else {
            return nil
        }

        struct StandardGroup {
            let kind: NestedArchiveGroupKind
            var indexedVolumes: [(index: Int, url: URL)]
        }

        var hasGameExecutableOrApp = false
        var hasOtherPayloadFiles = false
        var standardGroups: [String: StandardGroup] = [:]
        var gogSetupExesByDir: [String: [URL]] = [:]
        var gogBinsByDir: [String: [URL]] = [:]

        try? PathSafety.walkDirectory(
            at: canonicalDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [],
            includeSymlinks: false
        ) { itemURL, relativePath, vals in
            let cleanRel = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !cleanRel.isEmpty else { return }
            let components = cleanRel.split(separator: "/").map(String.init)
            if components.contains(where: { $0.hasPrefix(".") || $0.lowercased() == "__macosx" }) {
                return
            }
            if components.dropLast().contains(where: { $0.lowercased().hasSuffix(".app") }) {
                return
            }

            let fileName = components.last ?? itemURL.lastPathComponent
            let lowerName = fileName.lowercased()

            if vals.isDirectory == true {
                if lowerName.hasSuffix(".app") {
                    hasGameExecutableOrApp = true
                }
                return
            }

            guard vals.isRegularFile == true else { return }
            if lowerName == "thumbs.db" || lowerName == "desktop.ini" {
                return
            }

            let dirKey = itemURL.deletingLastPathComponent().standardizedFileURL.path

            if lowerName.hasSuffix(".exe") {
                if lowerName.hasPrefix("setup_") && isInnoSetupInstaller(itemURL.path) {
                    gogSetupExesByDir[dirKey, default: []].append(itemURL)
                } else {
                    hasGameExecutableOrApp = true
                }
                return
            }

            let fullRange = NSRange(fileName.startIndex..., in: fileName)
            if let regex7z = nestedSevenZipVolumeRegex,
               let match = regex7z.firstMatch(in: fileName, range: fullRange),
               let prefixRange = Range(match.range(at: 1), in: fileName),
               let idxRange = Range(match.range(at: 2), in: fileName),
               let volIdx = Int(fileName[idxRange]) {
                let prefix = String(fileName[prefixRange])
                let groupKey = "\(dirKey)|7z|\(prefix.lowercased())"
                var group = standardGroups[groupKey] ?? StandardGroup(kind: .sevenZipMultipart, indexedVolumes: [])
                group.indexedVolumes.append((volIdx, itemURL))
                standardGroups[groupKey] = group
                return
            }

            if let regexRar = nestedRarPartRegex,
               let match = regexRar.firstMatch(in: fileName, range: fullRange),
               let prefixRange = Range(match.range(at: 1), in: fileName),
               let idxRange = Range(match.range(at: 2), in: fileName),
               let volIdx = Int(fileName[idxRange]) {
                let prefix = String(fileName[prefixRange])
                let groupKey = "\(dirKey)|rarpart|\(prefix.lowercased())"
                var group = standardGroups[groupKey] ?? StandardGroup(kind: .rarMultipart, indexedVolumes: [])
                group.indexedVolumes.append((volIdx, itemURL))
                standardGroups[groupKey] = group
                return
            }

            let ext = (lowerName as NSString).pathExtension
            if ext == "7z" || ext == "rar" || ext == "zip" {
                let groupKey = "\(dirKey)|single|\(lowerName)"
                standardGroups[groupKey] = StandardGroup(kind: .single, indexedVolumes: [(1, itemURL)])
                return
            }

            if lowerName.hasPrefix("setup_") && ext == "bin" {
                gogBinsByDir[dirKey, default: []].append(itemURL)
                return
            }

            if nestedIgnorableSidecarExtensions.contains(ext) {
                return
            }

            hasOtherPayloadFiles = true
        }

        guard !hasGameExecutableOrApp, !hasOtherPayloadFiles else {
            return nil
        }

        // Verify all GOG .bin slices belong to an identified GOG setup dir
        for (dirKey, _) in gogBinsByDir {
            if gogSetupExesByDir[dirKey]?.isEmpty ?? true {
                return nil
            }
        }

        let totalGroupCount = standardGroups.count + gogSetupExesByDir.count
        guard totalGroupCount == 1 else {
            return nil
        }

        if let (_, group) = standardGroups.first {
            let sorted = group.indexedVolumes.sorted { $0.index < $1.index }
            guard !sorted.isEmpty else { return nil }
            switch group.kind {
            case .single:
                guard sorted.count == 1 else { return nil }
            case .sevenZipMultipart, .rarMultipart:
                let indices = sorted.map(\.index)
                guard indices == Array(1...sorted.count) else {
                    return nil
                }
            }
            let primaryURL = sorted[0].url
            var stem = (primaryURL.lastPathComponent as NSString).deletingPathExtension
            let lowerStem = stem.lowercased()
            if lowerStem.hasSuffix(".7z") || lowerStem.hasSuffix(".part1") || lowerStem.hasSuffix(".part01") || lowerStem.hasSuffix(".part001") {
                stem = (stem as NSString).deletingPathExtension
            }
            let cleanStem = GameTitle.cleanGameTitle(from: stem)
            return NestedArchivePayload(
                primaryArchiveURL: primaryURL,
                volumeURLs: sorted.map(\.url),
                proposedTitle: cleanStem
            )
        }

        if let (dirKey, exes) = gogSetupExesByDir.first {
            let sortedExes = exes.sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
            guard let primaryURL = sortedExes.first(where: { !$0.lastPathComponent.lowercased().contains("dlc") }) ?? sortedExes.first else {
                return nil
            }
            var volumes = sortedExes
            volumes.append(contentsOf: gogBinsByDir[dirKey] ?? [])
            var stem = (primaryURL.lastPathComponent as NSString).deletingPathExtension
            if stem.lowercased().hasPrefix("setup_") {
                stem = String(stem.dropFirst("setup_".count))
            }
            let cleanStem = GameTitle.cleanGameTitle(from: stem)
            return NestedArchivePayload(
                primaryArchiveURL: primaryURL,
                volumeURLs: volumes,
                proposedTitle: cleanStem
            )
        }

        return nil
    }

    private static func cleanupIntermediateArchives(_ volumeURLs: [URL], within stagingURL: URL) {
        let fm = FileManager.default
        guard let canonicalStaging = try? PathSafety.existingCanonicalDirectory(stagingURL.path) else {
            return
        }
        for volumeURL in volumeURLs {
            let standardized = volumeURL.standardizedFileURL
            guard let safeURL = PathSafety.containedURL(standardized, in: canonicalStaging),
                  safeURL.path != canonicalStaging.path,
                  let attrs = try? fm.attributesOfItem(atPath: safeURL.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular else {
                continue
            }
            try? fm.removeItem(at: safeURL)
        }
    }

    private func removeOutputDirectoryIfSafe(_ output: URL, parent: URL) {
        guard let target = PathSafety.containedURL(output, in: parent),
              target.path == output.standardizedFileURL.path,
              target.path != parent.resolvingSymlinksInPath().standardizedFileURL.path,
              target.path != "/" else { return }
        try? FileManager.default.removeItem(at: target)
    }

    private func cleanupSourceArchive(archivePath: String, onLog: @escaping @Sendable (String, Bool) async -> Void) async {
        let fm = FileManager.default
        let archiveURL = URL(fileURLWithPath: archivePath).standardizedFileURL
        let parentPath = archiveURL.deletingLastPathComponent().path
        guard let parent = try? PathSafety.canonicalDirectory(parentPath),
              let source = PathSafety.containedURL(archiveURL, in: parent),
              source.path != parent.path,
              let attrs = try? fm.attributesOfItem(atPath: source.path),
              (attrs[.type] as? FileAttributeType) == .typeRegular else { return }
        let fileName = source.lastPathComponent
        var removedAny = false
        func removeRegularChild(_ name: String) {
            guard let safeName = PathSafety.safeFilename(name) else { return }
            let candidate = parent.appendingPathComponent(safeName).standardizedFileURL
            guard let target = PathSafety.containedURL(candidate, in: parent),
                  target.path != parent.path,
                  let itemAttrs = try? fm.attributesOfItem(atPath: target.path),
                  (itemAttrs[.type] as? FileAttributeType) == .typeRegular else { return }
            if (try? fm.removeItem(at: target)) != nil { removedAny = true }
        }

        if fileName.lowercased().hasSuffix(".7z.001") {
            let prefix = String(fileName.dropLast(3))
            if let items = try? fm.contentsOfDirectory(atPath: parent.path) {
                for item in items where item.hasPrefix(prefix) { removeRegularChild(item) }
            }
        } else if let rarMatch = try? NSRegularExpression(pattern: #"^(.+)\.part0*1\.rar$"#, options: .caseInsensitive)
            .firstMatch(in: fileName, range: NSRange(fileName.startIndex..., in: fileName)),
                  let prefixRange = Range(rarMatch.range(at: 1), in: fileName) {
            let basePrefix = String(fileName[prefixRange]) + ".part"
            if let items = try? fm.contentsOfDirectory(atPath: parent.path) {
                for item in items where item.lowercased().hasPrefix(basePrefix.lowercased()) && item.lowercased().hasSuffix(".rar") {
                    removeRegularChild(item)
                }
            }
        } else {
            removeRegularChild(fileName)
        }
        if removedAny { await onLog("clean ▸ 已按设置自动清理源压缩包: \(fileName)", false) }
    }

    private func probeArchivePassword(
        archivePath: String,
        candidatePasswords: [String],
        sevenZip: String,
        unrarBin: String?,
        isRarArchive: Bool,
        taskID: UUID,
        isCancelled: @escaping @Sendable () async -> Bool
    ) async -> (foundPassword: String?, foundIndex: Int, cancelled: Bool) {
        let probePasswords = candidatePasswords.first == "" ? candidatePasswords : ([""] + candidatePasswords)
        for (idx, pwd) in probePasswords.enumerated() {
            if await supervisor.isCancelled(taskID, checking: isCancelled) {
                return (nil, 0, true)
            }
            guard let listRes = try? await supervisor.run(
                executable: sevenZip,
                arguments: ["l", "-slt", "-p\(pwd)", "-y", archivePath],
                taskID: taskID,
                captureOutput: true
            ) else { continue }

            if listRes.exitCode == 0 {
                let outText = listRes.outputString
                if !pwd.isEmpty || !outText.contains("Encrypted = +") {
                    return (pwd, idx, false)
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
                        for (pIdx, cPwd) in probePasswords.enumerated() where !cPwd.isEmpty {
                            if await supervisor.isCancelled(taskID, checking: isCancelled) {
                                return (nil, 0, true)
                            }
                            let exe = (isRarArchive && unrarBin != nil) ? unrarBin! : sevenZip
                            let args = (isRarArchive && unrarBin != nil)
                                ? ["t", "-y", "-p\(cPwd)", archivePath, sf]
                                : ["t", "-p\(cPwd)", "-bso0", "-bse0", "-y", archivePath, sf]
                            if let tRes = try? await supervisor.run(executable: exe, arguments: args, taskID: taskID),
                               tRes.exitCode == 0 {
                                return (cPwd, pIdx, false)
                            }
                        }
                    }
                    return (nil, 0, false)
                }
            }
        }
        return (nil, 0, false)
    }

    /// Extracts an external patch/mod archive into an isolated sandbox directory (with password probing and tool fallbacks).
    package func extractArchiveToSandbox(
        archivePath: String,
        sandboxURL: URL,
        candidatePasswords: [String],
        taskID: UUID = UUID(),
        isCancelled: @escaping @Sendable () async -> Bool = { Task.isCancelled }
    ) async -> Bool {
        let lower = archivePath.lowercased()
        let isRar = lower.hasSuffix(".rar")
        let isZip = lower.hasSuffix(".zip")
        let sevenZip = ToolchainLocator.locateSevenZip()
        let unrarBin = ToolchainLocator.locateUnrar()

        var pwd = ""
        if let sevenZip {
            let probe = await probeArchivePassword(
                archivePath: archivePath,
                candidatePasswords: candidatePasswords,
                sevenZip: sevenZip,
                unrarBin: unrarBin,
                isRarArchive: isRar,
                taskID: taskID,
                isCancelled: isCancelled
            )
            if probe.cancelled { return false }
            pwd = probe.foundPassword ?? ""
        }

        let res = (try? await runArchiveExtractionWithFallbacks(
            archivePath: archivePath,
            outDir: sandboxURL.path,
            password: pwd,
            sevenZip: sevenZip,
            unrarBin: unrarBin,
            isRarArchive: isRar,
            isZipArchive: isZip,
            allowDittoFallback: true,
            taskID: taskID,
            isCancelled: isCancelled,
            onLog: { _, _ in },
            onChunk: nil
        )) ?? (ok: false, cancelled: false, diagnostics: [])
        return res.ok && !res.cancelled
    }

    private func runArchiveExtractionWithFallbacks(
        archivePath: String,
        outDir: String,
        password: String,
        sevenZip: String?,
        unrarBin: String?,
        isRarArchive: Bool,
        isZipArchive: Bool,
        allowDittoFallback: Bool,
        taskID: UUID,
        isCancelled: @escaping @Sendable () async -> Bool,
        onLog: @escaping @Sendable (String, Bool) async -> Void,
        onChunk: (@Sendable (String) -> Void)?
    ) async throws -> (ok: Bool, cancelled: Bool, diagnostics: [String]) {
        var extractOK = false
        var diagnostics: [String] = []
        var usedUnrar = false

        if isRarArchive, let unrar = unrarBin {
            usedUnrar = true
            let pwdArg = password.isEmpty ? "-p-" : "-p\(password)"
            let res = try await supervisor.run(
                executable: unrar,
                arguments: ["x", "-y", "-o+", pwdArg, archivePath, "\(outDir)/"],
                taskID: taskID,
                captureOutput: onChunk == nil,
                mergeStderr: true,
                onStreamChunk: onChunk
            )
            extractOK = (res.exitCode == 0)
            if !extractOK, !res.diagnosticOutput.isEmpty {
                diagnostics.append("[unrar exit=\(res.exitCode)]\n\(res.diagnosticOutput)")
            }
        } else if let sevenZip {
            let res = try await supervisor.run(
                executable: sevenZip,
                arguments: ["x", "-p\(password)", "-bsp1", "-y", "-o\(outDir)", archivePath],
                taskID: taskID,
                captureOutput: onChunk == nil,
                mergeStderr: true,
                onStreamChunk: onChunk
            )
            extractOK = (res.exitCode == 0)
            if !extractOK, !res.diagnosticOutput.isEmpty {
                diagnostics.append("[7zz exit=\(res.exitCode)]\n\(res.diagnosticOutput)")
            }
        }

        if await supervisor.isCancelled(taskID, checking: isCancelled) {
            return (false, true, diagnostics)
        }

        if !extractOK, let unarBin = ToolchainLocator.locateUnar() {
            if !diagnostics.isEmpty {
                await onLog("unar ▸ 主引擎解压失败，自动切换 unar 引擎兜底解压...", true)
            }
            var unarArgs = ["-f", "-q", "-o", outDir]
            if !password.isEmpty {
                unarArgs.append(contentsOf: ["-p", password])
            }
            unarArgs.append(archivePath)
            if let unarRes = try? await supervisor.run(executable: unarBin, arguments: unarArgs, taskID: taskID) {
                extractOK = (unarRes.exitCode == 0)
                if !extractOK, !unarRes.diagnosticOutput.isEmpty {
                    diagnostics.append("[unar exit=\(unarRes.exitCode)]\n\(unarRes.diagnosticOutput)")
                }
            }
        }

        if !extractOK, isRarArchive, !usedUnrar, let unrar = unrarBin {
            let pwdArg = password.isEmpty ? "-p-" : "-p\(password)"
            if let rarRes = try? await supervisor.run(
                executable: unrar,
                arguments: ["x", "-y", "-o+", pwdArg, archivePath, "\(outDir)/"],
                taskID: taskID
            ) {
                extractOK = (rarRes.exitCode == 0)
                if !extractOK, !rarRes.diagnosticOutput.isEmpty {
                    diagnostics.append("[unrar exit=\(rarRes.exitCode)]\n\(rarRes.diagnosticOutput)")
                }
            }
        }

        if !extractOK, allowDittoFallback, isZipArchive {
            if let dittoRes = try? await supervisor.run(
                executable: "/usr/bin/ditto",
                arguments: ["-x", "-k", archivePath, outDir],
                taskID: taskID
            ) {
                extractOK = (dittoRes.exitCode == 0)
            }
        }

        let cancelled = await supervisor.isCancelled(taskID, checking: isCancelled)
        return (extractOK, cancelled, diagnostics)
    }

    private static let portableSaveFolderNames: Set<String> = [
        "saves", "save", "savedata", "savegames", "saved", "userdata", "profile", "profiles", "save_data", "save_files"
    ]

    package static func resolvedTargetDirectoryName(for proposedName: String) -> String {
        let base = proposedName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if let safe = PathSafety.safeFilename(base), !safe.isEmpty {
            return safe
        }
        return "Game"
    }

    package static func finalizeStagedDirectory(
        stagingURL: URL,
        parentURL: URL,
        targetName: String,
        knownGames: [LaunchGame],
        onLog: @escaping @Sendable (String, Bool) async -> Void
    ) async throws -> (finalURL: URL, finalName: String, replacedOld: Bool) {
        let fm = FileManager.default
        let canonicalParent = try PathSafety.canonicalDirectory(parentURL.path)
        let safeTargetName = resolvedTargetDirectoryName(for: targetName)

        // Inspect staging once to capture AppID/Title and verify whether it is a runnable game build.
        let stagingInspection = GameDirectoryInspector.inspect(directory: stagingURL.path)
        let stagingHasExecutable = (stagingInspection?.mainExecutable != nil)
        let stagingAppID: String? = {
            guard let raw = stagingInspection?.existingAppID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty, raw != "480" else {
                return nil
            }
            return raw
        }()
        let targetNormalizedTitle = LaunchGame.normalizedIdentityTitle(safeTargetName)
        let inspectedNormalizedTitle = LaunchGame.normalizedIdentityTitle(stagingInspection?.resolvedTitle ?? safeTargetName)

        var oldDirectoriesByCanonicalPath: [String: URL] = [:]
        var orderedOldDirectories: [URL] = []

        func registerOldDirectory(_ candidateURL: URL) {
            let standardized = candidateURL.standardizedFileURL
            guard let vals = try? standardized.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  vals.isDirectory == true,
                  vals.isSymbolicLink != true,
                  isSafeOldGameDirectoryToReplace(standardized, parentURL: canonicalParent, stagingURL: stagingURL) else {
                return
            }
            let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL.path
            if oldDirectoriesByCanonicalPath[canonical] == nil {
                oldDirectoriesByCanonicalPath[canonical] = standardized
                orderedOldDirectories.append(standardized)
            }
        }

        // Only full game builds (containing an executable) may supersede/trash existing game directories.
        if stagingHasExecutable {
            // 1. Same-name sibling already under canonicalParent (case-insensitive check for APFS/Unix parity).
            if let siblings = try? fm.contentsOfDirectory(atPath: canonicalParent.path) {
                let targetLower = safeTargetName.lowercased()
                for entry in siblings where entry.lowercased() == targetLower {
                    let candidate = canonicalParent.appendingPathComponent(entry, isDirectory: true)
                    if candidate.standardizedFileURL.path != stagingURL.standardizedFileURL.path {
                        registerOldDirectory(candidate)
                    }
                }
            }

            // 2. Existing Launch Library records within the same parent directory matching normalized title or non-480 AppID.
            for game in knownGames {
                let gameNormTitle = LaunchGame.normalizedIdentityTitle(game.title)
                let matchesTitle = (!targetNormalizedTitle.isEmpty && !gameNormTitle.isEmpty && gameNormTitle == targetNormalizedTitle)
                    || (!inspectedNormalizedTitle.isEmpty && !gameNormTitle.isEmpty && gameNormTitle == inspectedNormalizedTitle)
                let matchesAppID: Bool = {
                    guard let a1 = stagingAppID,
                          let a2 = game.appID?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !a2.isEmpty, a2 != "480" else {
                        return false
                    }
                    return a1 == a2
                }()
                guard matchesTitle || matchesAppID,
                      let oldDirPath = game.gameDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !oldDirPath.isEmpty else {
                    continue
                }
                registerOldDirectory(URL(fileURLWithPath: oldDirPath, isDirectory: true))
            }
        }

        // Migrate portable saves from all detected old dirs before trashing them.
        var totalMigratedFiles = 0
        for oldDir in orderedOldDirectories {
            totalMigratedFiles += migratePortableSaves(from: oldDir, into: stagingURL)
        }
        if totalMigratedFiles > 0 {
            await onLog("save ▸ 已从旧版本补充迁移 \(totalMigratedFiles) 个本地便携存档文件", true)
        }

        // Safely move old dirs to Trash (falling back to removeItem when Trash is unsupported on the volume).
        var replacedOld = false
        for oldDir in orderedOldDirectories {
            var trashed = false
            do {
                try fm.trashItem(at: oldDir, resultingItemURL: nil)
                trashed = true
            } catch {
                try? fm.removeItem(at: oldDir)
                trashed = !fm.fileExists(atPath: oldDir.path)
            }
            if trashed {
                replacedOld = true
                await onLog("overwrite ▸ 已安全替换旧版游戏目录: \(oldDir.lastPathComponent)", true)
            } else {
                await onLog("warn ▸ 未能移走旧目录 [\(oldDir.lastPathComponent)]，将尝试保留新版目录", false)
            }
        }

        let desiredURL = canonicalParent.appendingPathComponent(safeTargetName, isDirectory: true).standardizedFileURL
        guard let containedDesired = PathSafety.containedURL(desiredURL, in: canonicalParent),
              containedDesired.path != canonicalParent.path else {
            throw NSError(domain: "Chrysa.Unpack", code: 2, userInfo: [NSLocalizedDescriptionKey: "目标目录路径无效"])
        }

        if !fm.fileExists(atPath: containedDesired.path) {
            try fm.moveItem(at: stagingURL, to: containedDesired)
            return (containedDesired, safeTargetName, replacedOld)
        }

        if !stagingHasExecutable {
            await onLog("warn ▸ 检测到新解压目录缺少可执行文件（疑似独立补丁包），保留已有同名目录不予覆盖", true)
        }

        // Only if the target path could not be cleared or this is a non-runnable patch pack, fall back to a unique name.
        let fallback = try PathSafety.uniqueChildDirectory(parent: canonicalParent, proposedName: safeTargetName)
        try? fm.removeItem(at: fallback.url)
        try fm.moveItem(at: stagingURL, to: fallback.url)
        return (fallback.url, fallback.name, replacedOld)
    }

    package static func migratePortableSaves(from oldDir: URL, into stagingDir: URL) -> Int {
        let fm = FileManager.default
        guard let canonicalOld = try? PathSafety.existingCanonicalDirectory(oldDir.path),
              let canonicalStaging = try? PathSafety.existingCanonicalDirectory(stagingDir.path) else {
            return 0
        }

        var migratedCount = 0
        try? PathSafety.walkDirectory(
            at: canonicalOld,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants],
            includeSymlinks: false
        ) { item, relativePath, vals in
            guard vals.isRegularFile == true else { return }
            let components = relativePath.split(separator: "/").map(String.init)
            guard !components.isEmpty else { return }
            let dirComponentsLower = components.dropLast().map { $0.lowercased() }

            let isPortableSaveDir = dirComponentsLower.contains { portableSaveFolderNames.contains($0) }
            let isSteamSettingsUserData: Bool = {
                for idx in 0..<dirComponentsLower.count {
                    if idx + 1 < dirComponentsLower.count,
                       dirComponentsLower[idx] == "steam_settings",
                       dirComponentsLower[idx + 1] == "settings" {
                        return true
                    }
                }
                return false
            }()
            guard isPortableSaveDir || isSteamSettingsUserData else { return }

            let candidateDest = canonicalStaging.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
            guard let safeDest = PathSafety.containedURL(candidateDest, in: canonicalStaging),
                  !fm.fileExists(atPath: safeDest.path) else {
                return
            }

            if isSteamSettingsUserData,
               let ssIdx = dirComponentsLower.firstIndex(of: "steam_settings"), ssIdx > 0 {
                let parentRel = components[0..<ssIdx].joined(separator: "/")
                let expectedParent = canonicalStaging.appendingPathComponent(parentRel, isDirectory: true)
                guard fm.fileExists(atPath: expectedParent.path) else { return }
            }

            do {
                try fm.createDirectory(at: safeDest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: item, to: safeDest)
                migratedCount += 1
            } catch {
                // Non-fatal: continue migrating remaining saves.
            }
        }
        return migratedCount
    }

    private static func isSafeOldGameDirectoryToReplace(
        _ oldURL: URL,
        parentURL: URL,
        stagingURL: URL
    ) -> Bool {
        let oldCanonical = oldURL.resolvingSymlinksInPath().standardizedFileURL
        let parentCanonical = parentURL.resolvingSymlinksInPath().standardizedFileURL
        let stagingCanonical = stagingURL.resolvingSymlinksInPath().standardizedFileURL

        if oldCanonical.path == stagingCanonical.path || oldCanonical.path.hasPrefix(stagingCanonical.path + "/") {
            return false
        }
        return PathSafety.containedURL(oldCanonical, in: parentCanonical) != nil
    }
}
