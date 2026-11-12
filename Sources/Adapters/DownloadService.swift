import ChrysaCore
import ChrysaApplication
import Foundation

package struct DownloadProgressUpdate: Sendable {
    package var progress: Double?
    package var pill: String?
    package var rightText: String?
    package var localPath: String?
    package var resolvedTitle: String?
}

package enum DownloadOutcome: Sendable {
    case completed(localPath: String, finalTitle: String, rightText: String?)
    case cancelled
    case failed(pill: String)
}

package actor DownloadService {
    private let supervisor: ProcessSupervisor
    private var lastPrintedPctByTask: [UUID: Int] = [:]

    package init(supervisor: ProcessSupervisor = .shared) {
        self.supervisor = supervisor
    }

    package func executeDownload(
        taskID: UUID,
        currentTitle: String,
        resolved: ResolvedDownload,
        settings: AppSettings,
        isCancelled: @escaping @Sendable () async -> Bool = { Task.isCancelled },
        onProgress: @escaping @Sendable (DownloadProgressUpdate) async -> Void,
        onLog: @escaping @Sendable (String, Bool) async -> Void,
        onDiagnostic: @escaping @Sendable (StageLog) async -> Void = { _ in }
    ) async -> DownloadOutcome {
        if await supervisor.isCancelled(taskID, checking: isCancelled) { return .cancelled }
        if resolved.useChunkedRange, let totalSize = resolved.totalSize, totalSize > 0 {
            return await runChunkedRangeDownload(
                taskID: taskID,
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
        } catch {
            await onLog("error ▸ 无法准备下载目录: \(error.localizedDescription)", true)
            return .failed(pill: "目录错误")
        }

        let rawFilename = resolved.suggestedFilename ?? URL(string: resolved.finalURL)?.lastPathComponent ?? currentTitle
        guard let filename = PathSafety.safeFilename(rawFilename) else {
            await onLog("error ▸ 远端文件名无效或包含路径分隔符", true)
            return .failed(pill: "文件名无效")
        }
        let stagingDirectory = downloadsDirectory.appendingPathComponent(".chrysa-\(UUID().uuidString)", isDirectory: true)
        guard PathSafety.containedURL(stagingDirectory, in: downloadsRoot) != nil else {
            return .failed(pill: "路径无效")
        }
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        } catch {
            await onLog("error ▸ 无法建立下载暂存目录", true)
            return .failed(pill: "目录错误")
        }
        defer {
            if let safeStage = PathSafety.containedURL(stagingDirectory, in: downloadsRoot),
               safeStage.path == stagingDirectory.standardizedFileURL.path,
               safeStage.path != downloadsRoot.path {
                try? FileManager.default.removeItem(at: safeStage)
            }
        }
        let stagedFile = stagingDirectory.appendingPathComponent(filename)

        guard let aria2Path = ToolchainLocator.locateDownloadEngineBinary() else {
            await onLog("error ▸ 未找到下载内核 (sf-dl / aria2c)", true)
            return .failed(pill: "缺少内核")
        }

        let effectiveThreads = HostResolverRegistry.maxThreads(
            for: resolved.finalURL,
            configuredMax: settings.download.maxConcurrentConnections
        )
        let threadsStr = "\(effectiveThreads)"

        let customUA: String = {
            for h in resolved.headers {
                if h.lowercased().hasPrefix("user-agent:") {
                    return h.dropFirst("user-agent:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
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

        if ToolchainLocator.hostNeedsProxy(resolved.finalURL), let sysProxy = ToolchainLocator.detectSystemProxy() {
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

        do {
            let result = try await supervisor.run(
                executable: aria2Path,
                arguments: args,
                taskID: taskID,
                captureOutput: false,
                mergeStderr: true
            ) { [weak self] chunk in
                let parsed = Self.parseAria2Chunk(chunk)
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
                do {
                    let published = try PathSafety.publishFile(from: stagedFile, toDirectory: downloadsDirectory, filename: filename)
                    await onLog("dl ▸ 下载完成: \(published.name)", true)
                    return .completed(localPath: published.url.path, finalTitle: published.name, rightText: streamRight)
                } catch {
                    await onLog("error ▸ 无法安全发布下载文件: \(error.localizedDescription)", true)
                    return .failed(pill: "发布失败")
                }
            } else {
                await onDiagnostic(StageLog(
                    "error ▸ 下载内核异常退出 (代码 \(result.exitCode))",
                    level: .error,
                    rawOutput: LogEntry.sanitizeRawOutput(result.diagnosticOutput)
                ))
                return .failed(pill: "失败")
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

    private func logConsoleProgressIfNeeded(taskID: UUID, title: String, pct: Int, pill: String?, right: String?) {
        if pct != lastPrintedPctByTask[taskID], (pct % 5 == 0 || pct <= 2 || pct >= 98) {
            lastPrintedPctByTask[taskID] = pct
            print("  ↳ [DL] \(title): \(pct)% | \(pill ?? "") | \(right ?? "")")
            fflush(stdout)
        }
    }

    private static func parseAria2Chunk(_ output: String) -> DownloadProgressUpdate {
        var upd = DownloadProgressUpdate()
        if let pctMatch = try? NSRegularExpression(pattern: #"\(([0-9]{1,3})%\)"#).firstMatch(
            in: output, range: NSRange(output.startIndex..., in: output)
        ), let r = Range(pctMatch.range(at: 1), in: output), let pctVal = Double(output[r]) {
            upd.progress = max(0.03, min(0.99, pctVal / 100.0))
        }

        if let dlMatch = try? NSRegularExpression(pattern: #"DL:([0-9.]+[KMG]i?B)"#).firstMatch(
            in: output, range: NSRange(output.startIndex..., in: output)
        ), let r = Range(dlMatch.range(at: 1), in: output) {
            upd.pill = "\(output[r])/s"
        }

        if let sizeMatch = try? NSRegularExpression(pattern: #"([0-9.]+[KMG]i?B/[0-9.]+[KMG]i?B)"#).firstMatch(
            in: output, range: NSRange(output.startIndex..., in: output)
        ), let r = Range(sizeMatch.range(at: 1), in: output) {
            upd.rightText = String(output[r])
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

    private func runChunkedRangeDownload(
        taskID: UUID,
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
        } catch {
            await onLog("error ▸ 无法准备下载目录", true)
            return .failed(pill: "目录错误")
        }
        let rawFilename = resolved.suggestedFilename ?? URL(string: resolved.finalURL)?.lastPathComponent ?? "Download_\(UUID().uuidString).7z"
        guard let filename = PathSafety.safeFilename(rawFilename) else {
            await onLog("error ▸ 远端文件名无效或包含路径分隔符", true)
            return .failed(pill: "文件名无效")
        }
        let temporaryURL = downloadsDirectory.appendingPathComponent(".chrysa-range-\(UUID().uuidString).tmp")
        guard PathSafety.containedURL(temporaryURL, in: downloadsRoot) != nil else { return .failed(pill: "路径无效") }
        defer {
            if let safeTemporary = PathSafety.containedURL(temporaryURL, in: downloadsRoot),
               safeTemporary.path == temporaryURL.standardizedFileURL.path,
               safeTemporary.path != downloadsRoot.path {
                try? FileManager.default.removeItem(at: safeTemporary)
            }
        }

        await onLog("range-3m ▸ 检测到 VikingFile 限速策略，启用 8 路 × 3MB 切片校验引擎！", true)

        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil),
              let fileHandle = FileHandle(forWritingAtPath: temporaryURL.path) else {
            return .failed(pill: "写入失败")
        }
        do {
            try fileHandle.truncate(atOffset: UInt64(totalSize))
            try fileHandle.close()
        } catch {
            try? fileHandle.close()
            await onLog("error ▸ 无法预分配分片文件: \(error.localizedDescription)", true)
            return .failed(pill: "写入失败")
        }
        let destPath = temporaryURL.path

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

        let startTime = Date()
        let batchSize = min(8, max(2, settings.download.maxConcurrentConnections))
        var completedBytes: Int64 = 0
        let totalGB = Double(totalSize) / (1024.0 * 1024.0 * 1024.0)
        var activeCDNURL = resolved.finalURL
        let supervisorRef = self.supervisor

        for batchStart in stride(from: 0, to: ranges.count, by: batchSize) {
            if await supervisorRef.isCancelled(taskID, checking: isCancelled) {
                return .cancelled
            }
            let batchEnd = min(batchStart + batchSize, ranges.count)
            let slice = Array(ranges[batchStart..<batchEnd])
            let urlSnapshot = activeCDNURL

            let chunkResults: [(Int, Int64, Int64, Data?, String?, String?)] = await withTaskGroup(
                of: (Int, Int64, Int64, Data?, String?, String?).self
            ) { group in
                for (cIdx, cStart, cEnd) in slice {
                    group.addTask {
                        let tmpChunk = FileManager.default.temporaryDirectory
                            .appendingPathComponent("chrysa_chunk_\(taskID.uuidString)_\(cIdx).bin").path
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
                                    let refreshed = await HostResolverRegistry.resolveSingleLink(resolved.originalURL, passwords: settings.unpack.passwords)
                                    if !refreshed.finalURL.isEmpty {
                                        currentURL = refreshed.finalURL
                                    }
                                }
                            }
                            let res = try? await supervisorRef.run(
                                executable: "/usr/bin/curl",
                                arguments: [
                                    "--noproxy", "*",
                                    "--http2",
                                    "--fail",
                                    "-A", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
                                    "-sS",
                                    "-r", "\(cStart)-\(cEnd)",
                                    "-o", tmpChunk,
                                    currentURL
                                ],
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

            let elapsed = max(0.1, Date().timeIntervalSince(startTime))
            let speedMB = (Double(completedBytes) / (1024.0 * 1024.0)) / elapsed
            let doneGB = Double(completedBytes) / (1024.0 * 1024.0 * 1024.0)
            let progress = min(0.99, max(0.02, Double(completedBytes) / Double(totalSize)))
            await onProgress(
                DownloadProgressUpdate(
                    progress: progress,
                    pill: String(format: "%.1f MB/s", speedMB),
                    rightText: String(format: "%.2f / %.2f GB", doneGB, totalGB),
                    localPath: nil
                )
            )
        }

        if await supervisor.isCancelled(taskID, checking: isCancelled) { return .cancelled }
        let finalRight = String(format: "%.2f GB", totalGB)
        do {
            let published = try PathSafety.publishFile(from: temporaryURL, toDirectory: downloadsDirectory, filename: filename)
            await onLog("range-3m ▸ 下载完成并通过全量切片校验: \(published.name)", true)
            return .completed(localPath: published.url.path, finalTitle: published.name, rightText: finalRight)
        } catch {
            await onLog("error ▸ 无法安全发布分片下载文件: \(error.localizedDescription)", true)
            return .failed(pill: "发布失败")
        }
    }
}
