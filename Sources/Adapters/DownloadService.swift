import ChrysaCore
import ChrysaApplication
import Foundation

package struct DownloadProgressUpdate: Sendable {
    package var progress: Double?
    package var pill: String?
    package var rightText: String?
    package var localPath: String?
    package var resolvedTitle: String?
    package var downloadedBytes: Int64?
    package var totalBytes: Int64?
    package var speedBytesPerSec: Double?
}

package enum DownloadOutcome: Sendable {
    case completed(localPath: String, finalTitle: String, rightText: String?)
    case cancelled
    case failed(pill: String)
}

package struct ChunkBitmapState: Codable, Equatable, Sendable {
    package var totalSize: Int64
    package var chunkSize: Int64
    package var completedIndices: [Int]
}

package actor DownloadService {
    private let supervisor: ProcessSupervisor
    private var lastPrintedPctByTask: [UUID: Int] = [:]

    package init(supervisor: ProcessSupervisor = .shared) {
        self.supervisor = supervisor
    }

    package static func stagingRootURL(downloadDirectory: String) throws -> URL {
        let downloadsRoot = try PathSafety.canonicalDirectory(downloadDirectory)
        guard downloadsRoot.path != "/" else {
            throw CocoaError(.fileNoSuchFile)
        }
        return downloadsRoot.appendingPathComponent(".chrysa-staging", isDirectory: true)
    }

    package static func stagingDirectoryURL(
        downloadDirectory: String,
        jobID: UUID,
        subkey: String? = nil
    ) throws -> URL {
        let downloadsRoot = try PathSafety.canonicalDirectory(downloadDirectory)
        let root = try stagingRootURL(downloadDirectory: downloadDirectory)
        var dir = root.appendingPathComponent(jobID.uuidString, isDirectory: true)
        if let subkey, !subkey.isEmpty, let safeSub = PathSafety.safeFilename(subkey) {
            dir = dir.appendingPathComponent(safeSub, isDirectory: true)
        }
        guard PathSafety.containedURL(dir, in: downloadsRoot) != nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return dir
    }

    package static func cleanupStaging(for jobID: UUID, downloadDirectory: String) {
        guard let downloadsRoot = try? PathSafety.canonicalDirectory(downloadDirectory),
              let jobStageDir = try? stagingDirectoryURL(downloadDirectory: downloadDirectory, jobID: jobID),
              let contained = PathSafety.containedURL(jobStageDir, in: downloadsRoot),
              contained.path != downloadsRoot.path else {
            return
        }
        try? FileManager.default.removeItem(at: contained)
        // Clean `.chrysa-staging` root if empty
        if let stageRoot = try? stagingRootURL(downloadDirectory: downloadDirectory),
           let items = try? FileManager.default.contentsOfDirectory(atPath: stageRoot.path),
           items.isEmpty {
            try? FileManager.default.removeItem(at: stageRoot)
        }
    }

    private static func cleanupPartStagingIfEmpty(
        stagingDirectory: URL,
        jobID: UUID,
        downloadsRoot: URL
    ) {
        guard let safeStage = PathSafety.containedURL(stagingDirectory, in: downloadsRoot),
              safeStage.path != downloadsRoot.path else {
            return
        }
        try? FileManager.default.removeItem(at: safeStage)

        let jobStageDir = downloadsRoot
            .appendingPathComponent(".chrysa-staging", isDirectory: true)
            .appendingPathComponent(jobID.uuidString, isDirectory: true)
        if let safeJobStage = PathSafety.containedURL(jobStageDir, in: downloadsRoot),
           let remaining = try? FileManager.default.contentsOfDirectory(atPath: safeJobStage.path),
           remaining.isEmpty {
            try? FileManager.default.removeItem(at: safeJobStage)
        }

        let stageRoot = downloadsRoot.appendingPathComponent(".chrysa-staging", isDirectory: true)
        if let safeRoot = PathSafety.containedURL(stageRoot, in: downloadsRoot),
           let remaining = try? FileManager.default.contentsOfDirectory(atPath: safeRoot.path),
           remaining.isEmpty {
            try? FileManager.default.removeItem(at: safeRoot)
        }
    }

    package func executeDownload(
        taskID: UUID,
        currentTitle: String,
        resolved: ResolvedDownload,
        settings: AppSettings,
        stagingJobID: UUID? = nil,
        stagingSubkey: String? = nil,
        refreshHandler: (@Sendable (ResolvedDownload, AppSettings) async -> HostResolutionResult)? = nil,
        mirrorResolveHandler: (@Sendable (String, AppSettings) async -> HostResolutionResult)? = nil,
        isCancelled: @escaping @Sendable () async -> Bool = { Task.isCancelled },
        onProgress: @escaping @Sendable (DownloadProgressUpdate) async -> Void,
        onLog: @escaping @Sendable (String, Bool) async -> Void,
        onDiagnostic: @escaping @Sendable (StageLog) async -> Void = { _ in }
    ) async -> DownloadOutcome {
        if await supervisor.isCancelled(taskID, checking: isCancelled) { return .cancelled }
        let effectiveStageJobID = stagingJobID ?? taskID

        let resolverRefresh: @Sendable (ResolvedDownload, AppSettings) async -> HostResolutionResult = refreshHandler ?? { item, cfg in
            guard !item.originalURL.isEmpty else {
                return HostResolutionResult(downloads: [], failureReason: "缺少原始分享链接")
            }
            let detailed = await HostResolverRegistry.resolveLinksDetailed(
                item.originalURL,
                passwords: cfg.unpack.passwords,
                settings: cfg.download
            )
            if !detailed.downloads.isEmpty {
                return detailed
            }
            if detailed.failureReason != nil {
                return detailed
            }
            let fallback = await HostResolverRegistry.refreshDownload(
                item,
                passwords: cfg.unpack.passwords,
                settings: cfg.download
            )
            if fallback.finalURL != item.finalURL || fallback.headers != item.headers {
                return HostResolutionResult(downloads: [fallback])
            }
            return HostResolutionResult(downloads: [], failureReason: "链接已失效")
        }

        let resolverMirror: @Sendable (String, AppSettings) async -> HostResolutionResult = mirrorResolveHandler ?? { urlStr, cfg in
            await HostResolverRegistry.resolveLinksDetailed(
                urlStr,
                passwords: cfg.unpack.passwords,
                settings: cfg.download
            )
        }

        let downloadsRoot: URL
        let downloadsDirectory: URL
        let stagingDirectory: URL
        do {
            downloadsRoot = try PathSafety.canonicalDirectory(settings.download.downloadDirectory)
            guard downloadsRoot.path != "/" else { return .failed(pill: "下载目录无效") }
            if let rawSubdirectory = resolved.subDirectory, !rawSubdirectory.isEmpty {
                guard let subdirectory = PathSafety.safeRelativeDirectory(rawSubdirectory) else {
                    await onDiagnostic(StageLog("下载子目录包含不安全路径", level: .error))
                    return .failed(pill: "路径无效")
                }
                let candidate = downloadsRoot.appendingPathComponent(subdirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
                guard let contained = PathSafety.containedURL(candidate, in: downloadsRoot) else {
                    await onDiagnostic(StageLog("下载子目录越出下载目录", level: .error))
                    return .failed(pill: "路径无效")
                }
                downloadsDirectory = contained
            } else {
                downloadsDirectory = downloadsRoot
            }

            stagingDirectory = try Self.stagingDirectoryURL(
                downloadDirectory: settings.download.downloadDirectory,
                jobID: effectiveStageJobID,
                subkey: stagingSubkey
            )
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        } catch {
            await onDiagnostic(StageLog("无法准备下载目录: \(error.localizedDescription)", level: .error))
            return .failed(pill: "目录错误")
        }

        let rawFilename = resolved.suggestedFilename ?? URL(string: resolved.finalURL)?.lastPathComponent ?? currentTitle
        guard let candidateFilename = PathSafety.safeFilename(rawFilename) else {
            await onDiagnostic(StageLog("远端文件名无效或包含路径分隔符", level: .error))
            return .failed(pill: "文件名无效")
        }

        // Preserve existing staged filename if resuming an existing `.aria2` download in this deterministic staging folder
        var filename = Self.existingStagedFilename(in: stagingDirectory) ?? candidateFilename
        var activeResolved = resolved
        var mirrorQueue = resolved.mirrorURLs
        var attemptedMirrors = 0
        let totalMirrors = resolved.mirrorURLs.count
        var didRefreshOrigin = false

        func existingPartialBytes(for name: String) -> Int64 {
            let path = stagingDirectory.appendingPathComponent(name).path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int64 {
                return size
            }
            return 0
        }

        func checkDiskPreflightIfKnown(knownTotal: Int64?, name: String) async -> Bool {
            guard let total = knownTotal, total > 0 else { return true }
            let partial = existingPartialBytes(for: name)
            let isArch = UnpackService.isArchiveFile(name) || UnpackService.isInnoSetupInstaller(name)
            let needed = DiskSpacePreflight.requiredBytes(
                totalBytes: total,
                existingStagedBytes: partial,
                includeUnpackReserve: settings.unpack.autoRelay && isArch
            )
            if let avail = DiskSpaceHelper.availableBytes(atDirectory: downloadsDirectory.path), avail < needed {
                let needStr = DiskSpaceHelper.formatBytes(needed)
                let availStr = DiskSpaceHelper.formatBytes(avail)
                await onDiagnostic(StageLog("磁盘空间不足: 需 \(needStr)，可用 \(availStr)", level: .error))
                return false
            }
            return true
        }

        if !(await checkDiskPreflightIfKnown(knownTotal: activeResolved.totalSize, name: filename)) {
            return .failed(pill: "空间不足")
        }

        func switchToNextMirror(reason: String, allowResumeIfSizeMatches: Bool) async -> Bool {
            while !mirrorQueue.isEmpty {
                let nextURL = mirrorQueue.removeFirst()
                attemptedMirrors += 1
                await onDiagnostic(StageLog("\(reason)，切换备用镜像 (\(attemptedMirrors)/\(totalMirrors))", level: .warning))
                let mirrorRes = await resolverMirror(nextURL, settings)
                guard let candidate = mirrorRes.downloads.first else {
                    continue
                }
                if !allowResumeIfSizeMatches
                    || (activeResolved.totalSize != nil && candidate.totalSize != nil && candidate.totalSize != activeResolved.totalSize) {
                    let oldStaged = stagingDirectory.appendingPathComponent(filename)
                    try? FileManager.default.removeItem(at: oldStaged)
                    try? FileManager.default.removeItem(atPath: oldStaged.path + ".aria2")
                    try? FileManager.default.removeItem(atPath: oldStaged.path + ".chrysa-chunks.json")
                    if let newName = candidate.suggestedFilename, let safeNew = PathSafety.safeFilename(newName) {
                        filename = Self.existingStagedFilename(in: stagingDirectory) ?? safeNew
                    }
                }
                activeResolved = candidate
                didRefreshOrigin = false
                return true
            }
            return false
        }

        while true {
            if await supervisor.isCancelled(taskID, checking: isCancelled) { return .cancelled }

            let stagedFile = stagingDirectory.appendingPathComponent(filename)
            let hasAria2Resume = FileManager.default.fileExists(atPath: stagedFile.path)
                && FileManager.default.fileExists(atPath: stagedFile.path + ".aria2")
            if hasAria2Resume {
                await onLog("检测到未完成暂存与 .aria2 控制文件，继续断点续传: \(filename)", false)
            }

            // Pre-flight proxy route probe & live metadata check
            let headerDict = ResolverHTTPHelper.headerDictionary(from: activeResolved.headers)
            let routeDecision = await ResolverHTTPHelper.resolveProxyRoute(
                for: activeResolved.finalURL,
                policy: settings.download.proxyPolicy,
                headers: headerDict,
                timeoutSeconds: 5
            )
            let probe = routeDecision.probe

            // Newly discovered Content-Length triggers preflight check too
            if activeResolved.totalSize == nil, let probedSize = probe?.contentLength, probedSize > 0 {
                if !(await checkDiskPreflightIfKnown(knownTotal: probedSize, name: filename)) {
                    return .failed(pill: "空间不足")
                }
            }

            // Handle expired/failed direct URL caught during pre-transfer probe
            if let probe, (probe.statusCode == 403 || probe.statusCode == 410) {
                if !didRefreshOrigin && !activeResolved.originalURL.isEmpty {
                    await onDiagnostic(StageLog("直链签名已过期 (HTTP \(probe.statusCode))，正在从原分享页刷新...", level: .warning))
                    let refreshedRes = await resolverRefresh(activeResolved, settings)
                    if let matched = Self.pickMatchingDownload(from: refreshedRes.downloads, preferredFilename: filename) {
                        activeResolved = Self.mergedRefreshedDownload(current: activeResolved, refreshed: matched)
                        didRefreshOrigin = true
                        await onLog("直链已刷新，沿用暂存进度继续续传", false)
                        continue
                    } else if await switchToNextMirror(reason: refreshedRes.failureReason ?? "原分享链接已失效", allowResumeIfSizeMatches: true) {
                        continue
                    } else {
                        let reason = refreshedRes.failureReason ?? "链接已失效"
                        await onDiagnostic(StageLog("原分享链接刷新失败: \(reason)", level: .error))
                        return .failed(pill: reason)
                    }
                } else if await switchToNextMirror(reason: "直链失效 (HTTP \(probe.statusCode))", allowResumeIfSizeMatches: true) {
                    continue
                }
            } else if let probeFailure = ResolverHTTPHelper.validateDownloadProbe(probe) {
                if await switchToNextMirror(reason: probeFailure, allowResumeIfSizeMatches: true) {
                    continue
                }
                if probe?.statusCode == 404 || probeFailure == "今日额度已满" || probeFailure == "需访问密码" {
                    await onDiagnostic(StageLog(probeFailure, level: .error))
                    return .failed(pill: probeFailure)
                }
            }

            let isPixeldrain = activeResolved.resolverID == "pixeldrain" || activeResolved.finalURL.lowercased().contains("pixeldrain.com")
            let hasPixeldrainAuth = activeResolved.headers.contains { $0.lowercased().hasPrefix("authorization: basic") }
            var detectedRateLimit = activeResolved.rateLimitNote
            if isPixeldrain && !hasPixeldrainAuth {
                if let probe,
                   probe.statusCode == 429
                    || probe.headers["x-bandwidth-limit"] != nil
                    || probe.headers["download-speed-limit"] != nil {
                    detectedRateLimit = "限速 1MB/s"
                }
            }
            if detectedRateLimit == "限速 1MB/s" {
                if !mirrorQueue.isEmpty, await switchToNextMirror(reason: "主源触发服务端 1MB/s 限速", allowResumeIfSizeMatches: true) {
                    continue
                }
                await onProgress(DownloadProgressUpdate(pill: "限速 1MB/s"))
                await onDiagnostic(StageLog("服务端触发 1MB/s 限速，可在设置配置 Pixeldrain API Key 或切换节点", level: .warning))
            }

            if activeResolved.useChunkedRange, let totalSize = activeResolved.totalSize ?? probe?.contentLength, totalSize > 0 {
                let chunkOutcome = await runChunkedRangeDownload(
                    taskID: taskID,
                    stagingJobID: effectiveStageJobID,
                    stagingSubkey: stagingSubkey,
                    resolved: activeResolved,
                    totalSize: totalSize,
                    settings: settings,
                    initialRoute: routeDecision.route,
                    routeNote: routeDecision.note,
                    isCancelled: isCancelled,
                    onProgress: onProgress,
                    onLog: onLog,
                    onDiagnostic: onDiagnostic
                )
                switch chunkOutcome {
                case .completed, .cancelled:
                    return chunkOutcome
                case .failed(let pill):
                    if await switchToNextMirror(reason: "主源下载中断 (\(pill))", allowResumeIfSizeMatches: true) {
                        continue
                    }
                    return .failed(pill: pill)
                }
            }

            guard let aria2Path = ToolchainLocator.locateDownloadEngineBinary() else {
                await onDiagnostic(StageLog("未找到下载内核 (sf-dl / aria2c)", level: .error))
                return .failed(pill: "缺少内核")
            }

            let effectiveThreads = HostResolverRegistry.maxThreads(
                for: activeResolved.finalURL,
                resolvedMax: activeResolved.maxThreads,
                configuredMax: settings.download.maxConcurrentConnections
            )
            let threadsStr = "\(effectiveThreads)"

            let customUA: String = {
                for h in activeResolved.headers {
                    if h.lowercased().hasPrefix("user-agent:") {
                        return h.dropFirst("user-agent:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                return ResolverHTTPHelper.browserUserAgent
            }()

            var args = [
                "--no-conf",
                "-c",
                "-x", threadsStr,
                "-s", threadsStr,
                "-k", "1M",
                "-U", customUA,
                "--file-allocation=none",
                "--dir=\(stagingDirectory.path)",
                "--summary-interval=1",
                "--console-log-level=warn",
                "--allow-overwrite=true"
            ]

            let childEnv: [String: String]?
            switch routeDecision.route {
            case .proxy(let sysProxy):
                args.append("--all-proxy=\(sysProxy)")
                childEnv = nil
                await onLog("\(routeDecision.note) (\(threadsStr) 线程)", false)
            case .direct:
                args.append("--all-proxy=")
                childEnv = ResolverHTTPHelper.cleanedDirectEnvironment()
                await onLog("\(routeDecision.note) (\(threadsStr) 线程)", false)
            }
            args.append("--out=\(filename)")
            for h in activeResolved.headers where !h.lowercased().hasPrefix("user-agent:") {
                args.append("--header=\(h)")
            }
            args.append(activeResolved.finalURL)

            final class StreamCapture: @unchecked Sendable {
                private let lock = NSLock()
                var detectedPath: String? = nil
                var detectedTitle: String? = nil
                var lastRightText: String? = nil
                func record(path: String?, title: String?, right: String?) {
                    lock.lock()
                    if let p = path { detectedPath = p }
                    if let t = title { detectedTitle = t }
                    if let r = right { lastRightText = r }
                    lock.unlock()
                }
                func snapshot() -> (String?, String?, String?) {
                    lock.lock()
                    defer { lock.unlock() }
                    return (detectedPath, detectedTitle, lastRightText)
                }
            }
            let capture = StreamCapture()
            let progressEvents = StageEventQueue<DownloadProgressUpdate> { update in
                await onProgress(update)
            }
            let expectedTotal = activeResolved.totalSize ?? probe?.contentLength
            let rateLimitNoteSnapshot = detectedRateLimit
            let snapshotFilename = filename
            let snapshotFallbackTitle = activeResolved.suggestedFilename

            do {
                let result = try await supervisor.run(
                    executable: aria2Path,
                    arguments: args,
                    environment: childEnv,
                    taskID: taskID,
                    captureOutput: false,
                    mergeStderr: true
                ) { [weak self] chunk in
                    var parsed = Self.parseAria2Chunk(chunk, fallbackTotal: expectedTotal)
                    if rateLimitNoteSnapshot == "限速 1MB/s",
                       let spd = parsed.speedBytesPerSec,
                       spd > 0,
                       spd <= 1_250_000 {
                        parsed.pill = "限速 1MB/s"
                    }
                    capture.record(path: nil, title: nil, right: parsed.rightText)
                    if parsed.progress != nil || parsed.pill != nil || parsed.rightText != nil {
                        var visibleUpdate = parsed
                        visibleUpdate.localPath = nil
                        visibleUpdate.resolvedTitle = snapshotFilename
                        progressEvents.submit(visibleUpdate)
                    }
                    if let pct = parsed.progress {
                        let pInt = Int(pct * 100.0)
                        Task {
                            await self?.logConsoleProgressIfNeeded(
                                taskID: taskID,
                                title: parsed.resolvedTitle ?? snapshotFallbackTitle ?? currentTitle,
                                pct: pInt,
                                pill: parsed.pill,
                                right: parsed.rightText
                            )
                        }
                    }
                }

                await progressEvents.drain()

                if await supervisor.isCancelled(taskID, checking: isCancelled) {
                    return .cancelled
                }

                let (_, _, streamRight) = capture.snapshot()
                if result.exitCode == 0 {
                    guard FileManager.default.fileExists(atPath: stagedFile.path) else {
                        if await switchToNextMirror(reason: "下载文件缺失", allowResumeIfSizeMatches: false) {
                            continue
                        }
                        await onDiagnostic(StageLog("下载内核未生成预期文件", level: .error))
                        return .failed(pill: "文件缺失")
                    }

                    // Anti-"Fake Success" File Guard: catch HTML error/challenge pages masquerading as archives/binaries
                    if let guardFailure = ResolverHTTPHelper.validateStagedPayload(at: stagedFile, expectedFilename: filename) {
                        try? FileManager.default.removeItem(at: stagedFile)
                        try? FileManager.default.removeItem(atPath: stagedFile.path + ".aria2")
                        if await switchToNextMirror(reason: "主源返回无效页面 (\(guardFailure))", allowResumeIfSizeMatches: false) {
                            continue
                        }
                        await onDiagnostic(StageLog("拦截假包文件 [\(filename)] · \(guardFailure)", level: .error))
                        return .failed(pill: guardFailure)
                    }

                    do {
                        let published = try PathSafety.publishFile(
                            from: stagedFile,
                            toDirectory: downloadsDirectory,
                            filename: filename,
                            allowedSourceRoot: downloadsRoot
                        )
                        Self.cleanupPartStagingIfEmpty(
                            stagingDirectory: stagingDirectory,
                            jobID: effectiveStageJobID,
                            downloadsRoot: downloadsRoot
                        )
                        await onLog("下载完成: \(published.name)", true)
                        return .completed(localPath: published.url.path, finalTitle: published.name, rightText: streamRight)
                    } catch {
                        await onDiagnostic(StageLog("无法发布下载文件: \(error.localizedDescription)", level: .error))
                        return .failed(pill: "发布失败")
                    }
                } else {
                    if Self.isExpiredDirectLinkExit(exitCode: result.exitCode, diagnostic: result.diagnosticOutput),
                       !didRefreshOrigin,
                       !activeResolved.originalURL.isEmpty {
                        await onDiagnostic(StageLog("直链已过期 (HTTP 403/410)，正在从原分享页刷新并延续进度...", level: .warning))
                        let refreshedRes = await resolverRefresh(activeResolved, settings)
                        if let matched = Self.pickMatchingDownload(from: refreshedRes.downloads, preferredFilename: filename) {
                            activeResolved = Self.mergedRefreshedDownload(current: activeResolved, refreshed: matched)
                            didRefreshOrigin = true
                            await onLog("直链已刷新，沿用 .aria2 进度继续续传", false)
                            continue
                        } else if await switchToNextMirror(reason: refreshedRes.failureReason ?? "原分享页已失效", allowResumeIfSizeMatches: true) {
                            continue
                        } else {
                            let failureReason = refreshedRes.failureReason ?? "链接已失效"
                            await onDiagnostic(StageLog(
                                "原分享链接确认失效: \(failureReason)",
                                level: .error,
                                rawOutput: LogEntry.sanitizeRawOutput(result.diagnosticOutput, redact: settings.download.redactedSecrets)
                            ))
                            return .failed(pill: failureReason)
                        }
                    }

                    let failurePill = Self.classifyAria2Exit(exitCode: result.exitCode, diagnostic: result.diagnosticOutput)
                    if await switchToNextMirror(reason: "主源失败 (\(failurePill))", allowResumeIfSizeMatches: true) {
                        continue
                    }

                    await onDiagnostic(StageLog(
                        "下载异常退出 (代码 \(result.exitCode) · \(failurePill))",
                        level: .error,
                        rawOutput: LogEntry.sanitizeRawOutput(result.diagnosticOutput, redact: settings.download.redactedSecrets)
                    ))
                    return .failed(pill: failurePill)
                }
            } catch {
                await progressEvents.drain()
                if await supervisor.isCancelled(taskID, checking: isCancelled) {
                    return .cancelled
                }
                if await switchToNextMirror(reason: "内核启动异常", allowResumeIfSizeMatches: true) {
                    continue
                }
                await onDiagnostic(StageLog("无法启动下载内核: \(error.localizedDescription)", level: .error))
                return .failed(pill: "启动失败")
            }
        }
    }

    private static func pickMatchingDownload(
        from candidates: [ResolvedDownload],
        preferredFilename: String
    ) -> ResolvedDownload? {
        guard !candidates.isEmpty else { return nil }
        return candidates.first {
            $0.suggestedFilename?.caseInsensitiveCompare(preferredFilename) == .orderedSame
        } ?? candidates.first
    }

    private static func mergedRefreshedDownload(
        current: ResolvedDownload,
        refreshed: ResolvedDownload
    ) -> ResolvedDownload {
        ResolvedDownload(
            originalURL: current.originalURL,
            finalURL: refreshed.finalURL,
            mirrorURLs: current.mirrorURLs,
            headers: refreshed.headers,
            suggestedFilename: current.suggestedFilename ?? refreshed.suggestedFilename,
            useChunkedRange: refreshed.useChunkedRange,
            totalSize: refreshed.totalSize ?? current.totalSize,
            subDirectory: current.subDirectory ?? refreshed.subDirectory,
            mailRuWeblink: refreshed.mailRuWeblink ?? current.mailRuWeblink,
            maxThreads: refreshed.maxThreads ?? current.maxThreads,
            needsProxy: refreshed.needsProxy ?? current.needsProxy,
            resolverID: refreshed.resolverID ?? current.resolverID,
            rateLimitNote: refreshed.rateLimitNote
        )
    }

    package static func isExpiredDirectLinkExit(exitCode: Int32, diagnostic: String) -> Bool {
        let lower = diagnostic.lowercased()
        if lower.contains("403") || lower.contains("forbidden") || lower.contains("410") || lower.contains("gone") {
            return true
        }
        return false
    }

    private static func existingStagedFilename(in stagingDirectory: URL) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path) else {
            return nil
        }
        for name in entries where name.hasSuffix(".aria2") {
            let base = String(name.dropLast(".aria2".count))
            if !base.isEmpty, FileManager.default.fileExists(atPath: stagingDirectory.appendingPathComponent(base).path) {
                return base
            }
        }
        for name in entries where name.hasSuffix(".chrysa-chunks.json") {
            let base = String(name.dropLast(".chrysa-chunks.json".count))
            if !base.isEmpty, FileManager.default.fileExists(atPath: stagingDirectory.appendingPathComponent(base).path) {
                return base
            }
        }
        return nil
    }

    private static func classifyAria2Exit(exitCode: Int32, diagnostic: String) -> String {
        let lower = diagnostic.lowercased()
        if lower.contains("404") || lower.contains("not found") || lower.contains("410") {
            return "链接已失效"
        }
        if lower.contains("401") || lower.contains("unauthorized") {
            return "需访问密码"
        }
        if lower.contains("429") || lower.contains("too many requests") || lower.contains("quota") {
            return "今日额度已满"
        }
        if lower.contains("403") || lower.contains("forbidden") {
            return "链接已失效"
        }
        if exitCode == 22 || exitCode == 3 {
            return "链接已失效"
        }
        return "下载中断"
    }

    private func logConsoleProgressIfNeeded(taskID: UUID, title: String, pct: Int, pill: String?, right: String?) {
        if pct != lastPrintedPctByTask[taskID], (pct % 5 == 0 || pct <= 2 || pct >= 98) {
            lastPrintedPctByTask[taskID] = pct
            print("  ↳ [DL] \(title): \(pct)% | \(pill ?? "") | \(right ?? "")")
            fflush(stdout)
        }
    }

    package static func parseAria2Chunk(_ output: String, fallbackTotal: Int64? = nil) -> DownloadProgressUpdate {
        var upd = DownloadProgressUpdate()
        if let pctMatch = try? NSRegularExpression(pattern: #"\(([0-9]{1,3})%\)"#).firstMatch(
            in: output, range: NSRange(output.startIndex..., in: output)
        ), let r = Range(pctMatch.range(at: 1), in: output), let pctVal = Double(output[r]) {
            upd.progress = max(0.03, min(0.99, pctVal / 100.0))
        }

        if let dlMatch = try? NSRegularExpression(pattern: #"DL:([0-9.]+[KMG]i?B)"#).firstMatch(
            in: output, range: NSRange(output.startIndex..., in: output)
        ), let r = Range(dlMatch.range(at: 1), in: output) {
            let speedStr = String(output[r])
            upd.pill = "\(speedStr)/s"
            upd.speedBytesPerSec = parseByteSize(speedStr).map(Double.init)
        }

        if let sizeMatch = try? NSRegularExpression(pattern: #"([0-9.]+[KMG]i?B)/([0-9.]+[KMG]i?B)"#).firstMatch(
            in: output, range: NSRange(output.startIndex..., in: output)
        ), let r1 = Range(sizeMatch.range(at: 1), in: output),
           let r2 = Range(sizeMatch.range(at: 2), in: output),
           let full = Range(sizeMatch.range, in: output) {
            upd.rightText = String(output[full])
            upd.downloadedBytes = parseByteSize(String(output[r1]))
            upd.totalBytes = parseByteSize(String(output[r2])) ?? fallbackTotal
        }

        if let pathMatch = try? NSRegularExpression(pattern: #"(?:Download complete:|下载完成：)\s*(.+)"#).firstMatch(
            in: output, range: NSRange(output.startIndex..., in: output)
        ), let r = Range(pathMatch.range(at: 1), in: output) {
            let p = String(output[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            upd.localPath = p
            upd.resolvedTitle = (p as NSString).lastPathComponent
        }
        return upd
    }

    private static func parseByteSize(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let units: [(String, Double)] = [
            ("GiB", 1024 * 1024 * 1024),
            ("MiB", 1024 * 1024),
            ("KiB", 1024),
            ("GB", 1000 * 1000 * 1000),
            ("MB", 1000 * 1000),
            ("KB", 1000),
            ("B", 1)
        ]
        for (suffix, mult) in units where trimmed.hasSuffix(suffix) {
            let numStr = String(trimmed.dropLast(suffix.count))
            if let v = Double(numStr) {
                return Int64(v * mult)
            }
        }
        return nil
    }

    private func runChunkedRangeDownload(
        taskID: UUID,
        stagingJobID: UUID,
        stagingSubkey: String?,
        resolved: ResolvedDownload,
        totalSize: Int64,
        settings: AppSettings,
        initialRoute: ProxyRouteDecision = .direct,
        routeNote: String = "直连通道",
        isCancelled: @escaping @Sendable () async -> Bool,
        onProgress: @escaping @Sendable (DownloadProgressUpdate) async -> Void,
        onLog: @escaping @Sendable (String, Bool) async -> Void,
        onDiagnostic: @escaping @Sendable (StageLog) async -> Void = { _ in }
    ) async -> DownloadOutcome {
        let downloadsRoot: URL
        let downloadsDirectory: URL
        let stagingDirectory: URL
        do {
            downloadsRoot = try PathSafety.canonicalDirectory(settings.download.downloadDirectory)
            guard downloadsRoot.path != "/" else { return .failed(pill: "下载目录无效") }
            if let rawSubdirectory = resolved.subDirectory, !rawSubdirectory.isEmpty {
                guard let subdirectory = PathSafety.safeRelativeDirectory(rawSubdirectory) else {
                    await onDiagnostic(StageLog("下载子目录包含不安全路径", level: .error))
                    return .failed(pill: "路径无效")
                }
                let candidate = downloadsRoot.appendingPathComponent(subdirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
                guard let contained = PathSafety.containedURL(candidate, in: downloadsRoot) else {
                    await onDiagnostic(StageLog("下载子目录越出下载目录", level: .error))
                    return .failed(pill: "路径无效")
                }
                downloadsDirectory = contained
            } else {
                downloadsDirectory = downloadsRoot
            }

            stagingDirectory = try Self.stagingDirectoryURL(
                downloadDirectory: settings.download.downloadDirectory,
                jobID: stagingJobID,
                subkey: stagingSubkey
            )
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        } catch {
            await onDiagnostic(StageLog("无法准备下载目录", level: .error))
            return .failed(pill: "目录错误")
        }

        let rawFilename = resolved.suggestedFilename ?? URL(string: resolved.finalURL)?.lastPathComponent ?? "Download_\(UUID().uuidString).7z"
        guard let candidateFilename = PathSafety.safeFilename(rawFilename) else {
            await onDiagnostic(StageLog("远端文件名无效或包含路径分隔符", level: .error))
            return .failed(pill: "文件名无效")
        }
        let filename = Self.existingStagedFilename(in: stagingDirectory) ?? candidateFilename
        let stagedDataURL = stagingDirectory.appendingPathComponent(filename)
        let bitmapURL = stagingDirectory.appendingPathComponent(filename + ".chrysa-chunks.json")
        guard PathSafety.containedURL(stagedDataURL, in: downloadsRoot) != nil else {
            return .failed(pill: "路径无效")
        }

        let chunkSize: Int64 = 3 * 1024 * 1024
        var ranges: [(Int, Int64, Int64)] = []
        var cur: Int64 = 0
        var idx = 0
        while cur < totalSize {
            let end = min(cur + chunkSize - 1, totalSize - 1)
            ranges.append((idx, cur, end))
            cur = end + 1
            idx += 1
        }

        var completedIndices: Set<Int> = []
        let canResumeExisting: Bool = {
            guard FileManager.default.fileExists(atPath: stagedDataURL.path),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: stagedDataURL.path),
                  let existingSize = attrs[.size] as? Int64,
                  existingSize == totalSize,
                  let stateData = try? Data(contentsOf: bitmapURL),
                  let decoded = try? JSONDecoder().decode(ChunkBitmapState.self, from: stateData),
                  decoded.totalSize == totalSize,
                  decoded.chunkSize == chunkSize else {
                return false
            }
            completedIndices = Set(decoded.completedIndices.filter { $0 >= 0 && $0 < ranges.count })
            return true
        }()

        if canResumeExisting {
            await onLog("检测到切片位图 (\(completedIndices.count)/\(ranges.count))，断点续传中...", false)
        } else {
            await onLog("\(routeNote)，启用 8 路 × 3MB 切片校验 (\(ranges.count) 片)", false)
            guard FileManager.default.createFile(atPath: stagedDataURL.path, contents: nil),
                  let fileHandle = FileHandle(forWritingAtPath: stagedDataURL.path) else {
                return .failed(pill: "写入失败")
            }
            do {
                try fileHandle.truncate(atOffset: UInt64(totalSize))
                try fileHandle.close()
                let initState = ChunkBitmapState(totalSize: totalSize, chunkSize: chunkSize, completedIndices: [])
                if let encoded = try? JSONEncoder().encode(initState) {
                    try encoded.write(to: bitmapURL, options: [.atomic])
                }
            } catch {
                try? fileHandle.close()
                await onDiagnostic(StageLog("无法预分配分片文件: \(error.localizedDescription)", level: .error))
                return .failed(pill: "写入失败")
            }
        }

        let destPath = stagedDataURL.path
        let pendingRanges = ranges.filter { !completedIndices.contains($0.0) }
        var completedBytes: Int64 = completedIndices.reduce(0) { acc, cIdx in
            let r = ranges[cIdx]
            return acc + (r.2 - r.1 + 1)
        }
        let sessionInitialBytes = completedBytes
        let startTime = Date()
        let batchSize = min(8, max(2, settings.download.maxConcurrentConnections))
        let totalGB = Double(totalSize) / (1024.0 * 1024.0 * 1024.0)
        var activeCDNURL = resolved.finalURL
        let supervisorRef = self.supervisor
        let proxyArg = initialRoute.proxyAddress
        let directEnv: [String: String]? = proxyArg == nil ? ResolverHTTPHelper.cleanedDirectEnvironment() : nil

        if completedBytes > 0 {
            let doneGB = Double(completedBytes) / (1024.0 * 1024.0 * 1024.0)
            let progress = min(0.99, max(0.02, Double(completedBytes) / Double(totalSize)))
            await onProgress(
                DownloadProgressUpdate(
                    progress: progress,
                    pill: "续传中",
                    rightText: String(format: "%.2f / %.2f GB", doneGB, totalGB),
                    downloadedBytes: completedBytes,
                    totalBytes: totalSize
                )
            )
        }

        for batchStart in stride(from: 0, to: pendingRanges.count, by: batchSize) {
            if await supervisorRef.isCancelled(taskID, checking: isCancelled) {
                return .cancelled
            }
            let batchEnd = min(batchStart + batchSize, pendingRanges.count)
            let slice = Array(pendingRanges[batchStart..<batchEnd])
            let urlSnapshot = activeCDNURL

            let chunkResults: [(Int, Int64, Int64, Data?, String?, String?)] = await withTaskGroup(
                of: (Int, Int64, Int64, Data?, String?, String?).self
            ) { group in
                for (cIdx, cStart, cEnd) in slice {
                    group.addTask {
                        let tmpChunk = stagingDirectory
                            .appendingPathComponent(".chunk_\(cIdx).bin").path
                        defer { try? FileManager.default.removeItem(atPath: tmpChunk) }
                        let expectedBytes = Int(cEnd - cStart + 1)
                        var currentURL = urlSnapshot
                        var lastDiag: String? = nil

                        for attempt in 0...5 {
                            if await supervisorRef.isCancelled(taskID, checking: isCancelled) {
                                return (cIdx, cStart, cEnd, nil, nil, nil)
                            }
                            if attempt > 0 {
                                try? FileManager.default.removeItem(atPath: tmpChunk)
                                let delayNs = UInt64(Double(attempt) * 1.2 * 1_000_000_000)
                                try? await Task.sleep(nanoseconds: delayNs)
                                if await supervisorRef.isCancelled(taskID, checking: isCancelled) {
                                    return (cIdx, cStart, cEnd, nil, nil, nil)
                                }
                                if attempt >= 2 {
                                    let refreshed = await HostResolverRegistry.refreshDownload(
                                        resolved,
                                        passwords: settings.unpack.passwords,
                                        settings: settings.download
                                    )
                                    if !refreshed.finalURL.isEmpty {
                                        currentURL = refreshed.finalURL
                                    }
                                }
                            }
                            var curlArgs: [String] = []
                            if let proxyArg {
                                curlArgs += ["-x", proxyArg]
                            } else {
                                curlArgs += ["--noproxy", "*"]
                            }
                            curlArgs += [
                                "--http2",
                                "--fail",
                                "-A", ResolverHTTPHelper.browserUserAgent,
                                "-sS",
                                "-r", "\(cStart)-\(cEnd)",
                                "-o", tmpChunk
                            ]
                            for h in resolved.headers where !h.lowercased().hasPrefix("user-agent:") {
                                curlArgs += ["-H", h]
                            }
                            curlArgs.append(currentURL)

                            let res = try? await supervisorRef.run(
                                executable: "/usr/bin/curl",
                                arguments: curlArgs,
                                environment: directEnv,
                                taskID: taskID
                            )
                            if res?.exitCode == 0,
                               let d = try? Data(contentsOf: URL(fileURLWithPath: tmpChunk)),
                               d.count == expectedBytes {
                                return (cIdx, cStart, cEnd, d, currentURL, nil)
                            }
                            if let diag = res?.diagnosticOutput, !diag.isEmpty {
                                lastDiag = diag
                            }
                        }
                        return (cIdx, cStart, cEnd, nil, nil, lastDiag)
                    }
                }

                var collected: [(Int, Int64, Int64, Data?, String?, String?)] = []
                for await item in group {
                    collected.append(item)
                }
                return collected.sorted { $0.0 < $1.0 }
            }

            if await supervisorRef.isCancelled(taskID, checking: isCancelled) {
                return .cancelled
            }

            guard let writer = FileHandle(forWritingAtPath: destPath) else {
                return .failed(pill: "写入失败")
            }

            for (cIdx, cStart, cEnd, dataOpt, updatedURL, errDiag) in chunkResults {
                if let u = updatedURL, u != activeCDNURL {
                    activeCDNURL = u
                }
                if let verified = dataOpt {
                    do {
                        try writer.seek(toOffset: UInt64(cStart))
                        try writer.write(contentsOf: verified)
                        completedBytes += Int64(verified.count)
                        completedIndices.insert(cIdx)
                    } catch {
                        try? writer.close()
                        await onDiagnostic(StageLog("切片 #\(cIdx) 写入失败: \(error.localizedDescription)", level: .error))
                        return .failed(pill: "写入失败")
                    }
                } else {
                    try? writer.close()
                    await onDiagnostic(StageLog(
                        "切片 #\(cIdx) (\(cStart)-\(cEnd)) 重试后校验失败，已中止",
                        level: .error,
                        rawOutput: errDiag.flatMap { LogEntry.sanitizeRawOutput($0, redact: settings.download.redactedSecrets) }
                    ))
                    return .failed(pill: "切片校验失败")
                }
            }
            do {
                try writer.close()
            } catch {
                await onDiagnostic(StageLog("分片文件关闭失败: \(error.localizedDescription)", level: .error))
                return .failed(pill: "写入失败")
            }

            let updatedBitmap = ChunkBitmapState(
                totalSize: totalSize,
                chunkSize: chunkSize,
                completedIndices: completedIndices.sorted()
            )
            if let encoded = try? JSONEncoder().encode(updatedBitmap) {
                try? encoded.write(to: bitmapURL, options: [.atomic])
            }

            let elapsed = max(0.1, Date().timeIntervalSince(startTime))
            let sessionBytes = max(0, completedBytes - sessionInitialBytes)
            let speedBytesPerSec = Double(sessionBytes) / elapsed
            let speedMB = speedBytesPerSec / (1024.0 * 1024.0)
            let doneGB = Double(completedBytes) / (1024.0 * 1024.0 * 1024.0)
            let progress = min(0.99, max(0.02, Double(completedBytes) / Double(totalSize)))
            await onProgress(
                DownloadProgressUpdate(
                    progress: progress,
                    pill: String(format: "%.1f MB/s", speedMB),
                    rightText: String(format: "%.2f / %.2f GB", doneGB, totalGB),
                    localPath: nil,
                    downloadedBytes: completedBytes,
                    totalBytes: totalSize,
                    speedBytesPerSec: speedBytesPerSec
                )
            )
        }

        if await supervisor.isCancelled(taskID, checking: isCancelled) { return .cancelled }

        if let guardFailure = ResolverHTTPHelper.validateStagedPayload(at: stagedDataURL, expectedFilename: filename) {
            try? FileManager.default.removeItem(at: stagedDataURL)
            try? FileManager.default.removeItem(at: bitmapURL)
            await onDiagnostic(StageLog("拦截假包文件 [\(filename)] · \(guardFailure)", level: .error))
            return .failed(pill: guardFailure)
        }

        let finalRight = String(format: "%.2f GB", totalGB)
        do {
            let published = try PathSafety.publishFile(
                from: stagedDataURL,
                toDirectory: downloadsDirectory,
                filename: filename,
                allowedSourceRoot: downloadsRoot
            )
            try? FileManager.default.removeItem(at: bitmapURL)
            Self.cleanupPartStagingIfEmpty(
                stagingDirectory: stagingDirectory,
                jobID: stagingJobID,
                downloadsRoot: downloadsRoot
            )
            await onLog("下载完成: \(published.name)", true)
            return .completed(localPath: published.url.path, finalTitle: published.name, rightText: finalRight)
        } catch {
            await onDiagnostic(StageLog("无法发布下载文件: \(error.localizedDescription)", level: .error))
            return .failed(pill: "发布失败")
        }
    }
}
