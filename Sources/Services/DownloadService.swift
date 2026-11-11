import Foundation

struct DownloadProgressUpdate: Sendable {
    var progress: Double?
    var pill: String?
    var rightText: String?
    var localPath: String?
    var resolvedTitle: String?
}

enum DownloadOutcome: Sendable {
    case completed(localPath: String, finalTitle: String, rightText: String?)
    case cancelled
    case failed(pill: String)
}

actor DownloadService {
    private let supervisor: ProcessSupervisor
    private var lastPrintedPctByTask: [UUID: Int] = [:]

    init(supervisor: ProcessSupervisor = .shared) {
        self.supervisor = supervisor
    }

    func executeDownload(
        taskID: UUID,
        currentTitle: String,
        resolved: ResolvedDownload,
        settings: AppSettings,
        onProgress: @escaping @Sendable (DownloadProgressUpdate) -> Void,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async -> DownloadOutcome {
        await supervisor.clearCancellation(for: taskID)

        if resolved.useChunkedRange, let totalSize = resolved.totalSize, totalSize > 0 {
            return await runChunkedRangeDownload(
                taskID: taskID,
                resolved: resolved,
                totalSize: totalSize,
                settings: settings,
                onProgress: onProgress,
                onLog: onLog
            )
        }

        let baseDownloadsDir = (settings.downloadDirectory as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: baseDownloadsDir, withIntermediateDirectories: true)

        let downloadsDir: String = {
            if let sub = resolved.subDirectory, !sub.isEmpty {
                let d = (baseDownloadsDir as NSString).appendingPathComponent(sub)
                try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
                return d
            }
            return baseDownloadsDir
        }()

        guard let aria2Path = ToolchainLocator.locateDownloadEngineBinary() else {
            onLog("error ▸ 未找到下载内核 (sf-dl / aria2c)", true)
            return .failed(pill: "缺少内核")
        }

        let lowerFinal = resolved.finalURL.lowercased()
        let isPixeldrain = lowerFinal.contains("pixeldrain.com")
        let isFileDitch = lowerFinal.contains("fileditch")
        let configuredMax = max(1, min(16, settings.maxConcurrentConnections))
        let effectiveThreads = isFileDitch ? min(2, configuredMax) : (isPixeldrain ? min(4, configuredMax) : configuredMax)
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
            "--dir=\(downloadsDir)",
            "--summary-interval=1",
            "--console-log-level=warn",
            "--allow-overwrite=true"
        ]

        if ToolchainLocator.hostNeedsProxy(resolved.finalURL), let sysProxy = ToolchainLocator.detectSystemProxy() {
            args.append("--all-proxy=\(sysProxy)")
            onLog("proxy ▸ 海外节点通过 sf-dl 挂载系统代理: \(sysProxy) (\(threadsStr) 线程)", false)
        }
        if let name = resolved.suggestedFilename, !name.isEmpty {
            args.append("--out=\(name)")
        }
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

        do {
            let result = try await supervisor.run(
                executable: aria2Path,
                arguments: args,
                taskID: taskID,
                captureOutput: false,
                mergeStderr: true
            ) { [weak self] chunk in
                let parsed = Self.parseAria2Chunk(chunk)
                capture.record(path: parsed.localPath, title: parsed.resolvedTitle, right: parsed.rightText)
                if parsed.progress != nil || parsed.pill != nil || parsed.rightText != nil || parsed.localPath != nil {
                    onProgress(parsed)
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

            if await supervisor.isCancelled(taskID) {
                return .cancelled
            }

            let (streamPath, streamTitle, streamRight) = capture.snapshot()
            if result.exitCode == 0 {
                let finalTitle = streamTitle ?? resolved.suggestedFilename ?? currentTitle
                let fallbackPath: String = {
                    if let name = resolved.suggestedFilename, !name.isEmpty {
                        return (downloadsDir as NSString).appendingPathComponent(name)
                    }
                    return (downloadsDir as NSString).appendingPathComponent(finalTitle)
                }()
                let finalPath = streamPath ?? fallbackPath
                onLog("dl ▸ 下载完成: \(finalTitle)", true)
                return .completed(localPath: finalPath, finalTitle: finalTitle, rightText: streamRight)
            } else {
                onLog("dl ▸ 进程退出码 \(result.exitCode)", false)
                return .failed(pill: "失败")
            }
        } catch {
            if await supervisor.isCancelled(taskID) {
                return .cancelled
            }
            onLog("error ▸ 无法启动下载内核: \(error.localizedDescription)", false)
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
        onProgress: @escaping @Sendable (DownloadProgressUpdate) -> Void,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async -> DownloadOutcome {
        let downloadsDir = (settings.downloadDirectory as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: downloadsDir, withIntermediateDirectories: true)
        let filename = resolved.suggestedFilename ?? "Download_\(Int(Date().timeIntervalSince1970)).7z"
        let destPath = (downloadsDir as NSString).appendingPathComponent(filename)

        onLog("range-3m ▸ 检测到 VikingFile 限速策略，启用 8 路 × 3MB 切片校验引擎！", true)

        FileManager.default.createFile(atPath: destPath, contents: nil)
        guard let fileHandle = FileHandle(forWritingAtPath: destPath) else {
            return .failed(pill: "写入失败")
        }
        try? fileHandle.truncate(atOffset: UInt64(totalSize))
        try? fileHandle.close()

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
        let batchSize = min(8, max(2, settings.maxConcurrentConnections))
        var completedBytes: Int64 = 0
        let totalGB = Double(totalSize) / (1024.0 * 1024.0 * 1024.0)
        var activeCDNURL = resolved.finalURL
        let supervisorRef = self.supervisor

        for batchStart in stride(from: 0, to: ranges.count, by: batchSize) {
            if await supervisorRef.isCancelled(taskID) {
                return .cancelled
            }
            let batchEnd = min(batchStart + batchSize, ranges.count)
            let slice = Array(ranges[batchStart..<batchEnd])
            let urlSnapshot = activeCDNURL

            let chunkResults: [(Int, Int64, Int64, Data?, String?)] = await withTaskGroup(
                of: (Int, Int64, Int64, Data?, String?).self
            ) { group in
                for (cIdx, cStart, cEnd) in slice {
                    group.addTask {
                        let tmpChunk = "/tmp/chrysa_chunk_\(taskID.uuidString)_\(cIdx).bin"
                        defer { try? FileManager.default.removeItem(atPath: tmpChunk) }
                        let expectedBytes = Int(cEnd - cStart + 1)
                        var currentURL = urlSnapshot

                        for attempt in 0...5 {
                            if await supervisorRef.isCancelled(taskID) {
                                return (cIdx, cStart, cEnd, nil, nil)
                            }
                            if attempt > 0 {
                                try? FileManager.default.removeItem(atPath: tmpChunk)
                                let delayNs = UInt64(Double(attempt) * 1.2 * 1_000_000_000)
                                try? await Task.sleep(nanoseconds: delayNs)
                                if attempt >= 2 {
                                    let refreshed = await HostResolverRegistry.resolveSingleLink(resolved.originalURL)
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
                                    "-s",
                                    "-r", "\(cStart)-\(cEnd)",
                                    "-o", tmpChunk,
                                    currentURL
                                ],
                                taskID: taskID
                            )
                            if res?.exitCode == 0,
                               let d = try? Data(contentsOf: URL(fileURLWithPath: tmpChunk)),
                               d.count == expectedBytes {
                                return (cIdx, cStart, cEnd, d, currentURL)
                            }
                        }
                        return (cIdx, cStart, cEnd, nil, nil)
                    }
                }

                var collected: [(Int, Int64, Int64, Data?, String?)] = []
                for await item in group {
                    collected.append(item)
                }
                return collected.sorted { $0.0 < $1.0 }
            }

            if await supervisorRef.isCancelled(taskID) {
                return .cancelled
            }

            guard let writer = FileHandle(forWritingAtPath: destPath) else {
                return .failed(pill: "写入失败")
            }

            for (cIdx, cStart, cEnd, dataOpt, updatedURL) in chunkResults {
                if let u = updatedURL, u != activeCDNURL {
                    activeCDNURL = u
                }
                if let verified = dataOpt {
                    try? writer.seek(toOffset: UInt64(cStart))
                    try? writer.write(contentsOf: verified)
                    completedBytes += Int64(verified.count)
                } else {
                    try? writer.close()
                    onLog("error ▸ 切片 #\(cIdx) (\(cStart)-\(cEnd)) 5 次重试后仍未通过字节数校验，已中止以防损坏压缩包！", true)
                    return .failed(pill: "切片校验失败")
                }
            }
            try? writer.close()

            let elapsed = max(0.1, Date().timeIntervalSince(startTime))
            let speedMB = (Double(completedBytes) / (1024.0 * 1024.0)) / elapsed
            let doneGB = Double(completedBytes) / (1024.0 * 1024.0 * 1024.0)
            let progress = min(0.99, max(0.02, Double(completedBytes) / Double(totalSize)))
            onProgress(
                DownloadProgressUpdate(
                    progress: progress,
                    pill: String(format: "%.1f MB/s", speedMB),
                    rightText: String(format: "%.2f / %.2f GB", doneGB, totalGB),
                    localPath: destPath
                )
            )
        }

        let finalRight = String(format: "%.2f GB", totalGB)
        onLog("range-3m ▸ 下载完成并通过全量切片校验: \(filename)", true)
        return .completed(localPath: destPath, finalTitle: filename, rightText: finalRight)
    }
}
