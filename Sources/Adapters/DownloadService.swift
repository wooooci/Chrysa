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
        isCancelled: @escaping @Sendable () async -> Bool = { Task.isCancelled },
        onProgress: @escaping @Sendable (DownloadProgressUpdate) async -> Void,
        onLog: @escaping @Sendable (String, Bool) async -> Void,
        onDiagnostic: @escaping @Sendable (StageLog) async -> Void = { _ in }
    ) async -> DownloadOutcome {
        if await supervisor.isCancelled(taskID, checking: isCancelled) { return .cancelled }
        let effectiveStageJobID = stagingJobID ?? taskID

        if resolved.useChunkedRange, let totalSize = resolved.totalSize, totalSize > 0 {
            return await runChunkedRangeDownload(
                taskID: taskID,
                stagingJobID: effectiveStageJobID,
                stagingSubkey: stagingSubkey,
                resolved: resolved,
                totalSize: totalSize,
                settings: settings,
                isCancelled: isCancelled,
                onProgress: onProgress,
                onLog: onLog,
                onDiagnostic: onDiagnostic
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
                    await onLog("error ▸ 下载子目录包含不安全路径", true)
                    return .failed(pill: "路径无效")
                }
                let candidate = downloadsRoot.appendingPathComponent(subdirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
                guard let contained = PathSafety.containedURL(candidate, in: downloadsRoot) else {
                    await onLog("error ▸ 下载子目录越出下载目录", true)
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
            await onLog("error ▸ 无法准备下载目录: \(error.localizedDescription)", true)
            return .failed(pill: "目录错误")
        }

        let rawFilename = resolved.suggestedFilename ?? URL(string: resolved.finalURL)?.lastPathComponent ?? currentTitle
        guard let candidateFilename = PathSafety.safeFilename(rawFilename) else {
            await onLog("error ▸ 远端文件名无效或包含路径分隔符", true)
            return .failed(pill: "文件名无效")
        }

        // Preserve existing staged filename if resuming an existing `.aria2` download in this deterministic staging folder
        let filename = Self.existingStagedFilename(in: stagingDirectory) ?? candidateFilename
        let stagedFile = stagingDirectory.appendingPathComponent(filename)
        let hasResumeState = FileManager.default.fileExists(atPath: stagedFile.path)
            && FileManager.default.fileExists(atPath: stagedFile.path + ".aria2")
        if hasResumeState {
            await onLog("resume ▸ 检测到未完成暂存与 .aria2 控制文件，继续断点续传: \(filename)", false)
        }

        guard let aria2Path = ToolchainLocator.locateDownloadEngineBinary() else {
            await onLog("error ▸ 未找到下载内核 (sf-dl / aria2c)", true)
            return .failed(pill: "缺少内核")
        }

        let effectiveThreads = HostResolverRegistry.maxThreads(
            for: resolved.finalURL,
            resolvedMax: resolved.maxThreads,
            configuredMax: settings.download.maxConcurrentConnections
        )
        let threadsStr = "\(effectiveThreads)"

        let customUA: String = {
            for h in resolved.headers {
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

        if HostResolverRegistry.proxyNeeds(for: resolved.finalURL, resolvedNeeds: resolved.needsProxy),
           let sysProxy = ToolchainLocator.detectSystemProxy() {
            args.append("--all-proxy=\(sysProxy)")
            await onLog("proxy ▸ 海外节点通过 sf-dl 挂载系统代理: \(sysProxy) (\(threadsStr) 线程)", false)
        }
        args.append("--out=\(filename)")
        for h in resolved.headers where !h.lowercased().hasPrefix("user-agent:") {
            args.append("--header=\(h)")
        }
        args.append(resolved.finalURL)

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
        let expectedTotal = resolved.totalSize

        do {
            let result = try await supervisor.run(
                executable: aria2Path,
                arguments: args,
                taskID: taskID,
                captureOutput: false,
                mergeStderr: true
            ) { [weak self] chunk in
                let parsed = Self.parseAria2Chunk(chunk, fallbackTotal: expectedTotal)
                capture.record(path: nil, title: nil, right: parsed.rightText)
                if parsed.progress != nil || parsed.pill != nil || parsed.rightText != nil {
                    var visibleUpdate = parsed
                    visibleUpdate.localPath = nil
                    visibleUpdate.resolvedTitle = filename
                    progressEvents.submit(visibleUpdate)
                }
                if let pct = parsed.progress {
                    let pInt = Int(pct * 100.0)
                    Task {
                        await self?.logConsoleProgressIfNeeded(
                            taskID: taskID,
                            title: parsed.resolvedTitle ?? resolved.suggestedFilename ?? currentTitle,
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
                    await onLog("error ▸ 下载内核未生成预期文件", true)
                    return .failed(pill: "文件缺失")
                }

                // Anti-"Fake Success" File Guard: catch HTML error/challenge pages masquerading as archives/binaries
                if let guardFailure = ResolverHTTPHelper.validateStagedPayload(at: stagedFile, expectedFilename: filename) {
                    try? FileManager.default.removeItem(at: stagedFile)
                    try? FileManager.default.removeItem(atPath: stagedFile.path + ".aria2")
                    await onLog("error ▸ 拦截假包文件 [\(filename)] -> \(guardFailure)", true)
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
                    await onLog("dl ▸ 下载完成: \(published.name)", true)
                    return .completed(localPath: published.url.path, finalTitle: published.name, rightText: streamRight)
                } catch {
                    await onLog("error ▸ 无法安全发布下载文件: \(error.localizedDescription)", true)
                    return .failed(pill: "发布失败")
                }
            } else {
                let failurePill = Self.classifyAria2Exit(exitCode: result.exitCode, diagnostic: result.diagnosticOutput)
                await onDiagnostic(StageLog(
                    "error ▸ 下载内核异常退出 (代码 \(result.exitCode) · \(failurePill))",
                    level: .error,
                    rawOutput: LogEntry.sanitizeRawOutput(result.diagnosticOutput)
                ))
                return .failed(pill: failurePill)
            }
        } catch {
            await progressEvents.drain()
            if await supervisor.isCancelled(taskID, checking: isCancelled) {
                return .cancelled
            }
            await onLog("error ▸ 无法启动下载内核: \(error.localizedDescription)", false)
            return .failed(pill: "启动失败")
        }
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
                    await onLog("error ▸ 下载子目录包含不安全路径", true)
                    return .failed(pill: "路径无效")
                }
                let candidate = downloadsRoot.appendingPathComponent(subdirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
                guard let contained = PathSafety.containedURL(candidate, in: downloadsRoot) else {
                    await onLog("error ▸ 下载子目录越出下载目录", true)
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
            await onLog("error ▸ 无法准备下载目录", true)
            return .failed(pill: "目录错误")
        }

        let rawFilename = resolved.suggestedFilename ?? URL(string: resolved.finalURL)?.lastPathComponent ?? "Download_\(UUID().uuidString).7z"
        guard let candidateFilename = PathSafety.safeFilename(rawFilename) else {
            await onLog("error ▸ 远端文件名无效或包含路径分隔符", true)
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
            await onLog("range-3m ▸ 检测到已完成的切片位图 (\(completedIndices.count)/\(ranges.count))，断点续传中...", true)
        } else {
            await onLog("range-3m ▸ 启用 8 路 × 3MB 切片校验引擎 (\(ranges.count) 片)", true)
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
                await onLog("error ▸ 无法预分配分片文件: \(error.localizedDescription)", true)
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
        let useProxy = HostResolverRegistry.proxyNeeds(for: resolved.finalURL, resolvedNeeds: resolved.needsProxy)
        let proxyArg = useProxy ? ToolchainLocator.detectSystemProxy() : nil

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
                                        passwords: settings.unpack.passwords
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
                        await onLog("error ▸ 切片 #\(cIdx) 写入失败: \(error.localizedDescription)", true)
                        return .failed(pill: "写入失败")
                    }
                } else {
                    try? writer.close()
                    await onDiagnostic(StageLog(
                        "error ▸ 切片 #\(cIdx) (\(cStart)-\(cEnd)) 5 次重试后校验失败，已中止",
                        level: .error,
                        rawOutput: errDiag.flatMap { LogEntry.sanitizeRawOutput($0) }
                    ))
                    return .failed(pill: "切片校验失败")
                }
            }
            do {
                try writer.close()
            } catch {
                await onLog("error ▸ 分片文件关闭失败: \(error.localizedDescription)", true)
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
            await onLog("error ▸ 拦截假包文件 [\(filename)] -> \(guardFailure)", true)
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
            await onLog("range-3m ▸ 下载完成并通过全量切片校验: \(published.name)", true)
            return .completed(localPath: published.url.path, finalTitle: published.name, rightText: finalRight)
        } catch {
            await onLog("error ▸ 无法安全发布分片下载文件: \(error.localizedDescription)", true)
            return .failed(pill: "发布失败")
        }
    }
}
