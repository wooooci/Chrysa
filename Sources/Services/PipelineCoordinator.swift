import Foundation

/// Orchestrates the Download ➔ Unpack ➔ Patch workflow on `@MainActor` while delegating heavy I/O
/// to isolated `DownloadService`, `UnpackService`, and `PatchAndBottleService` actors.
/// When `autoRelay` is enabled, downstream stages start silently in the background without stealing the user's active tab.
@MainActor
final class PipelineCoordinator {
    let downloadService: DownloadService
    let unpackService: UnpackService
    let patchService: PatchAndBottleService

    weak var viewModel: StudioViewModel?
    private var cancelledTaskIDs: Set<UUID> = []

    init(
        downloadService: DownloadService = DownloadService(),
        unpackService: UnpackService = UnpackService(),
        patchService: PatchAndBottleService = PatchAndBottleService()
    ) {
        self.downloadService = downloadService
        self.unpackService = unpackService
        self.patchService = patchService
    }

    func markTaskCancelled(_ taskID: UUID) {
        cancelledTaskIDs.insert(taskID)
    }

    private func markTaskStarted(_ taskID: UUID) {
        cancelledTaskIDs.remove(taskID)
    }

    private func acceptsProgress(for taskID: UUID) -> Bool {
        !cancelledTaskIDs.contains(taskID)
    }

    func startDownload(urlString: String) {
        guard let vm = viewModel else { return }
        let cleanURL = HostResolverRegistry.normalizeDownloadInput(urlString)
            ?? urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return }

        let rawLast = URL(string: cleanURL)?.lastPathComponent ?? ""
        let guessedName: String = {
            if let decoded = HostResolverRegistry.decodeBase64FilenameIfPossible(rawLast) {
                return decoded
            }
            if !rawLast.isEmpty {
                return rawLast
            }
            return "Download_\(Int(Date().timeIntervalSince1970)).7z"
        }()

        let isMirrorWait = cleanURL.lowercased().contains("mirroruploadx.com") || cleanURL.lowercased().contains("fileditch")
        let firstTaskID = UUID()
        markTaskStarted(firstTaskID)
        let newTask = StudioTask(
            id: firstTaskID,
            title: guessedName,
            status: .running(0.02),
            pill: isMirrorWait ? "优选分流 (约10s)" : "嗅探中",
            rightText: "准备中",
            sourceURL: cleanURL
        )
        vm.downloadTasks.insert(newTask, at: 0)
        vm.scheduleTaskSave()
        vm.appendLog("sniff ▸ 开始解析链接: \(cleanURL)", highlight: true)

        let passwordsSnapshot = vm.settingsStore.settings.passwords
        Task { [weak self] in
            guard let self = self else { return }
            let resolvedList = await HostResolverRegistry.resolveLinks(cleanURL, passwords: passwordsSnapshot)
            guard self.acceptsProgress(for: firstTaskID), let vm = self.viewModel else { return }

            guard let first = resolvedList.first else {
                if let idx = vm.downloadTasks.firstIndex(where: { $0.id == firstTaskID }) {
                    vm.downloadTasks[idx].status = .failed
                    vm.downloadTasks[idx].pill = "解析失败"
                    vm.downloadTasks[idx].rightText = "无法获取直链"
                    vm.scheduleTaskSave()
                }
                vm.appendLog("error ▸ 无法从该分享页解析出有效文件直链: \(cleanURL)", highlight: true)
                return
            }

            if resolvedList.count == 1 {
                if let idx = vm.downloadTasks.firstIndex(where: { $0.id == firstTaskID }) {
                    if let name = first.suggestedFilename, !name.isEmpty {
                        vm.downloadTasks[idx].title = name
                    }
                    vm.downloadTasks[idx].pill = "连接中"
                    vm.scheduleTaskSave()
                }
                vm.appendLog("dl ▸ 启动高速下载: \(first.suggestedFilename ?? first.finalURL)", highlight: false)
                await self.runDownloadTask(taskID: firstTaskID, resolved: first, suppressAutoRelay: false)
            } else {
                await self.runFolderDownloadPipeline(firstTaskID: firstTaskID, guessedName: guessedName, items: resolvedList)
            }
        }
    }

    private func runFolderDownloadPipeline(firstTaskID: UUID, guessedName: String, items: [ResolvedDownload]) async {
        guard let vm = viewModel, let first = items.first else { return }

        var taskPairs: [(UUID, ResolvedDownload)] = [(firstTaskID, first)]
        for item in items.dropFirst() {
            taskPairs.append((UUID(), item))
        }
        let folderTitle = first.subDirectory ?? "多文件目录"

        if let idx = vm.downloadTasks.firstIndex(where: { $0.id == firstTaskID }) {
            vm.downloadTasks[idx].title = first.suggestedFilename ?? guessedName
            vm.downloadTasks[idx].pill = "队列 1/\(taskPairs.count)"
        }
        for (idxOffset, pair) in taskPairs.dropFirst().enumerated() {
            let t = StudioTask(
                id: pair.0,
                title: pair.1.suggestedFilename ?? "分卷文件",
                status: .queued,
                pill: "队列 \(idxOffset + 2)/\(taskPairs.count)",
                rightText: pair.1.totalSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "待下载",
                sourceURL: pair.1.originalURL
            )
            vm.downloadTasks.insert(t, at: min(idxOffset + 1, vm.downloadTasks.count))
        }
        vm.scheduleTaskSave()
        vm.appendLog("folder ▸ 检测到分享文件夹 [\(folderTitle)]，共 \(taskPairs.count) 个文件，开始顺序拉取...", highlight: true)

        let dlRoot = (vm.settingsStore.settings.downloadDirectory as NSString).expandingTildeInPath
        let folderDir = first.subDirectory.map { (dlRoot as NSString).appendingPathComponent($0) } ?? dlRoot
        let allNames = taskPairs.compactMap { $0.1.suggestedFilename }
        let primaryFile = allNames.first(where: { UnpackService.isArchiveFile($0) })
        let primaryBase: String? = primaryFile.map { (($0 as NSString).deletingPathExtension).lowercased() }
        let requiredBinSlices: Set<String> = {
            guard let pb = primaryBase else { return [] }
            return Set(allNames.filter {
                let lower = $0.lowercased()
                return lower.hasPrefix(pb + "-") && lower.hasSuffix(".bin")
            })
        }()

        var completedFiles: Set<String> = []
        var baseUnpackTriggered = false

        for (tID, rawItem) in taskPairs {
            guard acceptsProgress(for: tID) else { continue }
            let freshItem = await MailRuResolver.refreshURLIfNeeded(rawItem)
            await runDownloadTask(taskID: tID, resolved: freshItem, suppressAutoRelay: true)
            if let fname = freshItem.suggestedFilename {
                let fullPath = (folderDir as NSString).appendingPathComponent(fname)
                if FileManager.default.fileExists(atPath: fullPath) {
                    completedFiles.insert(fname)
                }
            }

            guard let vmNow = viewModel else { return }
            if !baseUnpackTriggered,
               let prim = primaryFile,
               completedFiles.contains(prim),
               requiredBinSlices.isSubset(of: completedFiles) {
                baseUnpackTriggered = true
                let fullPrimary = (folderDir as NSString).appendingPathComponent(prim)
                let hasRemainingDLCs = completedFiles.count < taskPairs.count
                if vmNow.settingsStore.settings.autoRelay {
                    if hasRemainingDLCs {
                        vmNow.appendLog("relay ▸ 主程序与数据卷已就绪，后台静默流转至 [解压]: \(prim) (DLC 继续下载)", highlight: true)
                    } else {
                        vmNow.appendLog("relay ▸ 文件夹全部下载完成，后台静默流转至 [解压]: \(prim)", highlight: true)
                    }
                    startUnpack(filePath: fullPrimary)
                }
            } else if baseUnpackTriggered,
                      let fname = freshItem.suggestedFilename,
                      fname.lowercased().hasPrefix("setup_") && fname.lowercased().hasSuffix(".exe") {
                let fullDLC = (folderDir as NSString).appendingPathComponent(fname)
                if FileManager.default.fileExists(atPath: fullDLC), let prim = primaryFile {
                    var rawBase = (prim as NSString).deletingPathExtension
                    if rawBase.lowercased().hasPrefix("setup_") {
                        rawBase = String(rawBase.dropFirst("setup_".count))
                    }
                    let baseOutDir = (folderDir as NSString).appendingPathComponent(PatchAndBottleService.cleanGameTitle(from: rawBase))
                    vmNow.appendLog("innoextract ▸ DLC 下载完成，正在合并至主游戏目录: \(fname)", highlight: true)
                    let ok = await unpackService.mergeGOGDLCInstaller(dlcExePath: fullDLC, intoDir: baseOutDir, taskID: tID)
                    if ok {
                        vmNow.appendLog("innoextract ▸ DLC 合并完成: \(fname)", highlight: true)
                    }
                }
            }
        }
    }

    func runDownloadTask(taskID: UUID, resolved: ResolvedDownload, suppressAutoRelay: Bool = false) async {
        guard let vm = viewModel else { return }
        let currentTitle = vm.downloadTasks.first(where: { $0.id == taskID })?.title ?? (resolved.suggestedFilename ?? "Download")
        let settingsSnapshot = vm.settingsStore.settings

        let outcome = await downloadService.executeDownload(
            taskID: taskID,
            currentTitle: currentTitle,
            resolved: resolved,
            settings: settingsSnapshot,
            onProgress: { [weak self] upd in
                Task { @MainActor in
                    guard let self = self,
                          self.acceptsProgress(for: taskID),
                          let vm = self.viewModel,
                          let idx = vm.downloadTasks.firstIndex(where: { $0.id == taskID }) else { return }
                    if let p = upd.progress { vm.downloadTasks[idx].status = .running(p) }
                    if let pill = upd.pill { vm.downloadTasks[idx].pill = pill }
                    if let right = upd.rightText { vm.downloadTasks[idx].rightText = right }
                    if let path = upd.localPath { vm.downloadTasks[idx].localPath = path }
                    if let title = upd.resolvedTitle { vm.downloadTasks[idx].title = title }
                }
            },
            onLog: { [weak vm] msg, hl in
                Task { @MainActor in
                    vm?.appendLog(msg, highlight: hl)
                }
            }
        )

        guard let vmAfter = viewModel,
              let idx = vmAfter.downloadTasks.firstIndex(where: { $0.id == taskID }),
              acceptsProgress(for: taskID) else { return }

        switch outcome {
        case .completed(let localPath, let finalTitle, let rightText):
            vmAfter.downloadTasks[idx].status = .done
            vmAfter.downloadTasks[idx].pill = nil
            vmAfter.downloadTasks[idx].title = finalTitle
            vmAfter.downloadTasks[idx].localPath = localPath
            if let r = rightText {
                vmAfter.downloadTasks[idx].rightText = r
            }
            vmAfter.scheduleTaskSave()

            // Silent background relay (does NOT hijack activeTab!)
            if !suppressAutoRelay && vmAfter.settingsStore.settings.autoRelay && UnpackService.isArchiveFile(localPath) {
                vmAfter.appendLog("relay ▸ 后台自动流转至 [解压]: \(finalTitle)", highlight: true)
                startUnpack(filePath: localPath)
            }

        case .cancelled:
            vmAfter.downloadTasks[idx].status = .failed
            vmAfter.downloadTasks[idx].pill = "已停止"
            vmAfter.downloadTasks[idx].rightText = "已停止"
            vmAfter.scheduleTaskSave()

        case .failed(let pill):
            vmAfter.downloadTasks[idx].status = .failed
            vmAfter.downloadTasks[idx].pill = pill
            vmAfter.scheduleTaskSave()
        }
    }

    func startUnpack(filePath: String) {
        guard let vm = viewModel else { return }
        let normalizedPath = UnpackService.normalizeMultipartArchivePath(filePath)
        let filename = (normalizedPath as NSString).lastPathComponent

        let fileSizeStr: String = {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: normalizedPath),
               let sz = attrs[.size] as? Int64 {
                return ByteCountFormatter.string(fromByteCount: sz, countStyle: .file)
            }
            return ""
        }()

        let taskID = UUID()
        markTaskStarted(taskID)
        let newTask = StudioTask(
            id: taskID,
            title: filename,
            status: .locked(0.08),
            pill: filename.lowercased().hasPrefix("setup_") ? "GOG 解包" : "试密中",
            rightText: fileSizeStr,
            localPath: normalizedPath
        )
        vm.unpackTasks.insert(newTask, at: 0)
        vm.scheduleTaskSave()
        vm.appendLog("unpack ▸ 准备解压 \(filename)...", highlight: false)

        let candidatePasswords = [""] + vm.settingsStore.settings.passwords
        Task { [weak self] in
            await self?.runUnpackTask(taskID: taskID, archivePath: normalizedPath, candidatePasswords: candidatePasswords)
        }
    }

    func runUnpackTask(taskID: UUID, archivePath: String, candidatePasswords: [String]) async {
        guard let vm = viewModel else { return }
        let deleteAfter = vm.settingsStore.settings.deleteArchiveAfterUnpack

        let outcome = await unpackService.executeUnpack(
            taskID: taskID,
            archivePath: archivePath,
            candidatePasswords: candidatePasswords,
            deleteArchiveAfterUnpack: deleteAfter,
            onProgress: { [weak self] pct, pillOpt in
                Task { @MainActor in
                    guard let self = self,
                          self.acceptsProgress(for: taskID),
                          let vm = self.viewModel,
                          let idx = vm.unpackTasks.firstIndex(where: { $0.id == taskID }) else { return }
                    vm.unpackTasks[idx].status = .locked(pct)
                    if let p = pillOpt { vm.unpackTasks[idx].pill = p }
                }
            },
            onLog: { [weak vm] msg, hl in
                Task { @MainActor in
                    vm?.appendLog(msg, highlight: hl)
                }
            }
        )

        guard let vmAfter = viewModel,
              let idx = vmAfter.unpackTasks.firstIndex(where: { $0.id == taskID }),
              acceptsProgress(for: taskID) else { return }

        switch outcome {
        case .completed(let outDir, let baseName, let pill):
            vmAfter.unpackTasks[idx].status = .done
            vmAfter.unpackTasks[idx].pill = pill
            vmAfter.unpackTasks[idx].localPath = outDir
            vmAfter.scheduleTaskSave()

            // Silent background relay (does NOT hijack activeTab!)
            if vmAfter.settingsStore.settings.autoRelay {
                vmAfter.appendLog("relay ▸ 后台自动流转至 [补丁]: \(baseName)", highlight: true)
                startPatch(folderPath: outDir)
            }

        case .cancelled:
            vmAfter.unpackTasks[idx].status = .failed
            vmAfter.unpackTasks[idx].pill = "已停止"
            vmAfter.unpackTasks[idx].rightText = "已停止"
            vmAfter.scheduleTaskSave()

        case .failed(let pill):
            vmAfter.unpackTasks[idx].status = .failed
            vmAfter.unpackTasks[idx].pill = pill
            vmAfter.scheduleTaskSave()
        }
    }

    func startPatch(folderPath: String) {
        guard let vm = viewModel else { return }
        let gameTitle = PatchAndBottleService.cleanGameTitle(from: (folderPath as NSString).lastPathComponent)
        let taskID = UUID()
        markTaskStarted(taskID)
        let newTask = StudioTask(
            id: taskID,
            title: gameTitle,
            status: .running(0.35),
            pill: "扫描中",
            rightText: "处理中",
            localPath: folderPath,
            expanded: true
        )
        vm.patchTasks.insert(newTask, at: 0)
        vm.scheduleTaskSave()
        vm.appendLog("pe-scan ▸ 开始扫描目录与 PE 导入表: \(gameTitle)", highlight: false)

        Task { [weak self] in
            await self?.runPatchTask(taskID: taskID, folderPath: folderPath, cleanTitle: gameTitle)
        }
    }

    func runPatchTask(taskID: UUID, folderPath: String, cleanTitle: String) async {
        guard let vm = viewModel else { return }
        let settingsSnapshot = vm.settingsStore.settings

        let payload = await patchService.executePatch(
            taskID: taskID,
            folderPath: folderPath,
            cleanTitle: cleanTitle,
            settings: settingsSnapshot,
            onLog: { [weak vm] msg, hl in
                Task { @MainActor in
                    vm?.appendLog(msg, highlight: hl)
                }
            }
        )

        guard let vmAfter = viewModel,
              acceptsProgress(for: taskID),
              let idx = vmAfter.patchTasks.firstIndex(where: { $0.id == taskID }) else { return }

        vmAfter.patchTasks[idx].title = payload.displayTitle
        vmAfter.patchTasks[idx].status = .done
        vmAfter.patchTasks[idx].pill = payload.pill
        vmAfter.patchTasks[idx].rightText = payload.rightText
        vmAfter.patchTasks[idx].exePath = payload.exePath
        vmAfter.patchTasks[idx].appID = payload.appID
        vmAfter.patchTasks[idx].checklist = payload.checklist
        vmAfter.scheduleTaskSave()
    }

    func launchGame(_ task: StudioTask) {
        guard let vm = viewModel else { return }
        let bottlesDir = vm.settingsStore.settings.bottlesDirectory
        Task {
            await patchService.launchGame(task, bottlesDirectory: bottlesDir) { [weak vm] msg, hl in
                Task { @MainActor in
                    vm?.appendLog(msg, highlight: hl)
                }
            }
        }
    }
}
