import ChrysaCore
import Foundation

package enum PipelineEvent: Sendable {
    case jobUpdated(Job)
    case jobRemoved(UUID)
    case launchGameUpdated(LaunchGame)
    case launchGameRemoved(UUID)
    case launchFailed(gameID: UUID, title: String, message: String)
    case log(LogEntry)
}

/// Runs registered workflow stages and persists their state without depending on presentation types.
@MainActor
package final class PipelineCoordinator {
    private let services: any WorkflowServices
    package let jobStore: any JobRepository
    package let gameLibrary: any LaunchGameRepository
    package let events: AsyncStream<PipelineEvent>
    private let eventContinuation: AsyncStream<PipelineEvent>.Continuation
    private var cancelledTaskIDs: Set<UUID> = []
    private var pausedTaskIDs: Set<UUID> = []
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var activePartTokensByJob: [UUID: Set<UUID>] = [:]
    private var livePartsByJob: [UUID: [DownloadPart]] = [:]
    private var activeDownloadTokens: Set<UUID> = []
    private var downloadWaiters: [(token: UUID, ownerJobID: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    private var maxConcurrentDownloads: Int = 2
    private var lastDownloadDirectory: String?
    private var bottleScanID: UUID?
    private var activeSleepTokens: [UUID: UUID] = [:]
    private var isIdleSleepPrevented = false

    package init(
        services: any WorkflowServices,
        jobStore: any JobRepository,
        gameLibrary: any LaunchGameRepository = InMemoryLaunchGameRepository()
    ) {
        self.services = services
        self.jobStore = jobStore
        self.gameLibrary = gameLibrary
        let stream = AsyncStream<PipelineEvent>.makeStream()
        self.events = stream.stream
        self.eventContinuation = stream.continuation
    }
    package func loadJobs(migratingLegacyStore: any LegacyTaskLoading) async -> JobStoreLoadResult {
        await jobStore.load(migratingLegacyStore: migratingLegacyStore)
    }

    package func loadLaunchLibrary() async -> LaunchGameStoreLoadResult {
        await gameLibrary.load()
    }

    package func migrateLegacyPatchEntriesToLaunchLibrary() async {
        let allJobs = await jobStore.all()
        let migratedAlready = await gameLibrary.isLegacyJobMigrationCompleted()

        for job in allJobs where job.kind == .patch {
            if job.isScannerDiscoveredPatch {
                let bottleName = Self.extractBottleName(from: job.checklist) ?? job.title
                let game = LaunchGame(
                    title: job.title,
                    exePath: job.exePath,
                    gameDirectory: job.localPath,
                    bottleName: bottleName,
                    appID: job.appID,
                    source: .crossoverScan,
                    addedAt: job.createdAt,
                    updatedAt: job.updatedAt
                )
                let stored = await gameLibrary.upsert(game, preferIncomingMetadata: false)
                eventContinuation.yield(.launchGameUpdated(stored))
                await jobStore.remove(id: job.id)
                eventContinuation.yield(.jobRemoved(job.id))
            } else if !migratedAlready, job.status == .succeeded, job.exePath != nil {
                let game = LaunchGame(
                    title: job.title,
                    exePath: job.exePath,
                    gameDirectory: job.localPath,
                    bottleName: nil,
                    appID: job.appID,
                    source: .patchPipeline,
                    addedAt: job.createdAt,
                    updatedAt: job.updatedAt
                )
                let stored = await gameLibrary.upsert(game, preferIncomingMetadata: false)
                eventContinuation.yield(.launchGameUpdated(stored))
            }
        }

        if !migratedAlready {
            await gameLibrary.markLegacyJobMigrationCompleted()
        }
    }

    private static func extractBottleName(from checklist: [CheckItem]) -> String? {
        for item in checklist {
            guard let start = item.title.range(of: "CrossOver 容器 [") else { continue }
            let after = item.title[start.upperBound...]
            if let end = after.firstIndex(of: "]") {
                let name = String(after[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    package func addJob(_ job: Job) async {
        let storedJob = await jobStore.upsert(job)
        eventContinuation.yield(.jobUpdated(storedJob))
    }

    package func rescanCrossOverBottles(bottlesDirectory: String, includePreviouslyRemoved: Bool = false) async {
        let scanID = UUID()
        bottleScanID = scanID
        if includePreviouslyRemoved {
            await gameLibrary.clearAllSuppressions()
        }
        let scanned = await services.scanBottles(directory: bottlesDirectory)
        guard bottleScanID == scanID, !Task.isCancelled else { return }
        let addedCount = await addDiscoveredLaunchGames(scanned)
        if addedCount > 0 {
            await recordLog(taskID: nil, module: .launch, level: .info, message: "容器目录扫描新增 \(addedCount) 款游戏")
        }
    }

    @discardableResult
    package func addDiscoveredLaunchGames(_ discoveredGames: [LaunchGame]) async -> Int {
        let existingGames = await gameLibrary.all()
        var knownGames = existingGames
        var addedCount = 0

        for candidate in discoveredGames {
            if await gameLibrary.isSuppressed(candidate) {
                continue
            }
            if let match = knownGames.first(where: { $0.matches(candidate) }) {
                let updated = await gameLibrary.upsert(candidate, preferIncomingMetadata: false)
                if updated != match {
                    if let idx = knownGames.firstIndex(where: { $0.id == updated.id }) {
                        knownGames[idx] = updated
                    }
                    eventContinuation.yield(.launchGameUpdated(updated))
                }
            } else {
                let stored = await gameLibrary.upsert(candidate, preferIncomingMetadata: false)
                knownGames.append(stored)
                eventContinuation.yield(.launchGameUpdated(stored))
                addedCount += 1
            }
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

    package func updateMaxConcurrentDownloads(_ limit: Int) {
        maxConcurrentDownloads = DownloadSettings.clampedConcurrentDownloads(limit)
        drainDownloadWaiters()
    }

    package func removeJob(_ id: UUID, downloadDirectory: String? = nil) async {
        workers[id]?.cancel()
        cancelledTaskIDs.insert(id)
        pausedTaskIDs.remove(id)
        cancelDownloadWaiters(ownerJobID: id)
        livePartsByJob.removeValue(forKey: id)
        if let partTokens = activePartTokensByJob.removeValue(forKey: id) {
            for token in partTokens {
                await services.cancel(taskID: token)
                releaseDownloadSlot(token: token)
            }
        }
        await services.cancel(taskID: id)
        releaseDownloadSlot(token: id)
        clearSleepAssertions(for: id)
        if let dir = downloadDirectory ?? lastDownloadDirectory {
            services.cleanupStaging(for: id, downloadDirectory: dir)
        }
        await jobStore.remove(id: id)
        workers[id] = nil
        eventContinuation.yield(.jobRemoved(id))
    }

    package func pauseTask(_ id: UUID) async {
        guard let job = await jobStore.job(for: id), job.kind == .download else {
            await cancelTask(id)
            return
        }
        pausedTaskIDs.insert(id)
        workers[id]?.cancel()
        cancelDownloadWaiters(ownerJobID: id)
        if let partTokens = activePartTokensByJob[id] {
            for token in partTokens {
                await services.cancel(taskID: token)
                releaseDownloadSlot(token: token)
            }
        }
        await services.cancel(taskID: id)
        releaseDownloadSlot(token: id)
        clearSleepAssertions(for: id)

        if var parts = livePartsByJob[id] ?? job.downloadParts, !parts.isEmpty {
            for idx in parts.indices where parts[idx].status == .running || parts[idx].status == .queued {
                parts[idx].status = .paused
                parts[idx].speedBytesPerSec = 0
                parts[idx].message = "已暂停"
            }
            livePartsByJob[id] = parts
            _ = await jobStore.updateDownloadMetadata(id: id, passwordHint: job.passwordHint, downloadParts: parts)
            await updateJob(
                id,
                status: .paused,
                message: "已暂停",
                rightText: Self.formatAggregatedRightText(parts: parts)
            )
        } else {
            await updateJob(id, status: .paused, message: "已暂停")
        }
    }

    package func cancelTask(_ id: UUID, downloadDirectory: String? = nil) async {
        cancelledTaskIDs.insert(id)
        pausedTaskIDs.remove(id)
        workers[id]?.cancel()
        cancelDownloadWaiters(ownerJobID: id)
        if let partTokens = activePartTokensByJob.removeValue(forKey: id) {
            for token in partTokens {
                await services.cancel(taskID: token)
                releaseDownloadSlot(token: token)
            }
        }
        await services.cancel(taskID: id)
        releaseDownloadSlot(token: id)
        clearSleepAssertions(for: id)
        if let dir = downloadDirectory ?? lastDownloadDirectory {
            services.cleanupStaging(for: id, downloadDirectory: dir)
        }
        if let job = await jobStore.job(for: id), var parts = livePartsByJob[id] ?? job.downloadParts, !parts.isEmpty {
            for idx in parts.indices where parts[idx].status != .succeeded {
                parts[idx].status = .cancelled
                parts[idx].speedBytesPerSec = 0
                parts[idx].message = "已停止"
            }
            livePartsByJob[id] = parts
            _ = await jobStore.updateDownloadMetadata(id: id, passwordHint: job.passwordHint, downloadParts: parts)
        }
        livePartsByJob.removeValue(forKey: id)
        await updateJob(id, status: .cancelled, message: "已停止", rightText: "已停止")
    }
    package func clearJobs(_ ids: [UUID], downloadDirectory: String? = nil) async {
        for id in ids {
            await removeJob(id, downloadDirectory: downloadDirectory)
        }
    }

    package func flushJobStoreWrites() async {
        _ = await jobStore.all()
        _ = await gameLibrary.all()
    }

    package func resolveDroppedFile(_ url: URL) async -> (kind: JobKind, path: String) {
        await services.resolveDroppedFile(url)
    }

    package func normalizeDownloadInput(_ input: String) -> String? {
        services.normalizeDownloadInput(input)
    }

    package func containsValidDownloadURL(_ raw: String) -> Bool {
        let parsed = DownloadInputParser.parse(raw, knownBareDomains: services.knownBareHostDomains())
        return !parsed.urls.isEmpty || services.normalizeDownloadInput(raw) != nil
    }

    package func deleteDownloadedFile(_ path: String, downloadDirectory: String) throws -> Bool {
        try services.deleteDownloadedFile(path, downloadDirectory: downloadDirectory)
    }

    package func startDownload(urlString: String, settings: AppSettings) {
        startDownloads(rawInput: urlString, settings: settings)
    }

    package func startDownloads(rawInput: String, settings: AppSettings) {
        lastDownloadDirectory = settings.download.downloadDirectory
        updateMaxConcurrentDownloads(settings.download.maxConcurrentDownloads)

        let bareDomains = services.knownBareHostDomains()
        let parsed = DownloadInputParser.parse(rawInput, knownBareDomains: bareDomains)
        let passwordHint = parsed.primaryPassword

        let urls: [String]
        let mirrorGroups = parsed.mirrorGroups
        if !parsed.urls.isEmpty {
            urls = parsed.urls
        } else if let single = services.normalizeDownloadInput(rawInput) {
            urls = [single]
        } else {
            let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let lower = trimmed.lowercased()
            if lower.hasPrefix("magnet:") || lower.hasSuffix(".torrent") {
                Task {
                    await recordLog(taskID: nil, module: .download, level: .warning, message: "不支持 .torrent 种子或 magnet 链接")
                }
            }
            return
        }

        if urls.count == 1 {
            launchSingleInputURL(
                urls[0],
                mirrorURLs: mirrorGroups[urls[0]] ?? [],
                passwordHint: passwordHint,
                settings: settings
            )
            return
        }

        launchMultiInputURLs(
            urls,
            mirrorGroups: mirrorGroups,
            passwordHint: passwordHint,
            settings: settings
        )
    }

    private func launchSingleInputURL(
        _ cleanURL: String,
        mirrorURLs: [String] = [],
        passwordHint: String?,
        settings: AppSettings
    ) {
        let guessedName = services.suggestedDownloadName(cleanURL)
            ?? "Download_\(Int(Date().timeIntervalSince1970)).7z"
        let initialMessage = services.initialDownloadMessage(for: cleanURL) ?? "解析中"
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
            rightText: "准备中",
            passwordHint: passwordHint,
            mirrorURLs: mirrorURLs
        )
        cancelledTaskIDs.remove(taskID)
        pausedTaskIDs.remove(taskID)

        workers[taskID] = Task { [weak self] in
            guard let self else { return }
            let sleepToken = self.beginSleepAssertion(for: taskID)
            defer {
                self.endSleepAssertion(token: sleepToken)
                self.workers[taskID] = nil
            }
            await self.services.clearCancellation(taskID: taskID)
            await self.addJob(job)
            if let passwordHint, !passwordHint.isEmpty {
                await self.recordLog(taskID: taskID, module: .download, level: .info, message: "已绑定文本中的解压密码")
            }
            await self.recordLog(taskID: taskID, module: .download, level: .info, message: "解析链接: \(cleanURL)")
            let passwords = Self.candidatePasswords(hint: passwordHint, settings: settings)
            let resolvedOutcome = await self.resolveWithMirrors(
                cleanURL,
                extraMirrors: mirrorURLs,
                passwords: passwords,
                settings: settings,
                taskID: taskID
            )
            let resolution = resolvedOutcome.result
            guard self.acceptsProgress(for: taskID), !self.pausedTaskIDs.contains(taskID) else { return }

            guard let first = resolution.downloads.first else {
                let reason = resolution.failureReason ?? "无法获取直链"
                await self.updateJob(taskID, status: .failed, message: reason, rightText: "解析失败")
                await self.recordLog(
                    taskID: taskID,
                    module: .download,
                    level: .error,
                    message: "解析直链失败 (\(reason)): \(cleanURL)",
                    rawOutput: resolution.diagnostic
                )
                return
            }

            if resolution.downloads.count == 1 {
                let displayName = first.suggestedFilename ?? guessedName
                let resolvedRef = ArtifactRef(kind: .remoteURL, value: resolvedOutcome.usedOriginURL)
                _ = await self.jobStore.updateDownloadMetadata(
                    id: taskID,
                    passwordHint: passwordHint,
                    downloadParts: nil,
                    mirrorURLs: first.mirrorURLs
                )
                await self.updateJob(taskID, title: displayName, source: resolvedRef, message: "排队中")
                await self.recordLog(taskID: taskID, module: .download, level: .info, message: "开始下载: \(first.suggestedFilename ?? first.finalURL)")
                await self.runDownloadTask(taskID: taskID, resolved: first, settings: settings)
            } else {
                await self.runFolderDownloadPipeline(firstTaskID: taskID, guessedName: guessedName, items: resolution.downloads, settings: settings)
            }
        }
    }

    private func launchMultiInputURLs(
        _ urls: [String],
        mirrorGroups: [String: [String]] = [:],
        passwordHint: String?,
        settings: AppSettings
    ) {
        let taskID = UUID()
        let initialJob = Job(
            id: taskID,
            kind: .download,
            title: "正在解析 \(urls.count) 个链接...",
            status: .running,
            progress: 0.02,
            source: ArtifactRef(kind: .remoteURL, value: urls[0]),
            input: ArtifactRef(kind: .remoteURL, value: urls[0]),
            message: "解析 0/\(urls.count)",
            rightText: "准备中",
            passwordHint: passwordHint
        )
        cancelledTaskIDs.remove(taskID)
        pausedTaskIDs.remove(taskID)

        workers[taskID] = Task { [weak self] in
            guard let self else { return }
            let sleepToken = self.beginSleepAssertion(for: taskID)
            defer {
                self.endSleepAssertion(token: sleepToken)
                self.workers[taskID] = nil
            }
            await self.services.clearCancellation(taskID: taskID)
            await self.addJob(initialJob)
            if let passwordHint, !passwordHint.isEmpty {
                await self.recordLog(taskID: taskID, module: .download, level: .info, message: "已绑定文本中的解压密码")
            }
            await self.recordLog(taskID: taskID, module: .download, level: .info, message: "批量解析 \(urls.count) 个链接")

            let passwords = Self.candidatePasswords(hint: passwordHint, settings: settings)
            var resolvedByIndex: [(Int, HostResolutionResult)] = []
            await withTaskGroup(of: (Int, HostResolutionResult).self) { group in
                for (idx, url) in urls.enumerated() {
                    let mirrors = mirrorGroups[url] ?? []
                    group.addTask {
                        let outcome = await self.resolveWithMirrors(
                            url,
                            extraMirrors: mirrors,
                            passwords: passwords,
                            settings: settings,
                            taskID: taskID
                        )
                        return (idx, outcome.result)
                    }
                }
                var completed = 0
                for await pair in group {
                    resolvedByIndex.append(pair)
                    completed += 1
                    if self.acceptsProgress(for: taskID), !self.pausedTaskIDs.contains(taskID) {
                        await self.updateJob(taskID, message: "解析 \(completed)/\(urls.count)")
                    }
                }
            }
            guard self.acceptsProgress(for: taskID), !self.pausedTaskIDs.contains(taskID) else { return }

            resolvedByIndex.sort { $0.0 < $1.0 }
            var allDownloads: [ResolvedDownload] = []
            var failures: [String] = []
            for (_, res) in resolvedByIndex {
                if res.downloads.isEmpty {
                    if let reason = res.failureReason { failures.append(reason) }
                } else {
                    allDownloads.append(contentsOf: res.downloads)
                }
            }

            guard !allDownloads.isEmpty else {
                let reason = failures.first ?? "解析失败"
                await self.updateJob(taskID, status: .failed, message: reason, rightText: "解析失败")
                return
            }

            let (coalescedDownloads, coalescedCount) = Self.coalesceMirrorDownloads(allDownloads)
            if coalescedCount > 0 {
                await self.recordLog(taskID: taskID, module: .download, level: .info, message: "已关联 \(coalescedCount) 组备选镜像")
            }

            let groupInputs = coalescedDownloads.map { item in
                MultipartGroupItem(
                    url: item.originalURL,
                    filename: item.suggestedFilename ?? DownloadInputParser.inferFilenameFromURL(item.finalURL),
                    subDirectory: item.subDirectory,
                    mirrorURLs: item.mirrorURLs
                )
            }
            let groups = DownloadInputParser.groupMultipartItems(groupInputs)
            var resolvedLookup: [String: [ResolvedDownload]] = [:]
            for dl in coalescedDownloads {
                resolvedLookup[dl.originalURL, default: []].append(dl)
            }

            var groupedResolved: [(title: String, items: [ResolvedDownload])] = []
            for group in groups {
                var groupItems: [ResolvedDownload] = []
                for gi in group.items {
                    if var arr = resolvedLookup[gi.url], !arr.isEmpty {
                        groupItems.append(arr.removeFirst())
                        resolvedLookup[gi.url] = arr
                    }
                }
                if !groupItems.isEmpty {
                    groupedResolved.append((title: group.title, items: groupItems))
                }
            }

            guard let firstGroup = groupedResolved.first else { return }

            for extraGroup in groupedResolved.dropFirst() {
                let extraID = UUID()
                let firstExtra = extraGroup.items[0]
                if extraGroup.items.count == 1 {
                    let extraJob = Job(
                        id: extraID,
                        kind: .download,
                        title: firstExtra.suggestedFilename ?? extraGroup.title,
                        status: .queued,
                        progress: 0.02,
                        source: ArtifactRef(kind: .remoteURL, value: firstExtra.originalURL),
                        input: ArtifactRef(kind: .remoteURL, value: firstExtra.finalURL),
                        message: "排队中",
                        rightText: firstExtra.totalSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "待下载",
                        passwordHint: passwordHint,
                        mirrorURLs: firstExtra.mirrorURLs
                    )
                    await self.addJob(extraJob)
                    self.workers[extraID] = Task { [weak self] in
                        guard let self else { return }
                        let extraSleep = self.beginSleepAssertion(for: extraID)
                        defer {
                            self.endSleepAssertion(token: extraSleep)
                            self.workers[extraID] = nil
                        }
                        await self.runDownloadTask(taskID: extraID, resolved: firstExtra, settings: settings)
                    }
                } else {
                    let parts = Self.makeDownloadParts(from: extraGroup.items)
                    let extraJob = Job(
                        id: extraID,
                        kind: .download,
                        title: extraGroup.title,
                        status: .queued,
                        progress: 0.02,
                        source: ArtifactRef(kind: .remoteURL, value: firstExtra.originalURL),
                        input: ArtifactRef(kind: .remoteURL, value: firstExtra.finalURL),
                        message: "分卷 0/\(parts.count)",
                        rightText: Self.formatAggregatedRightText(parts: parts),
                        passwordHint: passwordHint,
                        downloadParts: parts
                    )
                    await self.addJob(extraJob)
                    self.workers[extraID] = Task { [weak self] in
                        guard let self else { return }
                        let extraSleep = self.beginSleepAssertion(for: extraID)
                        defer {
                            self.endSleepAssertion(token: extraSleep)
                            self.workers[extraID] = nil
                        }
                        await self.runAggregatedDownloadPipeline(jobID: extraID, settings: settings)
                    }
                }
            }

            if firstGroup.items.count == 1 {
                let item = firstGroup.items[0]
                _ = await self.jobStore.updateDownloadMetadata(
                    id: taskID,
                    passwordHint: passwordHint,
                    downloadParts: nil,
                    mirrorURLs: item.mirrorURLs
                )
                await self.updateJob(
                    taskID,
                    title: item.suggestedFilename ?? firstGroup.title,
                    source: ArtifactRef(kind: .remoteURL, value: item.originalURL),
                    input: ArtifactRef(kind: .remoteURL, value: item.finalURL),
                    message: "排队中"
                )
                await self.runDownloadTask(taskID: taskID, resolved: item, settings: settings)
            } else {
                let parts = Self.makeDownloadParts(from: firstGroup.items)
                _ = await self.jobStore.updateDownloadMetadata(id: taskID, passwordHint: passwordHint, downloadParts: parts)
                await self.updateJob(
                    taskID,
                    title: firstGroup.title,
                    message: "分卷 0/\(parts.count)",
                    rightText: Self.formatAggregatedRightText(parts: parts)
                )
                await self.runAggregatedDownloadPipeline(jobID: taskID, settings: settings)
            }
        }
    }

    package func resumeDownloadJob(_ id: UUID, settings: AppSettings) {
        retryOrResumeDownloadJob(id, isResume: true, settings: settings)
    }

    package func retryDownloadJob(_ id: UUID, settings: AppSettings) {
        retryOrResumeDownloadJob(id, isResume: false, settings: settings)
    }

    private func retryOrResumeDownloadJob(_ id: UUID, isResume: Bool, settings: AppSettings) {
        lastDownloadDirectory = settings.download.downloadDirectory
        updateMaxConcurrentDownloads(settings.download.maxConcurrentDownloads)
        workers[id]?.cancel()
        cancelledTaskIDs.remove(id)
        pausedTaskIDs.remove(id)

        workers[id] = Task { [weak self] in
            guard let self else { return }
            let sleepToken = self.beginSleepAssertion(for: id)
            defer {
                self.endSleepAssertion(token: sleepToken)
                self.workers[id] = nil
            }
            guard let job = await self.jobStore.job(for: id), job.kind == .download else { return }
            await self.services.clearCancellation(taskID: id)

            if var parts = job.downloadParts, !parts.isEmpty {
                for idx in parts.indices where parts[idx].status != .succeeded {
                    parts[idx].status = .queued
                    parts[idx].speedBytesPerSec = 0
                    parts[idx].message = "排队中"
                    await self.services.clearCancellation(taskID: parts[idx].id)
                }
                _ = await self.jobStore.updateDownloadMetadata(id: id, passwordHint: job.passwordHint, downloadParts: parts)
                _ = await self.jobStore.reopenForResume(
                    id: id,
                    status: .running,
                    message: isResume ? "续传中" : "重试中",
                    rightText: Self.formatAggregatedRightText(parts: parts)
                )
                if let updated = await self.jobStore.job(for: id) {
                    self.eventContinuation.yield(.jobUpdated(updated))
                }
                await self.runAggregatedDownloadPipeline(jobID: id, settings: settings)
                return
            }

            let rawOrigin = job.sourceURL ?? job.input?.value ?? ""
            let parsedOrigin = DownloadInputParser.parse(rawOrigin, knownBareDomains: self.services.knownBareHostDomains())
            let originURL = parsedOrigin.urls.first ?? rawOrigin
            let combinedMirrors = Array(NSOrderedSet(array: job.mirrorURLs + (parsedOrigin.mirrorGroups[originURL] ?? [])))
                .compactMap { $0 as? String }
                .filter { $0 != originURL }
            guard !originURL.isEmpty else { return }
            _ = await self.jobStore.reopenForResume(
                id: id,
                status: .running,
                message: "解析中",
                rightText: job.rightText
            )
            if let updated = await self.jobStore.job(for: id) {
                self.eventContinuation.yield(.jobUpdated(updated))
            }
            await self.recordLog(
                taskID: id,
                module: .download,
                level: .info,
                message: isResume ? "刷新直链续传: \(originURL)" : "重新解析: \(originURL)"
            )

            let passwords = Self.candidatePasswords(hint: job.passwordHint, settings: settings)
            let resolvedOutcome = await self.resolveWithMirrors(
                originURL,
                extraMirrors: combinedMirrors,
                passwords: passwords,
                settings: settings,
                taskID: id
            )
            let resolution = resolvedOutcome.result
            guard self.acceptsProgress(for: id), !self.pausedTaskIDs.contains(id) else { return }

            guard let first = resolution.downloads.first else {
                let reason = resolution.failureReason ?? "解析失败"
                await self.updateJob(id, status: .failed, message: reason, rightText: "解析失败")
                return
            }

            if resolution.downloads.count == 1 {
                let preservedName: String? = {
                    if let s = first.suggestedFilename, !s.isEmpty { return s }
                    if !job.title.isEmpty, !job.title.hasPrefix("正在解析") { return job.title }
                    return nil
                }()
                let resolvedItem = ResolvedDownload(
                    originalURL: first.originalURL,
                    finalURL: first.finalURL,
                    mirrorURLs: first.mirrorURLs,
                    headers: first.headers,
                    suggestedFilename: preservedName,
                    useChunkedRange: first.useChunkedRange,
                    totalSize: first.totalSize,
                    subDirectory: first.subDirectory,
                    mailRuWeblink: first.mailRuWeblink,
                    maxThreads: first.maxThreads,
                    needsProxy: first.needsProxy,
                    resolverID: first.resolverID,
                    rateLimitNote: first.rateLimitNote
                )
                _ = await self.jobStore.updateDownloadMetadata(
                    id: id,
                    passwordHint: job.passwordHint,
                    downloadParts: nil,
                    mirrorURLs: resolvedItem.mirrorURLs
                )
                await self.runDownloadTask(taskID: id, resolved: resolvedItem, settings: settings)
            } else {
                await self.runFolderDownloadPipeline(firstTaskID: id, guessedName: job.title, items: resolution.downloads, settings: settings)
            }
        }
    }

    package func retryDownloadPart(jobID: UUID, partID: UUID, settings: AppSettings) {
        lastDownloadDirectory = settings.download.downloadDirectory
        updateMaxConcurrentDownloads(settings.download.maxConcurrentDownloads)
        cancelledTaskIDs.remove(jobID)
        pausedTaskIDs.remove(jobID)

        Task { @MainActor [weak self] in
            guard let self, let job = await self.jobStore.job(for: jobID),
                  var parts = self.livePartsByJob[jobID] ?? job.downloadParts,
                  let pIdx = parts.firstIndex(where: { $0.id == partID }) else { return }
            parts[pIdx].status = .queued
            parts[pIdx].speedBytesPerSec = 0
            parts[pIdx].message = "排队中"
            self.livePartsByJob[jobID] = parts
            await self.services.clearCancellation(taskID: partID)
            await self.services.clearCancellation(taskID: jobID)
            _ = await self.jobStore.updateDownloadMetadata(id: jobID, passwordHint: job.passwordHint, downloadParts: parts)

            if self.workers[jobID] == nil {
                _ = await self.jobStore.reopenForResume(
                    id: jobID,
                    status: .running,
                    message: "分卷续传",
                    rightText: Self.formatAggregatedRightText(parts: parts)
                )
                if let updated = await self.jobStore.job(for: jobID) {
                    self.eventContinuation.yield(.jobUpdated(updated))
                }
                self.workers[jobID] = Task { [weak self] in
                    guard let self else { return }
                    let sleepToken = self.beginSleepAssertion(for: jobID)
                    defer {
                        self.endSleepAssertion(token: sleepToken)
                        self.workers[jobID] = nil
                    }
                    await self.runAggregatedDownloadPipeline(jobID: jobID, settings: settings)
                }
            } else if let updated = await self.jobStore.job(for: jobID) {
                self.eventContinuation.yield(.jobUpdated(updated))
            }
        }
    }

    package func runFolderDownloadPipeline(firstTaskID: UUID, guessedName: String, items: [ResolvedDownload], settings: AppSettings) async {
        guard let first = items.first, acceptsProgress(for: firstTaskID), !pausedTaskIDs.contains(firstTaskID) else { return }
        lastDownloadDirectory = settings.download.downloadDirectory
        updateMaxConcurrentDownloads(settings.download.maxConcurrentDownloads)

        let existingJob = await jobStore.job(for: firstTaskID)
        let parts = Self.makeDownloadParts(from: items)
        let folderRawTitle = first.subDirectory ?? first.suggestedFilename ?? guessedName
        let cleanTitle = DownloadInputParser.cleanDisplayTitle(fromRawName: folderRawTitle)
        let displayTitle = cleanTitle.isEmpty ? folderRawTitle : cleanTitle

        _ = await jobStore.updateDownloadMetadata(
            id: firstTaskID,
            passwordHint: existingJob?.passwordHint,
            downloadParts: parts
        )
        await updateJob(
            firstTaskID,
            title: displayTitle,
            message: "分卷 0/\(parts.count)",
            rightText: Self.formatAggregatedRightText(parts: parts)
        )
        await recordLog(
            taskID: firstTaskID,
            module: .download,
            level: .info,
            message: "合并多文件任务 \(displayTitle)（\(parts.count) 个分卷）"
        )
        await runAggregatedDownloadPipeline(jobID: firstTaskID, settings: settings)
    }

    private func runAggregatedDownloadPipeline(jobID: UUID, settings: AppSettings) async {
        guard let initialJob = await jobStore.job(for: jobID),
              let initialParts = initialJob.downloadParts,
              !initialParts.isEmpty else { return }
        let sleepToken = beginSleepAssertion(for: jobID)
        defer { endSleepAssertion(token: sleepToken) }
        livePartsByJob[jobID] = initialParts

        let names = initialParts.map(\.filename)
        let primaryFile = Self.selectPrimaryArchive(from: names, isArchiveFile: services.isArchiveFile)
        let requiredBinSlices = Self.requiredCompanionVolumes(for: primaryFile, in: names)
        let requiredSet = Set([primaryFile].compactMap { $0 }).union(requiredBinSlices)

        var baseUnpackTriggered = false
        var relayTask: Task<Void, Never>?
        var pendingDLCInstallers: [(partID: UUID, filename: String, path: String)] = []
        let passwords = Self.candidatePasswords(hint: initialJob.passwordHint, settings: settings)

        func checkAndTriggerRelayIfReady() async {
            guard !baseUnpackTriggered,
                  settings.autoRelay,
                  let primaryFile else { return }
            let currentJob = await jobStore.job(for: jobID)
            guard let parts = livePartsByJob[jobID] ?? currentJob?.downloadParts else { return }
            let completedByName: [String: String] = Dictionary(
                uniqueKeysWithValues: parts.compactMap { part in
                    guard part.status == .succeeded,
                          let local = part.localPath,
                          services.fileExists(local) else { return nil }
                    return (part.filename, local)
                }
            )
            guard let primaryPath = completedByName[primaryFile],
                  requiredBinSlices.isSubset(of: Set(completedByName.keys)) else { return }

            let hasRemaining = parts.contains { $0.status != .succeeded }
            let hasRemainingDLC = parts.contains {
                $0.status != .succeeded
                    && $0.filename.lowercased().hasPrefix("setup_")
                    && $0.filename.lowercased().hasSuffix(".exe")
            }
            if hasRemaining && !hasRemainingDLC && !requiredSet.isSubset(of: Set(completedByName.keys)) {
                return
            }

            baseUnpackTriggered = true
            let detail = hasRemaining ? " (附属文件继续下载)" : ""
            await recordLog(taskID: jobID, module: .unpack, level: .info, message: "分卷就绪，开始解压: \(primaryFile)\(detail)")
            guard await prepareUnpackStage(taskID: jobID, archivePath: primaryPath, progress: 1.0 / 3.0) else { return }

            relayTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runUnpackTask(
                    taskID: jobID,
                    archivePath: primaryPath,
                    candidatePasswords: passwords,
                    settings: settings,
                    progressRange: (1.0 / 3.0...2.0 / 3.0)
                )
            }
        }

        let pendingParts = initialParts.filter { $0.status != .succeeded }
        if !pendingParts.isEmpty {
            let knownTotalBytes = initialParts.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
            let existingStagedBytes = initialParts.reduce(Int64(0)) { acc, part in
                if part.status == .succeeded {
                    return acc + max(part.downloadedBytes, part.totalBytes ?? 0)
                }
                return acc + part.downloadedBytes
            }
            let spaceOK = await checkDiskSpacePreflight(
                jobID: jobID,
                knownTotalBytes: knownTotalBytes,
                existingStagedBytes: existingStagedBytes,
                settings: settings
            )
            if !spaceOK {
                var updatedParts = initialParts
                for idx in updatedParts.indices where updatedParts[idx].status != .succeeded {
                    updatedParts[idx].status = .failed
                    updatedParts[idx].speedBytesPerSec = 0
                    updatedParts[idx].message = "空间不足"
                }
                livePartsByJob[jobID] = updatedParts
                _ = await jobStore.updateDownloadMetadata(id: jobID, passwordHint: initialJob.passwordHint, downloadParts: updatedParts)
                return
            }
        }

        if pendingParts.isEmpty {
            await checkAndTriggerRelayIfReady()
        } else {
            await withTaskGroup(of: (UUID, String, String?).self) { group in
                for part in pendingParts {
                    group.addTask { @MainActor in
                        let acquired = await self.acquireDownloadSlot(token: part.id, ownerJobID: jobID, limit: settings.download.maxConcurrentDownloads)
                        guard acquired else { return (part.id, part.filename, nil) }
                        defer { self.releaseDownloadSlot(token: part.id) }
                        guard self.acceptsProgress(for: jobID), !self.pausedTaskIDs.contains(jobID) else {
                            return (part.id, part.filename, nil)
                        }

                        let rawResolved = ResolvedDownload(
                            originalURL: part.originalURL,
                            finalURL: part.resolvedURL,
                            mirrorURLs: part.mirrorURLs,
                            headers: part.headers,
                            suggestedFilename: part.filename,
                            useChunkedRange: part.useChunkedRange,
                            totalSize: part.totalBytes,
                            subDirectory: part.subDirectory,
                            mailRuWeblink: part.mailRuWeblink,
                            maxThreads: part.maxThreads,
                            needsProxy: part.needsProxy,
                            resolverID: part.resolverID
                        )
                        let refreshed = await self.refreshItemForResume(rawResolved, passwords: passwords, settings: settings)
                        guard self.acceptsProgress(for: jobID), !self.pausedTaskIDs.contains(jobID) else {
                            return (part.id, part.filename, nil)
                        }

                        await self.updatePartState(jobID: jobID, partID: part.id) { p in
                            p.status = .running
                            p.resolvedURL = refreshed.finalURL
                            p.headers = refreshed.headers
                            p.mirrorURLs = refreshed.mirrorURLs
                            p.message = refreshed.rateLimitNote ?? "连接中"
                            if let total = refreshed.totalSize, p.totalBytes == nil {
                                p.totalBytes = total
                            }
                        }

                        var tokens = self.activePartTokensByJob[jobID] ?? []
                        tokens.insert(part.id)
                        self.activePartTokensByJob[jobID] = tokens
                        defer {
                            self.activePartTokensByJob[jobID]?.remove(part.id)
                        }

                        let stage = self.services.downloadStage(
                            title: part.filename,
                            resolved: refreshed,
                            stagingJobID: jobID,
                            stagingSubkey: part.id.uuidString,
                            settings: settings
                        )
                        let context = StageContext(
                            jobID: part.id,
                            input: ArtifactRef(kind: .remoteURL, value: refreshed.finalURL),
                            reportProgress: { [weak self] stageProg in
                                await self?.handlePartProgress(jobID: jobID, partID: part.id, progress: stageProg, settings: settings)
                            },
                            log: { [weak self] stageLog in
                                await self?.recordLog(
                                    taskID: jobID,
                                    module: .download,
                                    level: stageLog.level,
                                    message: "[\(part.filename)] \(stageLog.message)",
                                    rawOutput: stageLog.rawOutput
                                )
                            },
                            isCancelled: { [weak self] in
                                await self?.isCancelledOrPaused(jobID: jobID) ?? true
                            }
                        )
                        let result = await stage.execute(context: context)
                        if self.pausedTaskIDs.contains(jobID) {
                            await self.updatePartState(jobID: jobID, partID: part.id) { p in
                                p.status = .paused
                                p.speedBytesPerSec = 0
                                p.message = "已暂停"
                            }
                            return (part.id, part.filename, nil)
                        }
                        if !self.acceptsProgress(for: jobID) {
                            return (part.id, part.filename, nil)
                        }

                        switch result {
                        case .success(let output):
                            let outPath = output.artifact?.value
                            let finalSize = outPath.flatMap { self.services.fileSize($0) } ?? part.totalBytes
                            await self.updatePartState(jobID: jobID, partID: part.id) { p in
                                p.status = .succeeded
                                p.progress = 1
                                p.speedBytesPerSec = 0
                                p.localPath = outPath
                                p.message = nil
                                if let sz = finalSize {
                                    p.totalBytes = sz
                                    p.downloadedBytes = sz
                                }
                            }
                            await self.refreshAggregatedJobSummary(jobID: jobID, settings: settings)
                            return (part.id, part.filename, outPath)
                        case .cancelled:
                            await self.updatePartState(jobID: jobID, partID: part.id) { p in
                                p.status = self.pausedTaskIDs.contains(jobID) ? .paused : .cancelled
                                p.speedBytesPerSec = 0
                                p.message = self.pausedTaskIDs.contains(jobID) ? "已暂停" : "已停止"
                            }
                            return (part.id, part.filename, nil)
                        case .failure(let failure):
                            await self.updatePartState(jobID: jobID, partID: part.id) { p in
                                p.status = .failed
                                p.speedBytesPerSec = 0
                                p.message = failure.message
                            }
                            await self.refreshAggregatedJobSummary(jobID: jobID, settings: settings)
                            return (part.id, part.filename, nil)
                        }
                    }
                }

                for await (finishedPartID, finishedFilename, finishedPath) in group {
                    if let finishedPath {
                        if baseUnpackTriggered,
                           finishedFilename.lowercased().hasPrefix("setup_"),
                           finishedFilename.lowercased().hasSuffix(".exe") {
                            pendingDLCInstallers.append((partID: finishedPartID, filename: finishedFilename, path: finishedPath))
                        }
                        await checkAndTriggerRelayIfReady()
                    }
                }
            }
        }

        if let relayTask {
            await relayTask.value
        }

        guard acceptsProgress(for: jobID), !pausedTaskIDs.contains(jobID) else { return }
        guard let finalJob = await jobStore.job(for: jobID),
              let finalParts = livePartsByJob[jobID] ?? finalJob.downloadParts else { return }
        if !pendingDLCInstallers.isEmpty,
           let primaryFile,
           let primaryPath = finalParts.first(where: { $0.filename == primaryFile })?.localPath {
            let unpackedDir: String = {
                if let input = finalJob.input, input.kind == .directory { return input.value }
                if let output = finalJob.output, output.kind == .directory { return output.value }
                var rawBase = ((primaryPath as NSString).lastPathComponent as NSString).deletingPathExtension
                if rawBase.lowercased().hasPrefix("setup_") { rawBase = String(rawBase.dropFirst("setup_".count)) }
                return ((primaryPath as NSString).deletingLastPathComponent as NSString)
                    .appendingPathComponent(GameTitle.cleanGameTitle(from: rawBase))
            }()
            for dlc in pendingDLCInstallers where acceptsProgress(for: jobID) {
                await recordLog(taskID: jobID, module: .unpack, level: .info, message: "合并 DLC: \(dlc.filename)")
                let merged = await services.mergeDLC(installer: dlc.path, directory: unpackedDir, taskID: dlc.partID)
                if merged {
                    await recordLog(taskID: jobID, module: .unpack, level: .info, message: "DLC 合并完成: \(dlc.filename)")
                }
            }
        }

        // Finalize download state if autoRelay did not transition the job out of `.download`
        if finalJob.kind == .download {
            let failedParts = finalParts.filter { $0.status == .failed }
            let allSucceeded = finalParts.allSatisfy { $0.status == .succeeded }
            if allSucceeded {
                let primaryPath = primaryFile.flatMap { name in finalParts.first(where: { $0.filename == name })?.localPath }
                    ?? finalParts.first?.localPath
                await updateJob(
                    jobID,
                    status: .succeeded,
                    progress: 1,
                    output: primaryPath.map { ArtifactRef(kind: .file, value: $0) },
                    clearMessage: true,
                    rightText: Self.formatAggregatedRightText(parts: finalParts)
                )
            } else if !failedParts.isEmpty {
                let pill = failedParts.count == 1
                    ? (failedParts[0].message ?? "分卷失败")
                    : "分卷失败 (\(failedParts.count)/\(finalParts.count))"
                await updateJob(
                    jobID,
                    status: .failed,
                    message: pill,
                    rightText: Self.formatAggregatedRightText(parts: finalParts)
                )
            }
        }
    }

    private static func makeDownloadParts(from items: [ResolvedDownload]) -> [DownloadPart] {
        items.enumerated().map { idx, item in
            let fallbackName = DownloadInputParser.inferFilenameFromURL(item.finalURL)
                ?? DownloadInputParser.inferFilenameFromURL(item.originalURL)
                ?? "part_\(idx + 1)"
            return DownloadPart(
                filename: item.suggestedFilename ?? fallbackName,
                originalURL: item.originalURL,
                resolvedURL: item.finalURL,
                mirrorURLs: item.mirrorURLs,
                headers: item.headers,
                status: .queued,
                progress: 0,
                downloadedBytes: 0,
                totalBytes: item.totalSize,
                speedBytesPerSec: 0,
                message: "排队中",
                subDirectory: item.subDirectory,
                useChunkedRange: item.useChunkedRange,
                mailRuWeblink: item.mailRuWeblink,
                maxThreads: item.maxThreads,
                needsProxy: item.needsProxy,
                resolverID: item.resolverID
            )
        }
    }

    private static func candidatePasswords(hint: String?, settings: AppSettings) -> [String] {
        var list: [String] = []
        var seen: Set<String> = []
        func add(_ pw: String) {
            if !seen.contains(pw) {
                seen.insert(pw)
                list.append(pw)
            }
        }
        if let hint, !hint.isEmpty {
            add(hint)
        }
        add("")
        for pw in settings.passwords where !pw.isEmpty {
            add(pw)
        }
        return list
    }

    private func refreshItemForResume(
        _ item: ResolvedDownload,
        passwords: [String],
        settings: AppSettings
    ) async -> ResolvedDownload {
        if item.mailRuWeblink != nil {
            return await services.refreshDownload(item, passwords: passwords, settings: settings)
        }
        guard !item.originalURL.isEmpty, item.originalURL != item.finalURL else {
            return item
        }
        let outcome = await resolveWithMirrors(
            item.originalURL,
            extraMirrors: item.mirrorURLs,
            passwords: passwords,
            settings: settings
        )
        let resolved = outcome.result
        if let match = resolved.downloads.first(where: { $0.suggestedFilename == item.suggestedFilename }) ?? resolved.downloads.first {
            return ResolvedDownload(
                originalURL: match.originalURL,
                finalURL: match.finalURL,
                mirrorURLs: match.appendingMirrors(item.mirrorURLs).mirrorURLs,
                headers: match.headers,
                suggestedFilename: item.suggestedFilename ?? match.suggestedFilename,
                useChunkedRange: match.useChunkedRange,
                totalSize: match.totalSize ?? item.totalSize,
                subDirectory: item.subDirectory ?? match.subDirectory,
                mailRuWeblink: match.mailRuWeblink ?? item.mailRuWeblink,
                maxThreads: match.maxThreads ?? item.maxThreads,
                needsProxy: match.needsProxy ?? item.needsProxy,
                resolverID: match.resolverID ?? item.resolverID,
                rateLimitNote: match.rateLimitNote
            )
        }
        return await services.refreshDownload(item, passwords: passwords, settings: settings)
    }

    private func handlePartProgress(
        jobID: UUID,
        partID: UUID,
        progress: StageProgress,
        settings: AppSettings
    ) async {
        guard acceptsProgress(for: jobID), !pausedTaskIDs.contains(jobID) else { return }
        await updatePartState(jobID: jobID, partID: partID) { part in
            if let f = progress.fraction { part.progress = f }
            if let dl = progress.downloadedBytes { part.downloadedBytes = dl }
            if let tot = progress.totalBytes { part.totalBytes = tot }
            if let spd = progress.speedBytesPerSec { part.speedBytesPerSec = spd }
            if let msg = progress.message { part.message = msg }
        }
        await refreshAggregatedJobSummary(jobID: jobID, settings: settings)
    }

    private func updatePartState(jobID: UUID, partID: UUID, mutate: (inout DownloadPart) -> Void) async {
        if var parts = livePartsByJob[jobID],
           let idx = parts.firstIndex(where: { $0.id == partID }) {
            mutate(&parts[idx])
            livePartsByJob[jobID] = parts
            _ = await jobStore.updateDownloadMetadata(id: jobID, passwordHint: nil, downloadParts: parts)
            return
        }
        guard let job = await jobStore.job(for: jobID), var parts = job.downloadParts,
              let idx = parts.firstIndex(where: { $0.id == partID }) else { return }
        mutate(&parts[idx])
        livePartsByJob[jobID] = parts
        _ = await jobStore.updateDownloadMetadata(id: jobID, passwordHint: job.passwordHint, downloadParts: parts)
    }

    private func refreshAggregatedJobSummary(jobID: UUID, settings: AppSettings) async {
        guard let job = await jobStore.job(for: jobID),
              job.kind == .download,
              let parts = livePartsByJob[jobID] ?? job.downloadParts, !parts.isEmpty else { return }
        guard acceptsProgress(for: jobID), !pausedTaskIDs.contains(jobID) else { return }
        let doneCount = parts.filter { $0.status == .succeeded }.count
        let totalCount = parts.count
        let activeParts = parts.filter { $0.status == .running }
        let totalSpeed = activeParts.reduce(0.0) { $0 + $1.speedBytesPerSec }
        let speedText = Self.formatSpeed(bytesPerSec: totalSpeed)
        let rateLimitedOnly = !activeParts.isEmpty
            && activeParts.allSatisfy { $0.message == "限速 1MB/s" }
            && totalSpeed <= 1.3 * 1024.0 * 1024.0
        let pill: String
        if rateLimitedOnly {
            pill = "限速 1MB/s"
        } else {
            pill = speedText ?? "分卷 \(doneCount)/\(totalCount)"
        }

        let totalKnownBytes = parts.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
        let rawFraction: Double
        if totalKnownBytes > 0 {
            let doneBytes = parts.reduce(Int64(0)) { acc, part in
                if part.status == .succeeded { return acc + (part.totalBytes ?? part.downloadedBytes) }
                return acc + part.downloadedBytes
            }
            rawFraction = Double(doneBytes) / Double(totalKnownBytes)
        } else {
            rawFraction = parts.reduce(0.0) { $0 + ($1.status == .succeeded ? 1.0 : $1.progress) } / Double(totalCount)
        }
        let mappedProgress = settings.autoRelay ? (rawFraction / 3.0) : rawFraction
        let rightText = Self.formatAggregatedRightText(parts: parts)
        await updateJob(jobID, status: .running, progress: mappedProgress, message: pill, rightText: rightText)
    }

    private static func formatSpeed(bytesPerSec: Double) -> String? {
        guard bytesPerSec > 1024 else { return nil }
        let mb = bytesPerSec / (1024.0 * 1024.0)
        if mb >= 1.0 {
            return String(format: "%.1f MB/s", mb)
        }
        let kb = bytesPerSec / 1024.0
        return String(format: "%.0f KB/s", kb)
    }

    private static func formatAggregatedRightText(parts: [DownloadPart]) -> String {
        let downloaded = parts.reduce(Int64(0)) { acc, part in
            if part.status == .succeeded {
                return acc + max(part.downloadedBytes, part.totalBytes ?? 0)
            }
            return acc + part.downloadedBytes
        }
        let totalKnown = parts.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
        let allHaveTotal = parts.allSatisfy { ($0.totalBytes ?? 0) > 0 }
        if totalKnown > 0 && allHaveTotal {
            let doneStr = ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)
            let totStr = ByteCountFormatter.string(fromByteCount: totalKnown, countStyle: .file)
            return "\(doneStr) / \(totStr)"
        }
        if downloaded > 0 {
            return ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)
        }
        if totalKnown > 0 {
            return ByteCountFormatter.string(fromByteCount: totalKnown, countStyle: .file)
        }
        return "待下载"
    }

    private func acquireDownloadSlot(token: UUID, ownerJobID: UUID, limit: Int) async -> Bool {
        maxConcurrentDownloads = DownloadSettings.clampedConcurrentDownloads(limit)
        if isCancelledOrPaused(jobID: ownerJobID) { return false }
        if activeDownloadTokens.contains(token) { return true }
        if activeDownloadTokens.count < maxConcurrentDownloads {
            activeDownloadTokens.insert(token)
            return true
        }
        return await withCheckedContinuation { continuation in
            downloadWaiters.append((token: token, ownerJobID: ownerJobID, continuation: continuation))
        }
    }

    private func releaseDownloadSlot(token: UUID) {
        activeDownloadTokens.remove(token)
        drainDownloadWaiters()
    }

    private func drainDownloadWaiters() {
        while activeDownloadTokens.count < maxConcurrentDownloads, !downloadWaiters.isEmpty {
            let waiter = downloadWaiters.removeFirst()
            if isCancelledOrPaused(jobID: waiter.ownerJobID) {
                waiter.continuation.resume(returning: false)
                continue
            }
            activeDownloadTokens.insert(waiter.token)
            waiter.continuation.resume(returning: true)
        }
    }

    private func cancelDownloadWaiters(ownerJobID: UUID) {
        var remaining: [(token: UUID, ownerJobID: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
        for waiter in downloadWaiters {
            if waiter.ownerJobID == ownerJobID {
                waiter.continuation.resume(returning: false)
            } else {
                remaining.append(waiter)
            }
        }
        downloadWaiters = remaining
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
        lastDownloadDirectory = settings.download.downloadDirectory
        updateMaxConcurrentDownloads(settings.download.maxConcurrentDownloads)
        guard let job = await jobStore.job(for: taskID), job.kind == .download,
              job.status == .queued || job.status == .running || job.status == .paused,
              acceptsProgress(for: taskID), !pausedTaskIDs.contains(taskID) else { return }

        if job.status != .paused && job.progress <= 0.05, let total = resolved.totalSize, total > 0 {
            let spaceOK = await checkDiskSpacePreflight(
                jobID: taskID,
                knownTotalBytes: total,
                existingStagedBytes: 0,
                settings: settings
            )
            guard spaceOK else { return }
        }

        let sleepToken = beginSleepAssertion(for: taskID)
        defer { endSleepAssertion(token: sleepToken) }

        let acquired = await acquireDownloadSlot(token: taskID, ownerJobID: taskID, limit: settings.download.maxConcurrentDownloads)
        guard acquired else { return }
        defer { releaseDownloadSlot(token: taskID) }

        guard acceptsProgress(for: taskID), !pausedTaskIDs.contains(taskID) else { return }
        let currentTitle = job.title.isEmpty ? (resolved.suggestedFilename ?? "Download") : job.title
        await updateJob(
            taskID,
            status: .running,
            title: currentTitle,
            input: ArtifactRef(kind: .remoteURL, value: resolved.finalURL)
        )
        let effectiveResolved = job.mirrorURLs.isEmpty
            ? resolved
            : resolved.appendingMirrors(job.mirrorURLs)
        let stage = services.downloadStage(
            title: currentTitle,
            resolved: effectiveResolved,
            stagingJobID: taskID,
            stagingSubkey: nil,
            settings: settings
        )
        let result = await execute(
            registry: StageRegistry(stages: [stage]),
            stageID: stage.id,
            jobID: taskID,
            module: .download,
            input: ArtifactRef(kind: .remoteURL, value: effectiveResolved.finalURL),
            progressRange: progressRange ?? (settings.autoRelay && !suppressAutoRelay ? (0.0...1.0 / 3.0) : nil)
        )
        if pausedTaskIDs.contains(taskID) { return }
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
                await recordLog(taskID: taskID, module: .unpack, level: .info, message: "自动解压: \(finalTitle)")
                let passwords = Self.candidatePasswords(hint: job.passwordHint, settings: settings)
                await runUnpackTask(
                    taskID: taskID,
                    archivePath: outputPath,
                    candidatePasswords: passwords,
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
            if !pausedTaskIDs.contains(taskID) {
                await updateJob(taskID, status: .cancelled, message: "已停止", rightText: "已停止")
            }
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
            let sleepToken = self.beginSleepAssertion(for: taskID)
            defer {
                self.endSleepAssertion(token: sleepToken)
                self.workers[taskID] = nil
            }
            await self.addJob(job)
            await self.recordLog(taskID: taskID, module: .unpack, level: .info, message: "开始解压: \(filename)")
            await self.runUnpackTask(taskID: taskID, archivePath: archivePath, candidatePasswords: [""] + settings.passwords, settings: settings)
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
        let sleepToken = beginSleepAssertion(for: taskID)
        defer { endSleepAssertion(token: sleepToken) }
        await updateJob(taskID, status: .running)
        let knownGames = await gameLibrary.all()
        let stage = services.unpackStage(
            passwords: candidatePasswords,
            deleteArchive: settings.deleteArchiveAfterUnpack,
            knownGames: knownGames
        )
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
                clearSleepAssertions(for: taskID)
                await recordLog(taskID: taskID, module: .patch, level: .info, message: "自动补丁: \(title)")
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
            if output.artifact?.kind == .file {
                let resolvedTitle = output.metadata["title"] ?? cleanTitle
                let rawBottle = output.metadata["bottleName"]
                let bottleName = (rawBottle?.isEmpty == false && rawBottle != "独立补丁包" && rawBottle != "Default") ? rawBottle : nil
                let rawDefaultArgs = output.metadata["launchArguments"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let patchDefaultArgs = (rawDefaultArgs?.isEmpty == false) ? rawDefaultArgs : nil
                let probe = LaunchGame(
                    title: resolvedTitle,
                    exePath: output.artifact?.value,
                    gameDirectory: folderPath,
                    bottleName: bottleName,
                    appID: output.metadata["appID"],
                    source: .patchPipeline
                )
                let existingMatch = await gameLibrary.all().first(where: { $0.matches(probe) })
                let existingCustomArgs = existingMatch?.launchArguments?.trimmingCharacters(in: .whitespacesAndNewlines)
                let effectiveLaunchArgs: String? = (existingCustomArgs?.isEmpty == false)
                    ? existingCustomArgs
                    : patchDefaultArgs
                let game = LaunchGame(
                    title: resolvedTitle,
                    exePath: output.artifact?.value,
                    gameDirectory: folderPath,
                    bottleName: bottleName,
                    appID: output.metadata["appID"],
                    source: .patchPipeline,
                    launchArguments: effectiveLaunchArgs
                )
                let stored = await gameLibrary.upsert(game, preferIncomingMetadata: true)
                services.cleanupBaselineSnapshot(forGameID: stored.id, gameDirectory: existingMatch?.gameDirectory)
                services.cleanupBaselineSnapshot(forGameID: stored.id, gameDirectory: stored.gameDirectory)
                await services.invalidateLaunchGameIconCache(for: stored)
                eventContinuation.yield(.launchGameUpdated(stored))
            }
        case .cancelled:
            await updateJob(taskID, status: .cancelled, message: "已停止", rightText: "已停止")
        case .failure(let failure):
            await updateJob(taskID, status: .failed, message: failure.message)
        }
    }

    @discardableResult
    package func importLaunchGame(at url: URL, settings: AppSettings) async -> LaunchGame? {
        guard let inspected = await services.inspectGameForImport(at: url, bottlesDirectory: settings.bottlesDirectory) else {
            return nil
        }
        let stored = await gameLibrary.upsert(inspected, preferIncomingMetadata: true)
        eventContinuation.yield(.launchGameUpdated(stored))
        return stored
    }

    @discardableResult
    package func removeLaunchGame(
        _ id: UUID,
        mode: LaunchGameRemovalMode = .recordOnly,
        settings: AppSettings? = nil
    ) async -> LaunchGameUninstallOutcome {
        let allGames = await gameLibrary.all()
        let existing = allGames.first(where: { $0.id == id })
        workers[id]?.cancel()
        cancelledTaskIDs.insert(id)
        await services.cancel(taskID: id)
        await gameLibrary.remove(id: id, suppressRescan: true)
        var outcome = LaunchGameUninstallOutcome()
        if let existing {
            if mode == .moveToTrash {
                outcome = await services.uninstallLaunchGameArtifacts(
                    for: existing,
                    knownGames: allGames,
                    settings: settings ?? AppSettings()
                )
            }
            services.cleanupBaselineSnapshot(forGameID: existing.id, gameDirectory: existing.gameDirectory)
            await services.invalidateLaunchGameIconCache(for: existing)
            await services.removeCustomLaunchGameIcon(at: existing.customIconPath)
        }
        workers[id] = nil
        eventContinuation.yield(.launchGameRemoved(id))
        return outcome
    }
    package func resolveLaunchGameIcon(_ game: LaunchGame) async -> Data? {
        await services.resolveLaunchGameIcon(game)
    }

    package func readBottleRuntimeOptions(
        for game: LaunchGame,
        bottlesDirectory: String
    ) async -> CrossOverBottleRuntimeOptions? {
        await services.readBottleRuntimeOptions(for: game, bottlesDirectory: bottlesDirectory)
    }

    package func saveBottleRuntimeOptions(
        _ options: CrossOverBottleRuntimeOptions,
        for game: LaunchGame,
        bottlesDirectory: String
    ) async throws {
        try await services.saveBottleRuntimeOptions(options, for: game, bottlesDirectory: bottlesDirectory)
    }

    @discardableResult
    package func updateLaunchGame(
        _ updated: LaunchGame,
        previousCustomIconPath: String? = nil,
        bottlesDirectory: String? = nil,
        bottleRuntimeOptions: CrossOverBottleRuntimeOptions? = nil
    ) async -> LaunchGame? {
        let existing = await gameLibrary.game(for: updated.id)
        if let existing {
            await services.invalidateLaunchGameIconCache(for: existing)
        }
        await services.invalidateLaunchGameIconCache(for: updated)
        let saved = await gameLibrary.update(updated)
        if let previousCustomIconPath,
           !previousCustomIconPath.isEmpty,
           previousCustomIconPath != updated.customIconPath {
            await services.removeCustomLaunchGameIcon(at: previousCustomIconPath)
        }
        if let saved {
            if let bottlesDirectory, let bottleRuntimeOptions {
                try? await services.saveBottleRuntimeOptions(
                    bottleRuntimeOptions,
                    for: saved,
                    bottlesDirectory: bottlesDirectory
                )
            }
            if let bottlesDirectory, saved.exePath != existing?.exePath {
                await services.refreshBottleConfiguration(for: saved, bottlesDirectory: bottlesDirectory)
            }
            eventContinuation.yield(.launchGameUpdated(saved))
        }
        return saved
    }

    package func saveCustomLaunchGameIcon(from sourceURL: URL, for gameID: UUID) async -> String? {
        await services.saveCustomLaunchGameIcon(from: sourceURL, for: gameID)
    }

    package func removeCustomLaunchGameIcon(at path: String?) async {
        await services.removeCustomLaunchGameIcon(at: path)
    }

    package func invalidateLaunchGameIconCache(for game: LaunchGame) async {
        await services.invalidateLaunchGameIconCache(for: game)
    }

    package func hasBaselineSnapshot(for game: LaunchGame) -> Bool {
        services.hasBaselineSnapshot(for: game)
    }

    package func listCandidateExecutables(in directory: String) -> [String] {
        services.listCandidateExecutables(in: directory)
    }

    package func applyLaunchGamePatch(
        gameID: UUID,
        sourceURL: URL,
        settings: AppSettings
    ) async -> LaunchGamePatchOutcome {
        await applyLaunchGamePatch(gameID: gameID, sourceURLs: [sourceURL], settings: settings)
    }

    package func applyLaunchGamePatch(
        gameID: UUID,
        sourceURLs: [URL],
        settings: AppSettings
    ) async -> LaunchGamePatchOutcome {
        guard let game = await gameLibrary.game(for: gameID) else {
            return .failed("未找到对应游戏记录")
        }
        let outcome = await services.applyLaunchGamePatch(
            game: game,
            sourceURLs: sourceURLs,
            settings: settings,
            onLog: { [weak self] stageLog in
                await self?.recordLog(
                    taskID: gameID,
                    module: .patch,
                    level: stageLog.level,
                    message: stageLog.message,
                    rawOutput: stageLog.rawOutput
                )
            }
        )
        if case .applied(let updatedGame, let summary) = outcome {
            if let saved = await gameLibrary.update(updatedGame) {
                eventContinuation.yield(.launchGameUpdated(saved))
                return .applied(updatedGame: saved, summary: summary)
            }
            eventContinuation.yield(.launchGameUpdated(updatedGame))
        }
        return outcome
    }

    package func restoreBaselineSnapshot(
        for gameID: UUID,
        settings: AppSettings
    ) async -> LaunchGameRestoreOutcome {
        guard var game = await gameLibrary.game(for: gameID) else {
            return .failed("未找到对应游戏记录")
        }
        let outcome = await services.restoreBaselineSnapshot(
            for: game,
            settings: settings,
            onLog: { [weak self] stageLog in
                await self?.recordLog(
                    taskID: gameID,
                    module: .patch,
                    level: stageLog.level,
                    message: stageLog.message,
                    rawOutput: stageLog.rawOutput
                )
            }
        )
        if case .restored(let restoredExePath, let restoredLaunchArgs, _) = outcome {
            let priorExe = game.exePath
            if let restoredExePath {
                game.exePath = FileManager.default.fileExists(atPath: restoredExePath) ? restoredExePath : nil
            } else if let existingPrior = priorExe, !FileManager.default.fileExists(atPath: existingPrior) {
                game.exePath = nil
            }
            game.launchArguments = restoredLaunchArgs
            game.updatedAt = Date()
            if let saved = await gameLibrary.update(game) {
                await services.invalidateLaunchGameIconCache(for: saved)
                if saved.exePath != priorExe {
                    await services.refreshBottleConfiguration(
                        for: saved,
                        bottlesDirectory: settings.patch.bottlesDirectory
                    )
                }
                eventContinuation.yield(.launchGameUpdated(saved))
            }
        }
        return outcome
    }

    package func lookupSteamAppID(for title: String) async -> String? {
        await services.lookupSteamAppID(for: title)
    }

    package func launchGame(_ game: LaunchGame, settings: AppSettings) {
        guard workers[game.id] == nil else { return }
        let gameID = game.id
        cancelledTaskIDs.remove(gameID)
        workers[gameID] = Task { [weak self] in
            guard let self else { return }
            defer { self.workers[gameID] = nil }
            await self.services.clearCancellation(taskID: gameID)
            let storedGame = await self.gameLibrary.game(for: gameID) ?? game
            guard self.acceptsProgress(for: gameID) else { return }
            let request = GameLaunchRequest(game: storedGame, bottlesDirectory: settings.bottlesDirectory)
            let stage = self.services.launchStage(request: request)
            let result = await self.execute(
                registry: StageRegistry(stages: [stage]),
                stageID: stage.id,
                jobID: gameID,
                module: .launch,
                input: storedGame.exePath.map { ArtifactRef(kind: .file, value: $0) }
                    ?? storedGame.gameDirectory.map { ArtifactRef(kind: .directory, value: $0) }
            )
            switch result {
            case .success:
                if let updated = await self.gameLibrary.markPlayed(id: gameID, at: Date()) {
                    self.eventContinuation.yield(.launchGameUpdated(updated))
                }
            case .failure(let failure):
                self.eventContinuation.yield(.launchFailed(gameID: gameID, title: storedGame.title, message: failure.message))
            case .cancelled:
                break
            }
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
        guard acceptsProgress(for: id), !pausedTaskIDs.contains(id) else { return }
        let fraction = progress.fraction.map { stageFraction in
            progressRange.map { range in
                range.lowerBound + (range.upperBound - range.lowerBound) * stageFraction
            } ?? stageFraction
        }
        await updateJob(id, status: .running, progress: fraction, message: progress.message, rightText: progress.detail)
    }

    private func isCancelled(_ id: UUID) -> Bool {
        cancelledTaskIDs.contains(id) || pausedTaskIDs.contains(id) || Task.isCancelled
    }

    private func isCancelledOrPaused(jobID: UUID) -> Bool {
        cancelledTaskIDs.contains(jobID) || pausedTaskIDs.contains(jobID) || Task.isCancelled
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

    private func beginSleepAssertion(for jobID: UUID) -> UUID {
        let token = UUID()
        activeSleepTokens[token] = jobID
        syncIdleSleepAssertion()
        return token
    }

    private func endSleepAssertion(token: UUID) {
        activeSleepTokens.removeValue(forKey: token)
        syncIdleSleepAssertion()
    }

    private func clearSleepAssertions(for jobID: UUID) {
        activeSleepTokens = activeSleepTokens.filter { $0.value != jobID }
        syncIdleSleepAssertion()
    }

    private func syncIdleSleepAssertion() {
        let shouldPrevent = !activeSleepTokens.isEmpty
        guard shouldPrevent != isIdleSleepPrevented else { return }
        isIdleSleepPrevented = shouldPrevent
        services.setPreventIdleSleep(shouldPrevent)
    }

    private func checkDiskSpacePreflight(
        jobID: UUID,
        knownTotalBytes: Int64,
        existingStagedBytes: Int64,
        settings: AppSettings
    ) async -> Bool {
        guard knownTotalBytes > 0,
              let available = services.availableDiskSpace(atDirectory: settings.download.downloadDirectory) else {
            return true
        }
        let required = DiskSpacePreflight.requiredBytes(
            totalBytes: knownTotalBytes,
            existingStagedBytes: existingStagedBytes,
            includeUnpackReserve: settings.autoRelay
        )
        guard required > available else { return true }
        let needStr = Self.formatByteCount(required)
        let availStr = Self.formatByteCount(available)
        await recordLog(
            taskID: jobID,
            module: .download,
            level: .error,
            message: "磁盘空间不足: 需 \(needStr)，可用 \(availStr)"
        )
        await updateJob(jobID, status: .failed, message: "空间不足")
        return false
    }

    private static func formatByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func resolveWithMirrors(
        _ primaryURL: String,
        extraMirrors: [String],
        passwords: [String],
        settings: AppSettings,
        taskID: UUID? = nil
    ) async -> (result: HostResolutionResult, usedOriginURL: String, remainingMirrors: [String]) {
        let uniqueExtras = extraMirrors.filter { !$0.isEmpty && $0 != primaryURL }
        let primaryRes = await services.resolveDownloadsDetailed(primaryURL, passwords: passwords, settings: settings)
        if !primaryRes.downloads.isEmpty {
            let mapped = primaryRes.downloads.map { $0.appendingMirrors(uniqueExtras) }
            return (
                HostResolutionResult(downloads: mapped, failureReason: nil, diagnostic: primaryRes.diagnostic),
                primaryURL,
                uniqueExtras
            )
        }

        for (idx, mirror) in uniqueExtras.enumerated() {
            let mirrorRes = await services.resolveDownloadsDetailed(mirror, passwords: passwords, settings: settings)
            if !mirrorRes.downloads.isEmpty {
                let remaining = Array(uniqueExtras.dropFirst(idx + 1))
                if let taskID {
                    let host = URL(string: mirror)?.host ?? mirror
                    await recordLog(
                        taskID: taskID,
                        module: .download,
                        level: .warning,
                        message: "主源解析失败，切换备用镜像: \(host)"
                    )
                }
                let mapped = mirrorRes.downloads.map { $0.appendingMirrors(remaining) }
                return (
                    HostResolutionResult(downloads: mapped, failureReason: nil, diagnostic: mirrorRes.diagnostic),
                    mirror,
                    remaining
                )
            }
        }

        return (primaryRes, primaryURL, uniqueExtras)
    }

    private static func coalesceMirrorDownloads(_ items: [ResolvedDownload]) -> (items: [ResolvedDownload], coalescedCount: Int) {
        var bucketOrder: [String] = []
        var buckets: [String: [ResolvedDownload]] = [:]
        var unkeyed: [ResolvedDownload] = []

        for item in items {
            let candidateName = item.suggestedFilename ?? DownloadInputParser.inferFilenameFromURL(item.finalURL)
            guard let name = candidateName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  name.lowercased() != "download",
                  item.suggestedFilename != nil || name.contains(".") else {
                unkeyed.append(item)
                continue
            }
            let dir = (item.subDirectory ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let key = "\(dir)|\(name.lowercased())"
            if buckets[key] == nil {
                bucketOrder.append(key)
                buckets[key] = [item]
            } else {
                buckets[key]?.append(item)
            }
        }

        var merged: [ResolvedDownload] = []
        var coalescedCount = 0
        for key in bucketOrder {
            guard let group = buckets[key], let first = group.first else { continue }
            if group.count == 1 {
                merged.append(first)
                continue
            }
            let primaryIndex = group.firstIndex(where: { $0.rateLimitNote == nil }) ?? 0
            var primary = group[primaryIndex]
            var extraMirrors: [String] = []
            var fallbackTotalSize = primary.totalSize
            for (idx, item) in group.enumerated() where idx != primaryIndex {
                if !item.originalURL.isEmpty, item.originalURL != primary.originalURL {
                    extraMirrors.append(item.originalURL)
                }
                for m in item.mirrorURLs where m != primary.originalURL {
                    extraMirrors.append(m)
                }
                if fallbackTotalSize == nil {
                    fallbackTotalSize = item.totalSize
                }
            }
            primary = ResolvedDownload(
                originalURL: primary.originalURL,
                finalURL: primary.finalURL,
                mirrorURLs: primary.appendingMirrors(extraMirrors).mirrorURLs,
                headers: primary.headers,
                suggestedFilename: primary.suggestedFilename,
                useChunkedRange: primary.useChunkedRange,
                totalSize: fallbackTotalSize,
                subDirectory: primary.subDirectory,
                mailRuWeblink: primary.mailRuWeblink,
                maxThreads: primary.maxThreads,
                needsProxy: primary.needsProxy,
                resolverID: primary.resolverID,
                rateLimitNote: primary.rateLimitNote
            )
            merged.append(primary)
            coalescedCount += 1
        }
        merged.append(contentsOf: unkeyed)
        return (merged, coalescedCount)
    }
}
