import ChrysaCore
import ChrysaApplication
import Darwin
import Foundation

package actor GamePatchApplier {
    private let unpackService: UnpackService
    private let patchService: PatchService
    private let snapshotManager: GameSnapshotManager
    private let supervisor: ProcessSupervisor
    private let bottleConfigurator: CrossOverBottleConfigurator

    private static let osJunkNames: Set<String> = [
        ".ds_store", "thumbs.db", "__macosx"
    ]

    private static let nonStrippableRootDirNames: Set<String> = [
        "bepinex", "melonloader", "plugins", "mods", "~mods", "paks",
        "content", "engine", "binaries", "steam_settings", "saves", "savedata",
        "userdata", "x64", "x86", "win64", "win32", "data", "streamingassets",
        "managed", "il2cpp_data", "game", "assets", "localization", "patch"
    ]

    private static let extraArchiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "bz2", "xz", "tgz", "tbz2", "txz"
    ]

    package init(
        unpackService: UnpackService = UnpackService(),
        patchService: PatchService = PatchService(),
        snapshotManager: GameSnapshotManager = GameSnapshotManager(),
        supervisor: ProcessSupervisor = .shared,
        bottleConfigurator: CrossOverBottleConfigurator = CrossOverBottleConfigurator()
    ) {
        self.unpackService = unpackService
        self.patchService = patchService
        self.snapshotManager = snapshotManager
        self.supervisor = supervisor
        self.bottleConfigurator = bottleConfigurator
    }

    package func apply(
        game: LaunchGame,
        sourceURL: URL,
        settings: AppSettings,
        onLog: @escaping @Sendable (StageLog) async -> Void
    ) async -> LaunchGamePatchOutcome {
        await apply(game: game, sourceURLs: [sourceURL], settings: settings, onLog: onLog)
    }

    package func apply(
        game: LaunchGame,
        sourceURLs: [URL],
        settings: AppSettings,
        onLog: @escaping @Sendable (StageLog) async -> Void
    ) async -> LaunchGamePatchOutcome {
        let log: @Sendable (String, Bool) async -> Void = { msg, hi in
            await onLog(StageLog(msg, highlight: hi))
        }

        guard let gameDirPath = game.gameDirectory,
              let canonicalGameRoot = try? PathSafety.existingCanonicalDirectory(gameDirPath) else {
            return .failed("游戏目录无效或不存在")
        }
        guard !sourceURLs.isEmpty else {
            return .failed("未选择任何补丁文件或文件夹")
        }

        // Validate all inputs and block self-drops BEFORE touching or creating any baseline snapshot.
        var validatedInputs: [(url: URL, isDirectory: Bool)] = []
        for rawURL in sourceURLs {
            let standardized = rawURL.standardizedFileURL
            let vals = try? standardized.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard let vals,
                  vals.isSymbolicLink != true,
                  (vals.isDirectory == true || vals.isRegularFile == true) else {
                return .failed("补丁源路径无效或不可读: \(standardized.lastPathComponent)")
            }
            let canonicalSource = standardized.resolvingSymlinksInPath().standardizedFileURL
            if PathSafety.containedURL(canonicalSource, in: canonicalGameRoot, allowRoot: true) != nil {
                return .failed("不能将游戏自身目录或其内部文件作为补丁源拖入")
            }
            validatedInputs.append((standardized, vals.isDirectory == true))
        }

        let expandedInputs = Self.expandBarePakCompanionsIfNeeded(
            validatedInputs,
            gameRoot: canonicalGameRoot
        )

        if expandedInputs.count == 1, !expandedInputs[0].isDirectory {
            let onlyURL = expandedInputs[0].url
            let ext = onlyURL.pathExtension.lowercased()
            let allowedSingleFile = Self.isArchiveURL(onlyURL)
                || ext == "exe"
                || ext == "pak"
                || ext == "utoc"
                || ext == "ucas"
                || ext == "dll"
                || ext == "ini"
                || ext == "asi"
                || ext == "bat"
                || ext == "cmd"
                || onlyURL.lastPathComponent.hasPrefix(".")
            guard allowedSingleFile else {
                return .failed("不支持的补丁格式，请拖入压缩包 (.zip/.7z/.rar)、文件夹、.pak 或 .exe 安装程序")
            }
        }

        let bottlesDirectory = settings.patch.bottlesDirectory
        let existingBottleName = CrossOverRegistryHelper.resolveExistingBottleName(
            explicitBottleName: game.bottleName,
            gameTitle: game.title,
            exePath: game.exePath,
            bottlesDirectory: bottlesDirectory
        )
        let bottlesRoot = (bottlesDirectory as NSString).expandingTildeInPath
        let existingBottlePath = existingBottleName.map { (bottlesRoot as NSString).appendingPathComponent($0) }

        do {
            _ = try await snapshotManager.ensureBaselineSnapshot(
                for: game,
                bottlePath: existingBottlePath,
                onLog: log
            )
        } catch {
            return .failed("无法建立原版基准快照: \(error.localizedDescription)")
        }

        enum PatchWorkItem {
            case installer(URL)
            case archiveOrDirectory(URL, isArchive: Bool)
            case looseFiles([URL])
        }

        var workQueue: [PatchWorkItem] = []
        var looseBuffer: [URL] = []
        func flushLooseBuffer() {
            guard !looseBuffer.isEmpty else { return }
            workQueue.append(.looseFiles(looseBuffer))
            looseBuffer.removeAll()
        }

        for entry in expandedInputs {
            let ext = entry.url.pathExtension.lowercased()
            if entry.isDirectory {
                flushLooseBuffer()
                workQueue.append(.archiveOrDirectory(entry.url, isArchive: false))
            } else if ext == "exe" {
                flushLooseBuffer()
                workQueue.append(.installer(entry.url))
            } else if Self.isArchiveURL(entry.url) {
                flushLooseBuffer()
                workQueue.append(.archiveOrDirectory(entry.url, isArchive: true))
            } else {
                looseBuffer.append(entry.url)
            }
        }
        flushLooseBuffer()

        var workingGame = game
        var summaries: [String] = []
        var needsPostMergeSync = false

        for item in workQueue {
            switch item {
            case .installer(let installerURL):
                if needsPostMergeSync {
                    await syncHooksAndDLCs(for: &workingGame, gameRoot: canonicalGameRoot, settings: settings, log: log)
                    needsPostMergeSync = false
                }
                let outcome = await applyExecutableInstaller(
                    game: workingGame,
                    gameRoot: canonicalGameRoot,
                    installerURL: installerURL,
                    settings: settings,
                    log: log
                )
                switch outcome {
                case .applied(let updated, let summary):
                    workingGame = updated
                    summaries.append(summary)
                case .cancelled:
                    return .cancelled
                case .failed(let msg):
                    return .failed(msg)
                }

            case .archiveOrDirectory(let source, let isArchive):
                do {
                    let mergeReport = try await mergeArchiveOrDirectory(
                        sourceURL: source,
                        isArchive: isArchive,
                        game: workingGame,
                        gameRoot: canonicalGameRoot,
                        settings: settings,
                        log: log
                    )
                    try await handlePostMergeEffects(
                        mergeReport: mergeReport,
                        workingGame: &workingGame,
                        gameRoot: canonicalGameRoot,
                        settings: settings,
                        summaries: &summaries,
                        log: log
                    )
                    needsPostMergeSync = true
                } catch {
                    await log("error ▸ 补丁安装失败: \(error.localizedDescription)", true)
                    return .failed("补丁安装失败: \(error.localizedDescription)")
                }

            case .looseFiles(let files):
                do {
                    let mergeReport = try await mergeLooseFiles(
                        files,
                        game: workingGame,
                        gameRoot: canonicalGameRoot,
                        log: log
                    )
                    try await handlePostMergeEffects(
                        mergeReport: mergeReport,
                        workingGame: &workingGame,
                        gameRoot: canonicalGameRoot,
                        settings: settings,
                        summaries: &summaries,
                        log: log
                    )
                    needsPostMergeSync = true
                } catch {
                    await log("error ▸ 补丁安装失败: \(error.localizedDescription)", true)
                    return .failed("补丁安装失败: \(error.localizedDescription)")
                }
            }
        }

        if needsPostMergeSync {
            await syncHooksAndDLCs(for: &workingGame, gameRoot: canonicalGameRoot, settings: settings, log: log)
        }

        let finalSummary = summaries.joined(separator: "；")
        await log("patch-drop ▸ [\(workingGame.title)] \(finalSummary)", true)
        return .applied(updatedGame: workingGame, summary: finalSummary)
    }

    private static func isArchiveURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return UnpackService.isArchiveFile(url.path) || extraArchiveExtensions.contains(ext)
    }

    private static func expandBarePakCompanionsIfNeeded(
        _ inputs: [(url: URL, isDirectory: Bool)],
        gameRoot: URL
    ) -> [(url: URL, isDirectory: Bool)] {
        guard inputs.count == 1,
              !inputs[0].isDirectory,
              inputs[0].url.pathExtension.lowercased() == "pak" else {
            return inputs
        }
        let pakURL = inputs[0].url
        let parentDir = pakURL.deletingLastPathComponent()
        let stem = pakURL.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: parentDir.path) else {
            return inputs
        }

        var expanded = inputs
        for ext in ["utoc", "ucas"] {
            let expectedLower = "\(stem).\(ext)".lowercased()
            guard let matchName = entries.first(where: { $0.lowercased() == expectedLower }) else {
                continue
            }
            let companionURL = parentDir.appendingPathComponent(matchName).standardizedFileURL
            let vals = try? companionURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard vals?.isRegularFile == true, vals?.isSymbolicLink != true else { continue }
            let canonicalCompanion = companionURL.resolvingSymlinksInPath().standardizedFileURL
            guard PathSafety.containedURL(canonicalCompanion, in: gameRoot, allowRoot: true) == nil else {
                continue
            }
            expanded.append((companionURL, false))
        }
        return expanded
    }

    private func mergeArchiveOrDirectory(
        sourceURL: URL,
        isArchive: Bool,
        game: LaunchGame,
        gameRoot: URL,
        settings: AppSettings,
        log: @escaping @Sendable (String, Bool) async -> Void
    ) async throws -> MergeReport {
        let fm = FileManager.default
        var tempSandboxURL: URL?
        defer {
            if let tempSandboxURL {
                try? fm.removeItem(at: tempSandboxURL)
            }
        }

        let rawPayloadRoot: URL
        if isArchive {
            let sandbox = fm.temporaryDirectory.appendingPathComponent("chrysa-patch-sandbox-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
            tempSandboxURL = sandbox
            await log("patch-drop ▸ 正在沙盒解压补丁包: \(sourceURL.lastPathComponent)", true)
            let ok = await unpackService.extractArchiveToSandbox(
                archivePath: sourceURL.path,
                sandboxURL: sandbox,
                candidatePasswords: settings.unpack.passwords,
                taskID: game.id
            )
            guard ok else {
                throw NSError(domain: "Chrysa.PatchApply", code: 3, userInfo: [NSLocalizedDescriptionKey: "补丁压缩包解压失败（可能缺少密码或压缩包损坏）"])
            }
            rawPayloadRoot = sandbox
        } else {
            rawPayloadRoot = sourceURL
        }

        let canonicalPayload = try PathSafety.existingCanonicalDirectory(rawPayloadRoot.path)
        let effectivePayloadRoot = Self.unwrapRedundantSingleWrapperDirectory(
            from: canonicalPayload,
            gameRoot: gameRoot
        )
        return try await mergePreparedPayload(
            payloadRoot: effectivePayloadRoot,
            intoGameRoot: gameRoot,
            game: game
        )
    }

    private func mergeLooseFiles(
        _ files: [URL],
        game: LaunchGame,
        gameRoot: URL,
        log: @escaping @Sendable (String, Bool) async -> Void
    ) async throws -> MergeReport {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("chrysa-loose-sandbox-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }

        if files.count > 1, files.contains(where: { $0.pathExtension.lowercased() == "pak" }) {
            let names = files.map(\.lastPathComponent).joined(separator: ", ")
            await log("pak ▸ 已关联收集配套文件: \(names)", false)
        }
        for file in files {
            try fm.copyItem(at: file, to: sandbox.appendingPathComponent(file.lastPathComponent))
        }
        return try await mergePreparedPayload(
            payloadRoot: sandbox,
            intoGameRoot: gameRoot,
            game: game
        )
    }

    private func handlePostMergeEffects(
        mergeReport: MergeReport,
        workingGame: inout LaunchGame,
        gameRoot: URL,
        settings: AppSettings,
        summaries: inout [String],
        log: @escaping @Sendable (String, Bool) async -> Void
    ) async throws {
        workingGame.updatedAt = Date()
        if mergeReport.requiresFileOpenLogFlag {
            workingGame.launchArguments = workingGame.appendingLaunchArgument("-fileopenlog")
            await log("ue5-mod ▸ 检测到 .utoc/.ucas 资源，已自动附加 -fileopenlog 启动参数", true)
        }
        if !mergeReport.rootPatchBats.isEmpty {
            await log("bat-patch ▸ 检测到根目录批处理补丁脚本，准备在容器内执行...", true)
            try await runRootPatchBats(
                mergeReport.rootPatchBats,
                game: workingGame,
                gameRoot: gameRoot,
                settings: settings,
                onLog: log
            )
        }
        if let ueTarget = mergeReport.routedUEPaksModsRelative {
            summaries.append("已精准安装 \(mergeReport.mergedFileCount) 个 UE Pak 至 \(ueTarget)")
        } else {
            summaries.append("已安全增量合并 \(mergeReport.mergedFileCount) 个文件")
        }
    }

    private func syncHooksAndDLCs(
        for workingGame: inout LaunchGame,
        gameRoot: URL,
        settings: AppSettings,
        log: @escaping @Sendable (String, Bool) async -> Void
    ) async {
        if let preSync = CrossOverBottleConfigurator.syncPreLaunchEnvironment(
            gameTitle: workingGame.title,
            bottleName: workingGame.bottleName,
            executablePath: workingGame.exePath,
            gameDirectory: gameRoot.path,
            bottlesDirectory: settings.patch.bottlesDirectory
        ) {
            if workingGame.bottleName == nil {
                workingGame.bottleName = preSync.bottleName
            }
            if !preSync.detectedProxyStems.isEmpty {
                await log("hook ▸ 已自动同步新增代理钩子 DLL 放行: \(preSync.detectedProxyStems.joined(separator: ", "))", false)
            }
        }
        await patchService.refreshDLCConfiguration(
            directory: gameRoot.path,
            explicitAppID: workingGame.appID,
            onLog: log
        )
    }

    // MARK: - Unwrap Single Wrapper Folder

    package static func unwrapRedundantSingleWrapperDirectory(from payloadRoot: URL, gameRoot: URL) -> URL {
        let fm = FileManager.default
        let existingGameTopDirs: Set<String> = {
            let entries = (try? fm.contentsOfDirectory(atPath: gameRoot.path)) ?? []
            var set = Set<String>()
            for entry in entries {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: gameRoot.appendingPathComponent(entry).path, isDirectory: &isDir),
                   isDir.boolValue {
                    set.insert(entry.lowercased())
                }
            }
            return set
        }()

        var cursor = payloadRoot
        for _ in 0..<4 {
            guard let rawEntries = try? fm.contentsOfDirectory(atPath: cursor.path) else { break }
            let relevantEntries = rawEntries.filter { !isOSJunk($0) }
            guard relevantEntries.count == 1, let onlyName = relevantEntries.first else {
                break
            }
            let childURL = cursor.appendingPathComponent(onlyName).standardizedFileURL
            guard let vals = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  vals.isDirectory == true,
                  vals.isSymbolicLink != true else {
                break
            }
            let lower = onlyName.lowercased()
            if nonStrippableRootDirNames.contains(lower) || existingGameTopDirs.contains(lower) {
                break
            }
            cursor = childURL
        }
        return cursor
    }

    // MARK: - Merge & UE Bare Pak Routing

    package struct MergeReport: Sendable {
        package let mergedFileCount: Int
        package let routedUEPaksModsRelative: String?
        package let requiresFileOpenLogFlag: Bool
        package let rootPatchBats: [String]
    }

    package func mergePreparedPayload(
        payloadRoot: URL,
        intoGameRoot gameRoot: URL,
        game: LaunchGame
    ) async throws -> MergeReport {
        let canonicalPayload = try PathSafety.existingCanonicalDirectory(payloadRoot.path)
        let canonicalGame = try PathSafety.existingCanonicalDirectory(gameRoot.path)

        if let barePakReport = try await tryMergeBareUnrealPakPayload(
            payloadRoot: canonicalPayload,
            gameRoot: canonicalGame,
            game: game
        ) {
            return barePakReport
        }

        var collectedFiles: [(url: URL, components: [String])] = []
        try PathSafety.walkDirectory(
            at: canonicalPayload,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants],
            includeSymlinks: false
        ) { item, relativePath, vals in
            guard vals.isRegularFile == true else { return }
            let components = relativePath.split(separator: "/").map(String.init)
            guard !components.isEmpty, !components.contains(where: { Self.isOSJunk($0) }) else {
                return
            }
            collectedFiles.append((item, components))
        }

        var mergedCount = 0
        var rootPatchBats: [String] = []
        for (item, components) in collectedFiles {
            let resolved = Self.resolveCaseInsensitiveDestination(
                components: components,
                inGameRoot: canonicalGame
            )
            let destURL = resolved.url.standardizedFileURL
            guard let safeDest = PathSafety.containedURL(destURL, in: canonicalGame),
                  safeDest.path != canonicalGame.path else {
                continue
            }

            try await snapshotManager.recordIncomingChange(
                relativePath: resolved.relativePath,
                gameID: game.id,
                gameDirectory: canonicalGame.path
            )

            try PathSafety.replaceFileSafely(from: item, to: safeDest, copyInsteadOfMove: true)
            Self.sanitizeFileAttributesAndPermissions(at: safeDest.path)
            mergedCount += 1

            if components.count == 1 && Self.isObviousPatchBatchScript(safeDest.lastPathComponent) {
                rootPatchBats.append(safeDest.lastPathComponent)
            }
        }

        guard mergedCount > 0 else {
            throw NSError(domain: "Chrysa.PatchApply", code: 2, userInfo: [NSLocalizedDescriptionKey: "补丁包内未找到可合并的文件"])
        }

        return MergeReport(
            mergedFileCount: mergedCount,
            routedUEPaksModsRelative: nil,
            requiresFileOpenLogFlag: false,
            rootPatchBats: rootPatchBats.sorted()
        )
    }

    private func tryMergeBareUnrealPakPayload(
        payloadRoot: URL,
        gameRoot: URL,
        game: LaunchGame
    ) async throws -> MergeReport? {
        let fm = FileManager.default
        let entries = ((try? fm.contentsOfDirectory(atPath: payloadRoot.path)) ?? []).filter { !Self.isOSJunk($0) }
        guard !entries.isEmpty else { return nil }

        var sourceFiles: [URL] = []
        var hasPak = false
        var hasIoStore = false
        let allowedExts: Set<String> = ["pak", "utoc", "ucas"]

        for entry in entries {
            let item = payloadRoot.appendingPathComponent(entry).standardizedFileURL
            guard let vals = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  vals.isSymbolicLink != true,
                  vals.isDirectory != true,
                  vals.isRegularFile == true,
                  PathSafety.containedURL(item, in: payloadRoot) != nil else {
                return nil
            }
            let ext = item.pathExtension.lowercased()
            guard allowedExts.contains(ext) else {
                return nil
            }
            if ext == "pak" { hasPak = true }
            if ext == "utoc" || ext == "ucas" { hasIoStore = true }
            sourceFiles.append(item)
        }

        guard hasPak else { return nil }

        let paksDirs = Self.findUniqueUnrealContentPaksDirectories(in: gameRoot)
        guard paksDirs.count == 1, let uniquePaks = paksDirs.first else {
            return nil
        }

        let modsDir = Self.resolveCaseInsensitiveSingleSegment(named: "~mods", in: uniquePaks)
        guard let safeModsDir = PathSafety.containedURL(modsDir, in: gameRoot) else {
            return nil
        }
        try fm.createDirectory(at: safeModsDir, withIntermediateDirectories: true)

        let gamePrefix = gameRoot.path.hasSuffix("/") ? gameRoot.path : gameRoot.path + "/"
        var mergedCount = 0

        for srcFile in sourceFiles {
            let leafResolved = Self.resolveCaseInsensitiveSingleSegment(named: srcFile.lastPathComponent, in: safeModsDir)
            guard let safeDest = PathSafety.containedURL(leafResolved, in: gameRoot),
                  safeDest.path.hasPrefix(gamePrefix) else {
                continue
            }
            let relPath = String(safeDest.path.dropFirst(gamePrefix.count))
            try await snapshotManager.recordIncomingChange(
                relativePath: relPath,
                gameID: game.id,
                gameDirectory: gameRoot.path
            )
            try PathSafety.replaceFileSafely(from: srcFile, to: safeDest, copyInsteadOfMove: true)
            Self.sanitizeFileAttributesAndPermissions(at: safeDest.path)
            mergedCount += 1
        }

        let modsRel = safeModsDir.path.hasPrefix(gamePrefix)
            ? String(safeModsDir.path.dropFirst(gamePrefix.count))
            : "Content/Paks/~mods"

        return MergeReport(
            mergedFileCount: mergedCount,
            routedUEPaksModsRelative: modsRel,
            requiresFileOpenLogFlag: hasIoStore,
            rootPatchBats: []
        )
    }

    package static func findUniqueUnrealContentPaksDirectories(in gameRoot: URL) -> [URL] {
        var projectPaks: [URL] = []
        var rootContentPaks: [URL] = []
        try? PathSafety.walkDirectory(
            at: gameRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            includeSymlinks: false
        ) { item, rel, vals in
            guard vals.isDirectory == true else { return }
            let comps = rel.split(separator: "/").map(String.init)
            if comps.count == 3,
               comps[0].caseInsensitiveCompare("Engine") != .orderedSame,
               comps[1].caseInsensitiveCompare("Content") == .orderedSame,
               comps[2].caseInsensitiveCompare("Paks") == .orderedSame {
                projectPaks.append(item)
            } else if comps.count == 2,
                      comps[0].caseInsensitiveCompare("Content") == .orderedSame,
                      comps[1].caseInsensitiveCompare("Paks") == .orderedSame {
                rootContentPaks.append(item)
            }
        }
        return !projectPaks.isEmpty ? projectPaks : rootContentPaks
    }

    // MARK: - Root Patch .bat Execution

    private func runRootPatchBats(
        _ batFileNames: [String],
        game: LaunchGame,
        gameRoot: URL,
        settings: AppSettings,
        onLog: @escaping @Sendable (String, Bool) async -> Void
    ) async throws {
        guard let cxWine = ToolchainLocator.locateCrossOverBin("wine") else {
            await onLog("warn ▸ 未找到 CrossOver wine，跳过自动执行根目录批处理补丁", false)
            return
        }
        let bottleName = try await prepareBottleForExecution(
            game: game,
            gameRoot: gameRoot,
            settings: settings
        )
        guard bottleName != "Default" else { return }

        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "zh_CN.UTF-8"
        env["LC_ALL"] = "zh_CN.UTF-8"

        let opaqueToken = await snapshotManager.prepareForOpaqueProcessMutation(for: game)
        do {
            for batName in batFileNames {
                await onLog("cmd.exe ▸ 在容器 [\(bottleName)] (C:\\\(bottleName)) 中执行: \(batName)", true)
                let res = try await supervisor.run(
                    executable: cxWine,
                    arguments: ["--bottle", bottleName, "--wait-children", "--workdir", "C:\\\(bottleName)", "cmd.exe", "/c", batName],
                    currentDirectory: gameRoot.path,
                    environment: env,
                    taskID: game.id,
                    captureOutput: true,
                    mergeStderr: true
                )
                if res.exitCode != 0 {
                    await onLog("warn ▸ 批处理脚本 \(batName) 退出码 \(res.exitCode)", false)
                }
            }
            await snapshotManager.finalizeOpaqueProcessMutation(opaqueToken)
        } catch {
            await snapshotManager.finalizeOpaqueProcessMutation(opaqueToken)
            throw error
        }
    }

    // MARK: - .exe Installer Execution (Branch 2)

    private func applyExecutableInstaller(
        game: LaunchGame,
        gameRoot: URL,
        installerURL: URL,
        settings: AppSettings,
        log: @escaping @Sendable (String, Bool) async -> Void
    ) async -> LaunchGamePatchOutcome {
        guard let cxWine = ToolchainLocator.locateCrossOverBin("wine") else {
            return .failed("未检测到 CrossOver wine 运行时，无法运行 .exe 安装程序")
        }

        let opaqueToken = await snapshotManager.prepareForOpaqueProcessMutation(for: game)

        // 1. Temporarily restore original steam_api*.dll from `.bak` so CRC updaters verify official originals cleanly.
        let restoredBackups = temporarilyRestoreBackedUpSteamDLLs(in: gameRoot)
        if restoredBackups > 0 {
            await log("crc-prep ▸ 已临时还原 \(restoredBackups) 个原版 steam_api*.dll (.bak) 以通过升级校验", true)
        }

        do {
            // 2. Ensure bottle, C:\<bottleName> symlink, Chinese fonts, and Steam App InstallLocation in registry.
            let bottleName = try await prepareBottleForExecution(
                game: game,
                gameRoot: gameRoot,
                settings: settings
            )
            guard bottleName != "Default" else {
                throw NSError(domain: "Chrysa.Installer", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到可用的 CrossOver 容器"])
            }

            let bottlesRoot = (settings.patch.bottlesDirectory as NSString).expandingTildeInPath
            let bottlePath = (bottlesRoot as NSString).appendingPathComponent(bottleName)
            let inspection = GameDirectoryInspector.inspect(directory: gameRoot.path)
            let resolvedAppID = [game.appID, inspection?.existingAppID]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && Int($0) != nil }

            var env = ProcessInfo.processInfo.environment
            env["LANG"] = "zh_CN.UTF-8"
            env["LC_ALL"] = "zh_CN.UTF-8"

            if let appID = resolvedAppID {
                try? CrossOverRegistryHelper.ensureSteamAppInstallLocation(
                    inBottlePath: bottlePath,
                    appID: appID,
                    bottleName: bottleName
                )
                for key in [
                    "HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Steam App \(appID)",
                    "HKLM\\Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Steam App \(appID)"
                ] {
                    _ = try? await supervisor.run(
                        executable: cxWine,
                        arguments: ["--bottle", bottleName, "reg.exe", "add", key, "/v", "InstallLocation", "/t", "REG_SZ", "/d", "C:\\\(bottleName)", "/f"],
                        environment: env,
                        taskID: game.id
                    )
                }
                await log("reg ▸ 已写入 Steam App \(appID) 安装路径 (C:\\\(bottleName)) 供安装向导定位", false)
            }

            // 3. Execute installer inside bottle (cwd C:\<bottleName>, LANG=zh_CN.UTF-8) and wait for completion.
            let winTarget = CrossOverRegistryHelper.windowsLaunchTarget(
                exePath: installerURL.path,
                gameDirectory: gameRoot.path,
                bottlePath: bottlePath,
                bottleName: bottleName
            ) ?? installerURL.path

            await log("installer ▸ 正在容器 [\(bottleName)] 中运行安装器: \(installerURL.lastPathComponent) (等待退出)...", true)
            let runResult = try await supervisor.run(
                executable: cxWine,
                arguments: ["--bottle", bottleName, "--wait-children", "--workdir", "C:\\\(bottleName)", winTarget],
                currentDirectory: gameRoot.path,
                environment: env,
                taskID: game.id,
                captureOutput: true,
                mergeStderr: true
            )
            if runResult.exitCode != 0 {
                await log("warn ▸ 安装程序退出码 \(runResult.exitCode)，继续执行目录补丁复检", false)
            }

            // 4. Post-run: re-execute full PatchService check + Steam DLC sync.
            await log("post-check ▸ 安装器已退出，正在重新检查补丁状态并刷新 Steam DLC...", true)
            let patchResult = try await runPostInstallerPatchCheck(
                game: game,
                gameRoot: gameRoot,
                settings: settings,
                log: log
            )
            await snapshotManager.finalizeOpaqueProcessMutation(opaqueToken)

            var updatedGame = game
            updatedGame.updatedAt = Date()
            if let currentExe = game.exePath, FileManager.default.fileExists(atPath: currentExe) {
                updatedGame.exePath = currentExe
            } else if let patchExe = patchResult.exePath, !patchExe.isEmpty {
                updatedGame.exePath = patchExe
            }
            if !patchResult.appID.isEmpty, patchResult.appID != "480" {
                updatedGame.appID = patchResult.appID
            }
            if let b = patchResult.bottleName, !b.isEmpty {
                updatedGame.bottleName = b
            }

            return .applied(
                updatedGame: updatedGame,
                summary: "安装器执行完毕并已刷新补丁与 DLC 配置"
            )
        } catch {
            if restoredBackups > 0 {
                _ = try? await runPostInstallerPatchCheck(
                    game: game,
                    gameRoot: gameRoot,
                    settings: settings,
                    log: log
                )
            }
            await snapshotManager.finalizeOpaqueProcessMutation(opaqueToken)
            return .failed("安装器运行失败: \(error.localizedDescription)")
        }
    }

    private func runPostInstallerPatchCheck(
        game: LaunchGame,
        gameRoot: URL,
        settings: AppSettings,
        log: @escaping @Sendable (String, Bool) async -> Void
    ) async throws -> PatchResultPayload {
        let queue = StageEventQueue<(String, Bool)> { msg, hi in
            await log(msg, hi)
        }
        do {
            let result = try await patchService.executePatch(
                taskID: game.id,
                folderPath: gameRoot.path,
                cleanTitle: game.title,
                settings: settings,
                onLog: { msg, hi in
                    queue.submit((msg, hi))
                }
            )
            await queue.drain()
            return result
        } catch {
            await queue.drain()
            throw error
        }
    }

    private func prepareBottleForExecution(
        game: LaunchGame,
        gameRoot: URL,
        settings: AppSettings
    ) async throws -> String {
        let bottleName = try await bottleConfigurator.configure(
            taskID: game.id,
            gameTitle: game.title,
            exePath: game.exePath ?? gameRoot.appendingPathComponent("game.exe").path,
            gameDirectory: gameRoot.path,
            bottlesDirectory: settings.patch.bottlesDirectory,
            hasD3D12: false,
            hasWinHTTP: false
        )
        if bottleName != "Default" {
            let bottlesRoot = (settings.patch.bottlesDirectory as NSString).expandingTildeInPath
            let bottlePath = (bottlesRoot as NSString).appendingPathComponent(bottleName)
            _ = try? CrossOverRegistryHelper.ensureBottleDriveCSymlink(
                bottlePath: bottlePath,
                bottleName: bottleName,
                targetDirectory: gameRoot.path
            )
            try? CrossOverRegistryHelper.ensureChineseFontsConfigured(bottlePath: bottlePath)
        }
        return bottleName
    }

    private func temporarilyRestoreBackedUpSteamDLLs(in gameRoot: URL) -> Int {
        let fm = FileManager.default
        var backups: [URL] = []
        try? PathSafety.walkDirectory(
            at: gameRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants],
            includeSymlinks: false
        ) { item, _, vals in
            guard vals.isRegularFile == true else { return }
            let lower = item.lastPathComponent.lowercased()
            if lower == "steam_api64.dll.bak" || lower == "steam_api.dll.bak" {
                backups.append(item)
            }
        }
        var count = 0
        for item in backups {
            let targetURL = item.deletingPathExtension()
            guard let safeTarget = PathSafety.containedURL(targetURL, in: gameRoot) else { continue }
            do {
                if fm.fileExists(atPath: safeTarget.path) {
                    try fm.removeItem(at: safeTarget)
                }
                try fm.moveItem(at: item, to: safeTarget)
                count += 1
            } catch {
                // Non-fatal: continue inspecting remaining backups.
            }
        }
        return count
    }

    // MARK: - Path & Attribute Helpers

    private static func isOSJunk(_ name: String) -> Bool {
        let lower = name.lowercased()
        return osJunkNames.contains(lower) || lower.hasPrefix("._")
    }

    package static func isObviousPatchBatchScript(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        guard lower.hasSuffix(".bat") || lower.hasSuffix(".cmd") else { return false }
        let stem = String((lower as NSString).deletingPathExtension)
        if stem.hasPrefix("unins") || stem.contains("uninstall") || stem.contains("卸载") {
            return false
        }
        return stem.hasPrefix("install")
            || stem.hasPrefix("patch")
            || stem.contains("汉化")
            || stem.contains("补丁")
    }

    private static func resolveCaseInsensitiveSingleSegment(named target: String, in directory: URL) -> URL {
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(atPath: directory.path),
           let match = entries.first(where: { $0.caseInsensitiveCompare(target) == .orderedSame }) {
            return directory.appendingPathComponent(match)
        }
        return directory.appendingPathComponent(target)
    }

    package static func resolveCaseInsensitiveDestination(
        components: [String],
        inGameRoot gameRoot: URL
    ) -> (url: URL, relativePath: String) {
        var cursor = gameRoot
        var resolvedComponents: [String] = []
        for component in components {
            let next = resolveCaseInsensitiveSingleSegment(named: component, in: cursor)
            resolvedComponents.append(next.lastPathComponent)
            cursor = next
        }
        return (cursor, resolvedComponents.joined(separator: "/"))
    }

    private static func sanitizeFileAttributesAndPermissions(at path: String) {
        // Recursively strip Apple quarantine extended attribute if present.
        _ = Darwin.removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW)
        var st = stat()
        if lstat(path, &st) == 0 {
            let currentMode = st.st_mode & 0o777
            let ext = (path as NSString).pathExtension.lowercased()
            let executableExts: Set<String> = ["exe", "dll", "bat", "cmd", "sh", "com"]
            var desiredMode = currentMode | S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
            if executableExts.contains(ext) || (currentMode & S_IXUSR != 0) {
                desiredMode |= S_IXUSR | S_IXGRP
            }
            if desiredMode != currentMode {
                _ = Darwin.chmod(path, desiredMode)
            }
        }
    }
}
