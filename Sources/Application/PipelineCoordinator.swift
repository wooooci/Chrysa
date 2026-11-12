import ChrysaCore
import Foundation

package enum PipelineEvent: Sendable {
    case jobUpdated(Job)
    case jobRemoved(UUID)
    case log(LogEntry)
}

/// Runs registered workflow stages and persists their state without depending on presentation types.
@MainActor
package final class PipelineCoordinator {
    private let services: any WorkflowServices
    package let jobStore: any JobRepository
    package let events: AsyncStream<PipelineEvent>

    private let eventContinuation: AsyncStream<PipelineEvent>.Continuation
    private var cancelledTaskIDs: Set<UUID> = []
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var folderQueueOwners: Set<UUID> = []
    private var bottleScanID: UUID?

    package init(services: any WorkflowServices, jobStore: any JobRepository) {
        self.services = services
        self.jobStore = jobStore
        let stream = AsyncStream<PipelineEvent>.makeStream()
        self.events = stream.stream
        self.eventContinuation = stream.continuation
    }

    package func loadJobs(migratingLegacyStore: any LegacyTaskLoading) async -> JobStoreLoadResult {
        await jobStore.load(migratingLegacyStore: migratingLegacyStore)
    }

    package func addJob(_ job: Job) async {
        let storedJob = await jobStore.upsert(job)
        eventContinuation.yield(.jobUpdated(storedJob))
    }

    package func rescanCrossOverBottles(bottlesDirectory: String) async {
        let scanID = UUID()
        bottleScanID = scanID
        let scanned = await services.scanBottles(directory: bottlesDirectory)
        guard bottleScanID == scanID, !Task.isCancelled else { return }
        let addedCount = await addDiscoveredBottles(scanned)
        if addedCount > 0 {
            await recordLog(taskID: nil, module: .patch, level: .info, message: "容器目录扫描新增 \(addedCount) 款游戏")
        }
    }

    @discardableResult
    package func addDiscoveredBottles(_ discoveredJobs: [Job]) async -> Int {
        let existingJobs = await jobStore.all()
        var patchJobs = existingJobs.filter { $0.kind == .patch }
        var nextPosition = (patchJobs.map(\.listPosition).max() ?? -1) + 1
        var addedCount = 0

        for discoveredJob in discoveredJobs where discoveredJob.kind == .patch {
            let exists = patchJobs.contains { existing in
                existing.matchesDiscoveredPatchBottle(discoveredJob)
            }
            guard !exists else { continue }
            var job = discoveredJob
            job.listPosition = nextPosition
            job.expanded = false
            nextPosition += 1
            await jobStore.upsert(job)
            patchJobs.append(job)
            eventContinuation.yield(.jobUpdated(job))
            addedCount += 1
        }

        if !patchJobs.contains(where: \.expanded),
           let firstJob = patchJobs.min(by: Self.jobOrder) {
            await updateJob(firstJob.id, expanded: true)
        }

        return addedCount
    }

    @discardableResult
    package func updateJob(
        _ id: UUID,
        kind: JobKind? = nil,
        status: JobStatus? = nil,
        progress: Double? = nil,
        title: String? = nil,
        source: ArtifactRef? = nil,
        input: ArtifactRef? = nil,
        output: ArtifactRef? = nil,
        message: String? = nil,
        clearMessage: Bool = false,
        rightText: String? = nil,
        appID: String? = nil,
        checklist: [CheckItem]? = nil,
        isArchived: Bool? = nil,
        expanded: Bool? = nil,
        listPosition: Int? = nil
    ) async -> Job? {
        guard let job = await jobStore.update(
            id: id,
            kind: kind,
            status: status,
            progress: progress,
            title: title,
            source: source,
            input: input,
            output: output,
            message: message,
            clearMessage: clearMessage,
            rightText: rightText,
            appID: appID,
            checklist: checklist,
            isArchived: isArchived,
            expanded: expanded,
            listPosition: listPosition
        ) else { return nil }
        eventContinuation.yield(.jobUpdated(job))
        return job
    }

    package func removeJob(_ id: UUID) async {
        workers[id]?.cancel()
        cancelledTaskIDs.insert(id)
        await services.cancel(taskID: id)
        await jobStore.remove(id: id)
        workers[id] = nil
        eventContinuation.yield(.jobRemoved(id))
    }

    package func cancelTask(_ id: UUID) async {
        cancelledTaskIDs.insert(id)
        // The folder owner Task is the queue scheduler. Cancel only this file's
        // service work so remaining files in the same share can continue.
        if !folderQueueOwners.contains(id) {
            workers[id]?.cancel()
        }
        await services.cancel(taskID: id)
        await updateJob(id, status: .cancelled, message: "已停止", rightText: "已停止")
    }

    package func clearJobs(_ ids: [UUID]) async {
        for id in ids {
            await removeJob(id)
        }
    }

    package func flushJobStoreWrites() async {
        _ = await jobStore.all()
    }

    package func resolveDroppedFile(_ url: URL) async -> (kind: JobKind, path: String) {
        await services.resolveDroppedFile(url)
    }

    package func normalizeDownloadInput(_ input: String) -> String? {
        services.normalizeDownloadInput(input)
    }

    package func deleteDownloadedFile(_ path: String, downloadDirectory: String) throws -> Bool {
        try services.deleteDownloadedFile(path, downloadDirectory: downloadDirectory)
    }

    package func startDownload(urlString: String, settings: AppSettings) {
        let cleanURL = services.normalizeDownloadInput(urlString)
            ?? urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return }

        let guessedName = services.suggestedDownloadName(cleanURL)
            ?? "Download_\(Int(Date().timeIntervalSince1970)).7z"
        let initialMessage = services.initialDownloadMessage(for: cleanURL) ?? "嗅探中"
        let taskID = UUID()
        let job = Job(
            id: taskID,
            kind: .download,
            title: guessedName,
            status: .running,
            progress: 0.02,
            source: ArtifactRef(kind: .remoteURL, value: cleanURL),
            input: ArtifactRef(kind: .remoteURL, value: cleanURL),
            message: initialMessage,
            rightText: "准备中"
        )
        cancelledTaskIDs.remove(taskID)

        workers[taskID] = Task { [weak self] in
            guard let self else { return }
            defer { self.workers[taskID] = nil }
            await self.addJob(job)
            await self.recordLog(taskID: taskID, module: .download, level: .info, message: "sniff ▸ 开始解析链接: \(cleanURL)")
            let resolvedList = await self.services.resolveDownloads(cleanURL, passwords: settings.passwords)
            guard self.acceptsProgress(for: taskID) else { return }
            guard let first = resolvedList.first else {
                await self.updateJob(taskID, status: .failed, message: "解析失败", rightText: "无法获取直链")
                await self.recordLog(taskID: taskID, module: .download, level: .error, message: "无法从分享页解析出有效文件直链: \(cleanURL)")
                return
            }

            if resolvedList.count == 1 {
                await self.updateJob(taskID, title: first.suggestedFilename, message: "连接中")
                await self.recordLog(taskID: taskID, module: .download, level: .info, message: "dl ▸ 启动高速下载: \(first.suggestedFilename ?? first.finalURL)")
                await self.runDownloadTask(taskID: taskID, resolved: first, settings: settings)
            } else {
                await self.runFolderDownloadPipeline(firstTaskID: taskID, guessedName: guessedName, items: resolvedList, settings: settings)
            }
        }
    }

    package func runFolderDownloadPipeline(firstTaskID: UUID, guessedName: String, items: [ResolvedDownload], settings: AppSettings) async {
        guard let first = items.first, acceptsProgress(for: firstTaskID) else { return }
        folderQueueOwners.insert(firstTaskID)
        defer { folderQueueOwners.remove(firstTaskID) }

        let taskPairs = [(firstTaskID, first)] + items.dropFirst().map { (UUID(), $0) }
        let folderTitle = first.subDirectory ?? "多文件目录"
        await updateJob(firstTaskID, title: first.suggestedFilename ?? guessedName, message: "队列 1/\(taskPairs.count)")
        for (offset, pair) in taskPairs.dropFirst().enumerated() {
            let job = Job(
                id: pair.0,
                kind: .download,
                title: pair.1.suggestedFilename ?? "分卷文件",
                status: .queued,
                source: ArtifactRef(kind: .remoteURL, value: pair.1.originalURL),
                input: ArtifactRef(kind: .remoteURL, value: pair.1.finalURL),
                message: "队列 \(offset + 2)/\(taskPairs.count)",
                rightText: pair.1.totalSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "待下载",
                listPosition: offset + 1
            )
            cancelledTaskIDs.remove(pair.0)
            await addJob(job)
        }
        await recordLog(taskID: firstTaskID, module: .download, level: .info, message: "folder ▸ 检测到分享文件夹 [\(folderTitle)]，共 \(taskPairs.count) 个文件")
        let names = taskPairs.compactMap { $0.1.suggestedFilename }
        let primaryFile = Self.selectPrimaryArchive(from: names, isArchiveFile: services.isArchiveFile)
        let requiredBinSlices = Self.requiredCompanionVolumes(for: primaryFile, in: names)
        let primaryTaskID = primaryFile.flatMap { filename in
            taskPairs.first(where: { $0.1.suggestedFilename == filename })?.0
        }
        var completedPaths: [String: String] = [:]
        var baseUnpackTriggered = false
        var relayTask: Task<Void, Never>?
        var pendingDLCInstallers: [(taskID: UUID, filename: String, path: String)] = []

        for (taskID, rawItem) in taskPairs {
            guard acceptsProgress(for: taskID) else { continue }
            let item = await services.refreshDownload(rawItem)
            let holdsForRelay = settings.autoRelay && taskID == primaryTaskID
            await runDownloadTask(
                taskID: taskID,
                resolved: item,
                settings: settings,
                suppressAutoRelay: true,
                holdForFolderRelay: holdsForRelay,
                progressRange: holdsForRelay ? (0.0...1.0 / 3.0) : nil
            )
            guard acceptsProgress(for: taskID) else { continue }
            guard let filename = item.suggestedFilename,
                  let job = await jobStore.job(for: taskID),
                  job.status == .succeeded || (holdsForRelay && job.status == .running),
                  let output = job.output?.value, services.fileExists(output),
                  acceptsProgress(for: taskID) else { continue }
            completedPaths[filename] = output

            if !baseUnpackTriggered,
               let primaryFile,
               let primaryPath = completedPaths[primaryFile],
               requiredBinSlices.isSubset(of: Set(completedPaths.keys)) {
                baseUnpackTriggered = true
                let hasRemainingDLCs = completedPaths.count < taskPairs.count
                if settings.autoRelay {
                    let detail = hasRemainingDLCs ? " (DLC 继续下载)" : ""
                    await recordLog(taskID: primaryTaskID ?? firstTaskID, module: .unpack, level: .info, message: "relay ▸ 主文件与分卷已就绪，自动流转至解压: \(primaryFile)\(detail)")
                    guard let primaryTaskID,
                          await prepareUnpackStage(taskID: primaryTaskID, archivePath: primaryPath, progress: 1.0 / 3.0) else {
                        continue
                    }
                    let relayID = primaryTaskID
                    relayTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.runUnpackTask(
                            taskID: relayID,
                            archivePath: primaryPath,
                            candidatePasswords: [""] + settings.passwords,
                            settings: settings,
                            progressRange: (1.0 / 3.0...2.0 / 3.0)
                        )
                    }
                }
            } else if baseUnpackTriggered,
                      filename.lowercased().hasPrefix("setup_"), filename.lowercased().hasSuffix(".exe") {
                pendingDLCInstallers.append((taskID: taskID, filename: filename, path: output))
            }
        }

        if let relayTask {
            await relayTask.value
        } else if settings.autoRelay, let primaryTaskID,
                  let primaryJob = await jobStore.job(for: primaryTaskID),
                  primaryJob.kind == .download, primaryJob.status == .running,
                  primaryJob.output != nil, acceptsProgress(for: primaryTaskID) {
            await updateJob(primaryTaskID, status: .succeeded, progress: 1, clearMessage: true)
        }

        if !pendingDLCInstallers.isEmpty,
           let primaryFile,
           let primaryPath = completedPaths[primaryFile] {
            let primaryJob = primaryTaskID != nil ? await jobStore.job(for: primaryTaskID!) : nil
            let unpackedDir: String = {
                if let input = primaryJob?.input, input.kind == .directory { return input.value }
                if let output = primaryJob?.output, output.kind == .directory { return output.value }
                var rawBase = ((primaryPath as NSString).lastPathComponent as NSString).deletingPathExtension
                if rawBase.lowercased().hasPrefix("setup_") { rawBase = String(rawBase.dropFirst("setup_".count)) }
                return ((primaryPath as NSString).deletingLastPathComponent as NSString)
                    .appendingPathComponent(GameTitle.cleanGameTitle(from: rawBase))
            }()
            for dlc in pendingDLCInstallers where acceptsProgress(for: dlc.taskID) {
                await recordLog(taskID: primaryTaskID ?? dlc.taskID, module: .unpack, level: .info, message: "innoextract ▸ 正在合并 DLC: \(dlc.filename)")
                let merged = await services.mergeDLC(installer: dlc.path, directory: unpackedDir, taskID: dlc.taskID)
                if merged {
                    await recordLog(taskID: primaryTaskID ?? dlc.taskID, module: .unpack, level: .info, message: "innoextract ▸ DLC 合并完成: \(dlc.filename)")
                }
            }
        }
    }

    private static func selectPrimaryArchive(from names: [String], isArchiveFile: (String) -> Bool) -> String? {
        names.first { name in
            guard isArchiveFile(name) else { return false }
            let lower = name.lowercased()
            if lower.hasSuffix(".bin") { return false }
            if let rarRegex = try? NSRegularExpression(pattern: #"\.part([0-9]+)\.rar$"#, options: .caseInsensitive),
               let match = rarRegex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
               let numRange = Range(match.range(at: 1), in: lower),
               Int(lower[numRange]) != 1 {
                return false
            }
            return true
        } ?? names.first(where: isArchiveFile)
    }

    private static func requiredCompanionVolumes(for primaryFile: String?, in names: [String]) -> Set<String> {
        guard let primaryFile else { return [] }
        let lowerPrimary = primaryFile.lowercased()
        let primaryBase = ((primaryFile as NSString).deletingPathExtension).lowercased()
        var required: Set<String> = []

        for name in names {
            let lower = name.lowercased()
            // 1. GOG Inno Setup companion data slices: setup_xxx-1.bin
            if lower.hasPrefix(primaryBase + "-") && lower.hasSuffix(".bin") {
                required.insert(name)
            }
            // 2. Split .7z volumes: game.7z.001, game.7z.002, ...
            if lowerPrimary.hasSuffix(".7z.001") {
                let prefix = String(lowerPrimary.dropLast(3))
                if lower.hasPrefix(prefix),
                   lower.range(of: #"\.[0-9]{3}$"#, options: .regularExpression) != nil {
                    required.insert(name)
                }
            }
            // 3. Multipart RAR volumes: game.part1.rar, game.part2.rar, ...
            if let rarMatch = try? NSRegularExpression(pattern: #"^(.+)\.part0*1\.rar$"#, options: .caseInsensitive)
                .firstMatch(in: primaryFile, range: NSRange(primaryFile.startIndex..., in: primaryFile)),
               let prefixRange = Range(rarMatch.range(at: 1), in: primaryFile) {
                let basePrefix = String(primaryFile[prefixRange]).lowercased() + ".part"
                if lower.hasPrefix(basePrefix) && lower.hasSuffix(".rar") {
                    required.insert(name)
                }
            }
        }
        return required
    }

    package func runDownloadTask(
        taskID: UUID,
        resolved: ResolvedDownload,
        settings: AppSettings,
        suppressAutoRelay: Bool = false,
        holdForFolderRelay: Bool = false,
        progressRange: ClosedRange<Double>? = nil
    ) async {
        guard let job = await jobStore.job(for: taskID), job.kind == .download,
              job.status == .queued || job.status == .running,
              acceptsProgress(for: taskID) else { return }
        let currentTitle = job.title.isEmpty ? (resolved.suggestedFilename ?? "Download") : job.title
        await updateJob(
            taskID,
            status: .running,
            title: currentTitle,
            input: ArtifactRef(kind: .remoteURL, value: resolved.finalURL)
        )
        let stage = services.downloadStage(title: currentTitle, resolved: resolved, settings: settings)
        let result = await execute(
            registry: StageRegistry(stages: [stage]),
            stageID: stage.id,
            jobID: taskID,
            module: .download,
            input: ArtifactRef(kind: .remoteURL, value: resolved.finalURL),
            progressRange: progressRange ?? (settings.autoRelay && !suppressAutoRelay ? (0.0...1.0 / 3.0) : nil)
        )
        guard acceptsProgress(for: taskID) else { return }

        switch result {
        case .success(let output):
            let finalTitle = output.metadata["title"] ?? currentTitle
            let rightText = output.metadata["rightText"]
            let outputPath = output.artifact?.value
            let shouldRelay = !suppressAutoRelay && settings.autoRelay
                && outputPath.map(services.isArchiveFile) == true
            if shouldRelay, let outputArtifact = output.artifact, let outputPath {
                let filename = (outputPath as NSString).lastPathComponent
                guard let transitioned = await updateJob(
                    taskID,
                    kind: .unpack,
                    status: .running,
                    progress: 1.0 / 3.0,
                    title: filename,
                    input: outputArtifact,
                    output: outputArtifact,
                    message: filename.lowercased().hasPrefix("setup_") ? "GOG 解包" : "试密中",
                    rightText: services.fileSize(outputPath)
                        .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? rightText ?? ""
                ), transitioned.status == .running, acceptsProgress(for: taskID) else { return }
                await recordLog(taskID: taskID, module: .unpack, level: .info, message: "relay ▸ 自动流转至解压: \(finalTitle)")
                await runUnpackTask(
                    taskID: taskID,
                    archivePath: outputPath,
                    candidatePasswords: [""] + settings.passwords,
                    settings: settings,
                    progressRange: (1.0 / 3.0...2.0 / 3.0)
                )
                return
            }

            if holdForFolderRelay {
                await updateJob(
                    taskID,
                    status: .running,
                    progress: progressRange?.upperBound ?? 1.0 / 3.0,
                    title: finalTitle,
                    output: output.artifact,
                    clearMessage: true,
                    rightText: rightText
                )
                return
            }
            let completed = await updateJob(
                taskID,
                status: .succeeded,
                progress: 1,
                title: finalTitle,
                output: output.artifact,
                clearMessage: true,
                rightText: rightText
            )
            guard completed?.status == .succeeded, acceptsProgress(for: taskID) else { return }
        case .cancelled:
            await updateJob(taskID, status: .cancelled, message: "已停止", rightText: "已停止")
        case .failure(let failure):
            await updateJob(taskID, status: .failed, message: failure.message)
        }
    }

    package func startUnpack(filePath: String, settings: AppSettings) {
        let archivePath = services.normalizeArchivePath(filePath)
        let filename = (archivePath as NSString).lastPathComponent
        let fileSize = services.fileSize(archivePath)
            .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        let taskID = UUID()
        let job = Job(
            id: taskID,
            kind: .unpack,
            title: filename,
            status: .running,
            progress: 0.08,
            source: ArtifactRef(kind: .file, value: archivePath),
            input: ArtifactRef(kind: .file, value: archivePath),
            message: filename.lowercased().hasPrefix("setup_") ? "GOG 解包" : "试密中",
            rightText: fileSize
        )
        cancelledTaskIDs.remove(taskID)
        workers[taskID] = Task { [weak self] in
            guard let self else { return }
            await self.addJob(job)
            await self.recordLog(taskID: taskID, module: .unpack, level: .info, message: "unpack ▸ 准备解压 \(filename)")
            await self.runUnpackTask(taskID: taskID, archivePath: archivePath, candidatePasswords: [""] + settings.passwords, settings: settings)
            self.workers[taskID] = nil
        }
    }

    private func prepareUnpackStage(taskID: UUID, archivePath: String, progress: Double) async -> Bool {
        let filename = (archivePath as NSString).lastPathComponent
        let fileSize = services.fileSize(archivePath)
            .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        guard let updated = await updateJob(
            taskID,
            kind: .unpack,
            status: .running,
            progress: progress,
            title: filename,
            input: ArtifactRef(kind: .file, value: archivePath),
            message: filename.lowercased().hasPrefix("setup_") ? "GOG 解包" : "试密中",
            rightText: fileSize
        ) else { return false }
        return updated.status == .running && acceptsProgress(for: taskID)
    }

    package func runUnpackTask(
        taskID: UUID,
        archivePath: String,
        candidatePasswords: [String],
        settings: AppSettings,
        progressRange: ClosedRange<Double>? = nil
    ) async {
        guard let job = await jobStore.job(for: taskID), job.kind == .unpack,
              job.status == .queued || job.status == .running,
              acceptsProgress(for: taskID) else { return }
        await updateJob(taskID, status: .running)
        let stage = services.unpackStage(passwords: candidatePasswords, deleteArchive: settings.deleteArchiveAfterUnpack)
        let result = await execute(
            registry: StageRegistry(stages: [stage]),
            stageID: stage.id,
            jobID: taskID,
            module: .unpack,
            input: ArtifactRef(kind: .file, value: archivePath),
            progressRange: progressRange ?? (settings.autoRelay ? (0.0...0.5) : nil)
        )
        guard acceptsProgress(for: taskID) else { return }

        switch result {
        case .success(let output):
            let outputPath = output.artifact?.value
            if settings.autoRelay, let outputPath, let outputArtifact = output.artifact {
                let title = GameTitle.cleanGameTitle(from: output.metadata["title"] ?? (outputPath as NSString).lastPathComponent)
                let nextProgress = progressRange?.upperBound ?? 0.5
                guard let transitioned = await updateJob(
                    taskID,
                    kind: .patch,
                    status: .running,
                    progress: nextProgress,
                    title: title,
                    input: outputArtifact,
                    output: outputArtifact,
                    message: "扫描中",
                    rightText: "处理中",
                    expanded: true
                ), transitioned.status == .running, acceptsProgress(for: taskID) else { return }
                await recordLog(taskID: taskID, module: .patch, level: .info, message: "relay ▸ 自动流转至补丁: \(title)")
                await runPatchTask(
                    taskID: taskID,
                    folderPath: outputPath,
                    cleanTitle: title,
                    settings: settings,
                    progressRange: (nextProgress...1.0)
                )
                return
            }
            let completed = await updateJob(
                taskID,
                status: .succeeded,
                progress: 1,
                output: output.artifact,
                message: output.metadata["message"]
            )
            guard completed?.status == .succeeded, acceptsProgress(for: taskID) else { return }
        case .cancelled:
            await updateJob(taskID, status: .cancelled, message: "已停止", rightText: "已停止")
        case .failure(let failure):
            await updateJob(taskID, status: .failed, message: failure.message)
        }
    }

    package func startPatch(folderPath: String, settings: AppSettings) {
        let title = GameTitle.cleanGameTitle(from: (folderPath as NSString).lastPathComponent)
        let taskID = UUID()
        let job = Job(
            id: taskID,
            kind: .patch,
            title: title,
            status: .running,
            progress: 0.35,
            source: ArtifactRef(kind: .directory, value: folderPath),
            input: ArtifactRef(kind: .directory, value: folderPath),
            message: "扫描中",
            rightText: "处理中",
            expanded: true
        )
        cancelledTaskIDs.remove(taskID)
        workers[taskID] = Task { [weak self] in
            guard let self else { return }
            await self.addJob(job)
            await self.recordLog(taskID: taskID, module: .patch, level: .info, message: "pe-scan ▸ 开始扫描目录与 PE 导入表: \(title)")
            await self.runPatchTask(taskID: taskID, folderPath: folderPath, cleanTitle: title, settings: settings)
            self.workers[taskID] = nil
        }
    }

    package func runPatchTask(
        taskID: UUID,
        folderPath: String,
        cleanTitle: String,
        settings: AppSettings,
        progressRange: ClosedRange<Double>? = nil
    ) async {
        guard let job = await jobStore.job(for: taskID), job.kind == .patch,
              job.status == .queued || job.status == .running,
              acceptsProgress(for: taskID) else { return }
        await updateJob(taskID, status: .running)
        let stage = services.patchStage(title: cleanTitle, settings: settings)
        let result = await execute(
            registry: StageRegistry(stages: [stage]),
            stageID: stage.id,
            jobID: taskID,
            module: .patch,
            input: ArtifactRef(kind: .directory, value: folderPath),
            progressRange: progressRange
        )
        guard acceptsProgress(for: taskID) else { return }
        switch result {
        case .success(let output):
            await updateJob(
                taskID,
                status: .succeeded,
                progress: 1,
                title: output.metadata["title"],
                output: output.artifact,
                message: output.metadata["message"],
                rightText: output.metadata["rightText"],
                appID: output.metadata["appID"],
                checklist: output.checklist
            )
        case .cancelled:
            await updateJob(taskID, status: .cancelled, message: "已停止", rightText: "已停止")
        case .failure(let failure):
            await updateJob(taskID, status: .failed, message: failure.message)
        }
    }

    package func launchGame(_ job: Job, settings: AppSettings) {
        guard job.kind == .patch, job.status == .succeeded, workers[job.id] == nil else { return }
        let taskID = job.id
        cancelledTaskIDs.remove(taskID)
        workers[taskID] = Task { [weak self] in
            guard let self else { return }
            defer { self.workers[taskID] = nil }
            await self.services.clearCancellation(taskID: taskID)
            guard let storedJob = await self.jobStore.job(for: taskID),
                  storedJob.kind == .patch, storedJob.status == .succeeded,
                  self.acceptsProgress(for: taskID) else { return }
            let request = GameLaunchRequest(job: storedJob, bottlesDirectory: settings.bottlesDirectory)
            let stage = self.services.launchStage(request: request)
            _ = await self.execute(
                registry: StageRegistry(stages: [stage]),
                stageID: stage.id,
                jobID: taskID,
                module: .launch,
                input: storedJob.output
            )
        }
    }

    private func execute(
        registry: StageRegistry,
        stageID: StageID,
        jobID: UUID,
        module: LogModule,
        input: ArtifactRef?,
        progressRange: ClosedRange<Double>? = nil
    ) async -> StageResult {
        let context = StageContext(
            jobID: jobID,
            input: input,
            reportProgress: { [weak self] progress in
                await self?.report(progress, for: jobID, progressRange: progressRange)
            },
            log: { [weak self] stageLog in
                await self?.recordLog(
                    taskID: jobID,
                    module: module,
                    level: stageLog.level,
                    message: stageLog.message,
                    rawOutput: stageLog.rawOutput
                )
            },
            isCancelled: { [weak self] in
                await self?.isCancelled(jobID) ?? true
            }
        )
        return await registry.execute(stageID, context: context)
    }

    private func report(_ progress: StageProgress, for id: UUID, progressRange: ClosedRange<Double>?) async {
        guard acceptsProgress(for: id) else { return }
        let fraction = progress.fraction.map { stageFraction in
            progressRange.map { range in
                range.lowerBound + (range.upperBound - range.lowerBound) * stageFraction
            } ?? stageFraction
        }
        await updateJob(id, status: .running, progress: fraction, message: progress.message, rightText: progress.detail)
    }

    private func isCancelled(_ id: UUID) -> Bool {
        cancelledTaskIDs.contains(id) || Task.isCancelled
    }

    private func acceptsProgress(for id: UUID) -> Bool {
        !cancelledTaskIDs.contains(id)
    }

    private func recordLog(
        taskID: UUID?,
        module: LogModule,
        level: LogLevel,
        message: String,
        rawOutput: String? = nil
    ) async {
        let entry = LogEntry(
            taskID: taskID,
            module: module,
            level: level,
            message: message,
            rawOutput: rawOutput
        )
        if let taskID, let updatedJob = await jobStore.appendLog(entry, to: taskID) {
            eventContinuation.yield(.jobUpdated(updatedJob))
        }
        eventContinuation.yield(.log(entry))
    }
    private static func jobOrder(_ lhs: Job, _ rhs: Job) -> Bool {
        if lhs.listPosition != rhs.listPosition { return lhs.listPosition < rhs.listPosition }
        if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
        return lhs.createdAt > rhs.createdAt
    }
}
