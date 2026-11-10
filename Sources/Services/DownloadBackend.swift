import SwiftUI
import AppKit
import JavaScriptCore
import CryptoKit

@MainActor
extension StudioViewModel {
    // MARK: - 1. DOWNLOAD BACKEND (Host Resolvers + MirrorUploadX/FileDitch Rescue + Direct Stream + aria2c 16x)
    nonisolated static func normalizeDownloadInput(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("magnet:") {
            return trimmed
        }
        let lower = trimmed.lowercased()
        let knownDomains = [
            "gofile.io/", "www.gofile.io/",
            "pixeldrain.com/", "www.pixeldrain.com/",
            "buzzheavier.com/", "www.buzzheavier.com/",
            "vikingfile.com/", "www.vikingfile.com/",
            "itsfileditchfiles.st/", "fileditchfiles.st/", "fileditch.com/",
            "mirroruploadx.com/", "www.mirroruploadx.com/",
            "cloud.mail.ru/",
            "mediafire.com/", "www.mediafire.com/",
            "drive.google.com/",
            "mega.nz/",
            "1fichier.com/"
        ]
        if knownDomains.contains(where: { lower.hasPrefix($0) }) {
            return "https://" + trimmed
        }
        if !trimmed.contains(" "),
           let slashIdx = trimmed.firstIndex(of: "/"),
           trimmed[..<slashIdx].contains(".") {
            return "https://" + trimmed
        }
        return nil
    }

    func startDownloadFromInputOrClipboard() {
        let raw = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            urlInput = ""
            startDownload(urlString: Self.normalizeDownloadInput(raw) ?? raw)
            return
        }
        if let clip = NSPasteboard.general.string(forType: .string),
           let normalized = Self.normalizeDownloadInput(clip) {
            startDownload(urlString: normalized)
            return
        }
        pickFileForActiveTab()
    }

    nonisolated static func decodeBase64FilenameIfPossible(_ raw: String) -> String? {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count >= 24 else { return nil }
        var b64 = candidate
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem > 0 {
            b64 += String(repeating: "=", count: 4 - rem)
        }
        guard let data = Data(base64Encoded: b64),
              let decoded = String(data: data, encoding: .utf8),
              decoded.contains("/") else {
            return nil
        }
        let last = (decoded as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty && last.contains(".") {
            return last
        }
        return nil
    }

    func startDownload(urlString: String) {
        let cleanURL = Self.normalizeDownloadInput(urlString) ?? urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return }

        let rawLast = URL(string: cleanURL)?.lastPathComponent ?? ""
        let guessedName: String = {
            if let decoded = Self.decodeBase64FilenameIfPossible(rawLast) {
                return decoded
            }
            if !rawLast.isEmpty {
                return rawLast
            }
            return "Download_\(Int(Date().timeIntervalSince1970)).7z"
        }()

        let isMirrorWait = cleanURL.lowercased().contains("mirroruploadx.com") || cleanURL.lowercased().contains("fileditch")
        let firstTaskID = UUID()
        let newTask = StudioTask(
            id: firstTaskID,
            title: guessedName,
            status: .running(0.02),
            pill: isMirrorWait ? "优选分流 (约10s)" : "嗅探中",
            rightText: "准备中",
            sourceURL: cleanURL
        )
        downloadTasks.insert(newTask, at: 0)
        appendLog("sniff ▸ 开始解析链接: \(cleanURL)", highlight: true)

        Task.detached { [weak self] in
            let resolvedList = await Self.resolveHostLinks(cleanURL)
            guard let first = resolvedList.first else {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    if let idx = self.downloadTasks.firstIndex(where: { $0.id == firstTaskID }) {
                        self.downloadTasks[idx].status = .failed
                        self.downloadTasks[idx].pill = "解析失败"
                        self.downloadTasks[idx].rightText = "无法获取直链"
                    }
                    self.appendLog("error ▸ 无法从该分享页解析出有效文件直链: \(cleanURL)", highlight: true)
                }
                return
            }

            if resolvedList.count == 1 {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    if let idx = self.downloadTasks.firstIndex(where: { $0.id == firstTaskID }) {
                        if let name = first.suggestedFilename, !name.isEmpty {
                            self.downloadTasks[idx].title = name
                        }
                        self.downloadTasks[idx].pill = "连接中"
                    }
                    self.appendLog("dl ▸ 启动高速下载: \(first.suggestedFilename ?? first.finalURL)", highlight: false)
                }
                await self?.runAria2Download(taskID: firstTaskID, resolved: first)
            } else {
                // Multi-file shared folder (e.g. cloud.mail.ru or gofile folder with setup.exe + .bin + DLCs)
                var taskPairs: [(UUID, ResolvedDownload)] = [(firstTaskID, first)]
                for item in resolvedList.dropFirst() {
                    taskPairs.append((UUID(), item))
                }
                let finalPairs = taskPairs
                let folderTitle = first.subDirectory ?? "多文件目录"
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    if let idx = self.downloadTasks.firstIndex(where: { $0.id == firstTaskID }) {
                        self.downloadTasks[idx].title = first.suggestedFilename ?? guessedName
                        self.downloadTasks[idx].pill = "队列 1/\(finalPairs.count)"
                    }
                    for (idxOffset, pair) in finalPairs.dropFirst().enumerated() {
                        let t = StudioTask(
                            id: pair.0,
                            title: pair.1.suggestedFilename ?? "分卷文件",
                            status: .queued,
                            pill: "队列 \(idxOffset + 2)/\(finalPairs.count)",
                            rightText: pair.1.totalSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "待下载"
                        )
                        self.downloadTasks.insert(t, at: min(idxOffset + 1, self.downloadTasks.count))
                    }
                    self.appendLog("folder ▸ 检测到分享文件夹 [\(folderTitle)]，共 \(finalPairs.count) 个文件，开始顺序拉取...", highlight: true)
                }

                let dlRoot = ("~/Downloads" as NSString).expandingTildeInPath
                let folderDir = first.subDirectory.map { (dlRoot as NSString).appendingPathComponent($0) } ?? dlRoot
                let allNames = finalPairs.compactMap { $0.1.suggestedFilename }
                let primaryFile = allNames.first(where: { Self.isArchiveFile($0) })
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

                for (tID, rawItem) in finalPairs {
                    let freshItem = await Self.refreshMailRuURLIfNeeded(rawItem)
                    await self?.runAria2Download(taskID: tID, resolved: freshItem, suppressAutoRelay: true)
                    if let fname = freshItem.suggestedFilename {
                        let fullPath = (folderDir as NSString).appendingPathComponent(fname)
                        if FileManager.default.fileExists(atPath: fullPath) {
                            completedFiles.insert(fname)
                        }
                    }

                    // If base game (setup.exe + its -1.bin slices) is ready and there are still DLCs remaining, start unpacking base game immediately!
                    if !baseUnpackTriggered,
                       let prim = primaryFile,
                       completedFiles.contains(prim),
                       requiredBinSlices.isSubset(of: completedFiles) {
                        baseUnpackTriggered = true
                        let fullPrimary = (folderDir as NSString).appendingPathComponent(prim)
                        let hasRemainingDLCs = completedFiles.count < finalPairs.count
                        await MainActor.run { [weak self] in
                            guard let self = self, self.autoRelay else { return }
                            if hasRemainingDLCs {
                                self.appendLog("relay ▸ 主程序与数据卷已就绪，先行流转至 [解压]: \(prim) (DLC 后台继续下载)", highlight: true)
                            } else {
                                self.appendLog("relay ▸ 文件夹全部下载完成，自动流转至 [解压]: \(prim)", highlight: true)
                            }
                            self.activeTab = .unpack
                            self.startUnpack(filePath: fullPrimary)
                        }
                    } else if baseUnpackTriggered,
                              let fname = freshItem.suggestedFilename,
                              fname.lowercased().hasPrefix("setup_") && fname.lowercased().hasSuffix(".exe") {
                        // A subsequent DLC setup_*.exe finished after base game unpack started; merge it into the base game folder
                        let fullDLC = (folderDir as NSString).appendingPathComponent(fname)
                        if FileManager.default.fileExists(atPath: fullDLC), let prim = primaryFile {
                            var rawBase = (prim as NSString).deletingPathExtension
                            if rawBase.lowercased().hasPrefix("setup_") {
                                rawBase = String(rawBase.dropFirst("setup_".count))
                            }
                            let baseOutDir = (folderDir as NSString).appendingPathComponent(Self.cleanGameTitle(from: rawBase))
                            await MainActor.run { [weak self] in
                                self?.appendLog("innoextract ▸ DLC 下载完成，正在合并至主游戏目录: \(fname)", highlight: true)
                            }
                            let p = Process()
                            p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/innoextract")
                            p.arguments = ["-e", "-m", "-g", "--collisions=overwrite", "-s", "-d", baseOutDir, fullDLC]
                            p.standardOutput = FileHandle.nullDevice
                            p.standardError = FileHandle.nullDevice
                            try? p.run()
                            p.waitUntilExit()
                            await MainActor.run { [weak self] in
                                self?.appendLog("innoextract ▸ DLC 合并完成: \(fname)", highlight: true)
                            }
                        }
                    }
                }
            }
        }
    }

    struct ResolvedDownload: Sendable {
        let originalURL: String
        let finalURL: String
        let headers: [String]
        let suggestedFilename: String?
        let useChunkedRange: Bool
        let totalSize: Int64?
        let subDirectory: String?
        let mailRuWeblink: String?

        init(
            originalURL: String = "",
            finalURL: String,
            headers: [String],
            suggestedFilename: String?,
            useChunkedRange: Bool = false,
            totalSize: Int64? = nil,
            subDirectory: String? = nil,
            mailRuWeblink: String? = nil
        ) {
            self.originalURL = originalURL.isEmpty ? finalURL : originalURL
            self.finalURL = finalURL
            self.headers = headers
            self.suggestedFilename = suggestedFilename
            self.useChunkedRange = useChunkedRange
            self.totalSize = totalSize
            self.subDirectory = subDirectory
            self.mailRuWeblink = mailRuWeblink
        }
    }

    nonisolated static func refreshMailRuURLIfNeeded(_ item: ResolvedDownload) async -> ResolvedDownload {
        guard let itemWeblink = item.mailRuWeblink,
              let dispURL = URL(string: "https://cloud.mail.ru/api/v2/dispatcher"),
              let (dispData, _) = try? await URLSession.shared.data(from: dispURL),
              let dispJSON = try? JSONSerialization.jsonObject(with: dispData) as? [String: Any],
              let dispBody = dispJSON["body"] as? [String: Any],
              let weblinkGet = dispBody["weblink_get"] as? [[String: Any]],
              let baseURL = weblinkGet.first?["url"] as? String else {
            return item
        }
        let encodedPath = itemWeblink
            .components(separatedBy: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: "/")
        let freshDirectURL = "\(baseURL)/\(encodedPath)"
        return ResolvedDownload(
            originalURL: item.originalURL,
            finalURL: freshDirectURL,
            headers: item.headers,
            suggestedFilename: item.suggestedFilename,
            useChunkedRange: item.useChunkedRange,
            totalSize: item.totalSize,
            subDirectory: item.subDirectory,
            mailRuWeblink: item.mailRuWeblink
        )
    }

    nonisolated static func detectSystemProxy() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        proc.arguments = ["--proxy"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        guard let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return nil
        }
        var enabled = false
        var host: String? = nil
        var port: String? = nil
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("HTTPEnable :") && line.hasSuffix("1") {
                enabled = true
            } else if line.hasPrefix("HTTPProxy :") {
                host = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line.hasPrefix("HTTPPort :") {
                port = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if enabled, let h = host, let p = port, !h.isEmpty, !p.isEmpty {
            return "http://\(h):\(p)"
        }
        return nil
    }

    nonisolated static func hostNeedsProxy(_ urlString: String) -> Bool {
        let lower = urlString.lowercased()
        // VikingFile, Buzzheavier, and Mail.ru CDNs are fast via direct connection
        if lower.contains("vikingfile.com") || lower.contains("buzzheavier.com") || lower.contains("mail.ru") {
            return false
        }
        let proxyHosts = [
            "gofile.io",
            "itsfileditchfiles.st",
            "fileditchfiles.st",
            "fileditch.com",
            "mirroruploadx.com",
            "drive.google.com",
            "drive.usercontent.google.com",
            "googleusercontent.com",
            "pixeldrain.com",
            "mediafire.com",
            "mega.nz",
            "1fichier.com",
            "github.com",
            "githubusercontent.com"
        ]
        return proxyHosts.contains { lower.contains($0) }
    }

    nonisolated static func resolveHostLinks(_ input: String) async -> [ResolvedDownload] {
        guard let url = URL(string: input), let host = url.host?.lowercased() else {
            return [ResolvedDownload(originalURL: input, finalURL: input, headers: [], suggestedFilename: nil)]
        }

        // 0. FileDitch JDownloader / CDN Base64 token link (e.g. .../MTc5NDMxOTEyMD... -> decode exact .rar/.7z filename and stream directly!)
        if let decodedFilename = decodeBase64FilenameIfPossible(url.lastPathComponent) {
            return [
                ResolvedDownload(
                    originalURL: input,
                    finalURL: input,
                    headers: [],
                    suggestedFilename: decodedFilename
                )
            ]
        }

        // Mail.ru Cloud: https://cloud.mail.ru/public/<weblink> (supports both single file and multi-file folder)
        if host.contains("cloud.mail.ru") {
            return await resolveMailRu(input: input, url: url)
        }

        // Gofile: https://gofile.io/d/<id> (supports both single file and multi-file folder)
        if host.contains("gofile.io") {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 2 && parts[0] == "d" {
                return await resolveGofileList(contentId: parts[1])
            }
        }

        // MirrorUploadX: https://mirroruploadx.com/f/<slug> -> auto-select Gofile or VikingFile high-speed mirror (NEVER fall through to downloading 43KB HTML!)
        if host.contains("mirroruploadx.com") {
            return await resolveMirrorUploadX(urlString: input)
        }

        // FileDitch webpage: https://itsfileditchfiles.st/<user>/<hash>/<file> -> auto-rescue Gofile/VikingFile mirror via MirrorUploadX history or browser JDownloader link
        if host.contains("fileditch") {
            return await resolveFileDitchOrMirror(input: input, url: url)
        }

        let single = await resolveHostLink(input)
        return [single]
    }

    nonisolated static func findMirrorUploadXInFirefoxHistory(filename: String) -> String? {
        guard !filename.isEmpty else { return nil }
        let ffRoot = ("~/Library/Application Support/Firefox/Profiles" as NSString).expandingTildeInPath
        guard let profiles = try? FileManager.default.contentsOfDirectory(atPath: ffRoot) else { return nil }
        let safeName = filename.replacingOccurrences(of: "'", with: "''")
        for prof in profiles {
            let dbPath = (ffRoot as NSString).appendingPathComponent("\(prof)/places.sqlite")
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }
            let tmpBase = "/tmp/sf_ff_places_\(UUID().uuidString).sqlite"
            try? FileManager.default.copyItem(atPath: dbPath, toPath: tmpBase)
            if FileManager.default.fileExists(atPath: dbPath + "-wal") {
                try? FileManager.default.copyItem(atPath: dbPath + "-wal", toPath: tmpBase + "-wal")
            }
            if FileManager.default.fileExists(atPath: dbPath + "-shm") {
                try? FileManager.default.copyItem(atPath: dbPath + "-shm", toPath: tmpBase + "-shm")
            }
            defer {
                try? FileManager.default.removeItem(atPath: tmpBase)
                try? FileManager.default.removeItem(atPath: tmpBase + "-wal")
                try? FileManager.default.removeItem(atPath: tmpBase + "-shm")
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            let sql = "SELECT url FROM moz_places WHERE url LIKE 'https://mirroruploadx.com/f/%' AND title LIKE '%\(safeName)%' ORDER BY last_visit_date DESC LIMIT 1;"
            proc.arguments = [tmpBase, sql]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            proc.waitUntilExit()
            if out.hasPrefix("https://mirroruploadx.com/f/") {
                return out
            }
        }
        return nil
    }

    nonisolated static func resolveMirrorUploadX(urlString: String) async -> [ResolvedDownload] {
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:150.0) Gecko/20100101 Firefox/150.0"
        let fetchProc = Process()
        fetchProc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        fetchProc.arguments = ["-sL", "-A", ua, urlString]
        let fetchPipe = Pipe()
        fetchProc.standardOutput = fetchPipe
        fetchProc.standardError = FileHandle.nullDevice
        try? fetchProc.run()
        let htmlData = fetchPipe.fileHandleForReading.readDataToEndOfFile()
        fetchProc.waitUntilExit()

        guard let rawHTML = String(data: htmlData, encoding: .utf8), !rawHTML.isEmpty else {
            return []
        }
        // Unescape Next.js RSC payload quotes (\" -> ")
        let cleanHTML = rawHTML.replacingOccurrences(of: "\\\"", with: "\"")

        // Parse downloadDelaySeconds (typically 10s)
        var delaySec: Double = 10.0
        if let dMatch = try? NSRegularExpression(pattern: #""downloadDelaySeconds"\s*:\s*([0-9]+)"#).firstMatch(
            in: cleanHTML, range: NSRange(cleanHTML.startIndex..., in: cleanHTML)
        ), let r = Range(dMatch.range(at: 1), in: cleanHTML), let val = Double(cleanHTML[r]) {
            delaySec = min(max(val, 1.0), 15.0)
        }

        // Extract provider clickUrls in priority order: gofile -> vikingfile
        var preferredClickURLs: [(String, String)] = []
        let pattern = #""provider"\s*:\s*"([^"]+)"[\s\S]{1,600}?"clickUrl"\s*:\s*"([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let matches = regex.matches(in: cleanHTML, range: NSRange(cleanHTML.startIndex..., in: cleanHTML))
            var byProvider: [String: String] = [:]
            for m in matches {
                if let rProv = Range(m.range(at: 1), in: cleanHTML),
                   let rClick = Range(m.range(at: 2), in: cleanHTML) {
                    let prov = String(cleanHTML[rProv]).lowercased()
                    let rawClick = String(cleanHTML[rClick])
                    let fullClick = rawClick.hasPrefix("http") ? rawClick : "https://mirroruploadx.com\(rawClick)"
                    byProvider[prov] = fullClick
                }
            }
            for hostKey in ["gofile", "vikingfile"] {
                if let c = byProvider[hostKey] {
                    preferredClickURLs.append((hostKey, c))
                }
            }
        }

        guard !preferredClickURLs.isEmpty else { return [] }
        // Wait required countdown on MirrorUploadX session before hitting clickUrl
        try? await Task.sleep(nanoseconds: UInt64((delaySec + 0.8) * 1_000_000_000))

        for (_, clickURL) in preferredClickURLs {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            proc.arguments = ["-sI", "-A", ua, "-e", urlString, clickURL]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            let hdrText = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            proc.waitUntilExit()

            var locationURL: String? = nil
            for line in hdrText.components(separatedBy: .newlines) {
                if line.lowercased().hasPrefix("location:") {
                    let loc = line.dropFirst("location:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !loc.isEmpty && !loc.contains("mirroruploadx.com") {
                        locationURL = loc
                        break
                    }
                }
            }

            if let targetURL = locationURL {
                let resolved = await resolveHostLinks(targetURL)
                if !resolved.isEmpty {
                    return resolved
                }
            }
        }
        return []
    }

    nonisolated static func resolveFileDitchOrMirror(input: String, url: URL) async -> [ResolvedDownload] {
        let filename = url.lastPathComponent
        // 0. If this is already a FileDitch JDownloader / direct CDN link with Base64 token, decode filename and download directly!
        if let decoded = decodeBase64FilenameIfPossible(filename) {
            return [
                ResolvedDownload(
                    originalURL: input,
                    finalURL: input,
                    headers: [],
                    suggestedFilename: decoded
                )
            ]
        }

        // 1. Check if this FileDitch file came from a MirrorUploadX multi-host page in Firefox history
        if let mirrorURL = findMirrorUploadXInFirefoxHistory(filename: filename) {
            print("[MirrorUploadX] Found multi-mirror page in Firefox history for \(filename): \(mirrorURL)")
            fflush(stdout)
            let items = await resolveMirrorUploadX(urlString: mirrorURL)
            if !items.isEmpty {
                return items
            }
        }

        return []
    }

    nonisolated static func resolveMailRu(input: String, url: URL) async -> [ResolvedDownload] {
        let comps = url.pathComponents.filter { $0 != "/" }
        guard let pubIdx = comps.firstIndex(of: "public"), comps.count > pubIdx + 1 else {
            return []
        }
        let weblink = comps[(pubIdx + 1)...].joined(separator: "/")

        // 1. Query /api/v2/dispatcher for CDN base URL
        guard let dispURL = URL(string: "https://cloud.mail.ru/api/v2/dispatcher"),
              let (dispData, _) = try? await URLSession.shared.data(from: dispURL),
              let dispJSON = try? JSONSerialization.jsonObject(with: dispData) as? [String: Any],
              let dispBody = dispJSON["body"] as? [String: Any],
              let weblinkGet = dispBody["weblink_get"] as? [[String: Any]],
              let baseURL = weblinkGet.first?["url"] as? String else {
            return []
        }

        let encodedQuery = weblink.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? weblink
        if let folderURL = URL(string: "https://cloud.mail.ru/api/v2/folder?weblink=\(encodedQuery)"),
           let (fData, _) = try? await URLSession.shared.data(from: folderURL),
           let fJSON = try? JSONSerialization.jsonObject(with: fData) as? [String: Any],
           let fBody = fJSON["body"] as? [String: Any],
           let list = fBody["list"] as? [[String: Any]], !list.isEmpty {
            let folderName = (fBody["name"] as? String) ?? "mailru_folder"
            var results: [ResolvedDownload] = []
            for item in list {
                guard (item["type"] as? String) == "file",
                      let name = item["name"] as? String,
                      let itemWeblink = item["weblink"] as? String else { continue }
                let lowerName = name.lowercased()
                if lowerName.hasPrefix("#") || lowerName.hasSuffix(".md5") || lowerName.hasSuffix(".sfv") {
                    continue
                }
                let sizeVal: Int64? = {
                    if let s = item["size"] as? Int64 { return s }
                    if let n = item["size"] as? NSNumber { return n.int64Value }
                    return nil
                }()
                let encodedPath = itemWeblink
                    .components(separatedBy: "/")
                    .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
                    .joined(separator: "/")
                let directURL = "\(baseURL)/\(encodedPath)"
                results.append(
                    ResolvedDownload(
                        originalURL: input,
                        finalURL: directURL,
                        headers: [],
                        suggestedFilename: name,
                        useChunkedRange: false,
                        totalSize: sizeVal,
                        subDirectory: folderName,
                        mailRuWeblink: itemWeblink
                    )
                )
            }
            // Sort so primary setup.exe or .001/.part1 comes before -1.bin or DLCs
            results.sort { a, b in
                let na = (a.suggestedFilename ?? "").lowercased()
                let nb = (b.suggestedFilename ?? "").lowercased()
                let aIsMainSetup = na.hasPrefix("setup_") && na.hasSuffix(".exe") && !na.contains("downpour") && !na.contains("watcher") && !na.contains("dlc")
                let bIsMainSetup = nb.hasPrefix("setup_") && nb.hasSuffix(".exe") && !nb.contains("downpour") && !nb.contains("watcher") && !nb.contains("dlc")
                if aIsMainSetup != bIsMainSetup { return aIsMainSetup }
                return na < nb
            }
            if !results.isEmpty {
                return results
            }
        }

        // Single file on cloud.mail.ru
        if let fileURL = URL(string: "https://cloud.mail.ru/api/v2/file?weblink=\(encodedQuery)"),
           let (fiData, _) = try? await URLSession.shared.data(from: fileURL),
           let fiJSON = try? JSONSerialization.jsonObject(with: fiData) as? [String: Any],
           let fiBody = fiJSON["body"] as? [String: Any],
           let name = fiBody["name"] as? String {
            let sizeVal = (fiBody["size"] as? NSNumber)?.int64Value
            let encodedPath = weblink
                .components(separatedBy: "/")
                .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
                .joined(separator: "/")
            let directURL = "\(baseURL)/\(encodedPath)"
            return [
                ResolvedDownload(
                    originalURL: input,
                    finalURL: directURL,
                    headers: [],
                    suggestedFilename: name,
                    useChunkedRange: false,
                    totalSize: sizeVal,
                    mailRuWeblink: weblink
                )
            ]
        }

        return []
    }

    nonisolated static func resolveHostLink(_ input: String) async -> ResolvedDownload {
        guard let url = URL(string: input), let host = url.host?.lowercased() else {
            return ResolvedDownload(originalURL: input, finalURL: input, headers: [], suggestedFilename: nil)
        }

        if let decodedFilename = decodeBase64FilenameIfPossible(url.lastPathComponent) {
            return ResolvedDownload(
                originalURL: input,
                finalURL: input,
                headers: [],
                suggestedFilename: decodedFilename
            )
        }

        if host.contains("cloud.mail.ru") {
            if let first = await resolveMailRu(input: input, url: url).first {
                return first
            }
        }

        if host.contains("mirroruploadx.com") {
            if let first = await resolveMirrorUploadX(urlString: input).first {
                return first
            }
        }

        if host.contains("fileditch") {
            if let first = await resolveFileDitchOrMirror(input: input, url: url).first {
                return first
            }
        }

        // 0. VikingFile: https://vikingfile.com/f/ID or /d/ID/filename -> resolve 302 CDN URL once + enable 3MB Chunked Range Engine (bypasses nginx limit_rate_after 3m & 429)
        if host.contains("vikingfile.com") {
            var dURL = input
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 2 && parts[0] == "f" {
                dURL = "https://vikingfile.com/d/\(parts[1])"
            }
            let headProc = Process()
            headProc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            headProc.arguments = ["--noproxy", "*", "-sI", dURL]
            let pipe = Pipe()
            headProc.standardOutput = pipe
            try? headProc.run()
            headProc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let text = String(data: data, encoding: .utf8) {
                var cdnURL: String? = nil
                for line in text.components(separatedBy: .newlines) {
                    if line.lowercased().hasPrefix("location:") {
                        cdnURL = line.dropFirst("location:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
                if let resolvedCDN = cdnURL, !resolvedCDN.isEmpty {
                    let fname = URL(string: resolvedCDN)?.lastPathComponent ?? url.lastPathComponent
                    var totalBytes: Int64? = nil
                    let rangeProc = Process()
                    rangeProc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                    rangeProc.arguments = ["--noproxy", "*", "-sI", "-r", "0-0", resolvedCDN]
                    let rPipe = Pipe()
                    rangeProc.standardOutput = rPipe
                    try? rangeProc.run()
                    rangeProc.waitUntilExit()
                    if let rText = String(data: rPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
                        for line in rText.components(separatedBy: .newlines) {
                            if line.lowercased().hasPrefix("content-range:"),
                               let slashIdx = line.lastIndex(of: "/") {
                                let numStr = line[line.index(after: slashIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
                                totalBytes = Int64(numStr)
                            }
                        }
                    }
                    return ResolvedDownload(
                        originalURL: dURL,
                        finalURL: resolvedCDN,
                        headers: [],
                        suggestedFilename: fname,
                        useChunkedRange: true,
                        totalSize: totalBytes
                    )
                }
            }
        }

        // 1. Pixeldrain: https://pixeldrain.com/u/ID -> query /api/file/ID/info for exact name & size + /api/file/ID?download
        if host.contains("pixeldrain.com") {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 2 && (parts[0] == "u" || parts[0] == "l") {
                let id = parts[1]
                let direct = "https://pixeldrain.com/api/file/\(id)?download"
                var realName: String? = nil
                var fileSize: Int64? = nil
                if let infoURL = URL(string: "https://pixeldrain.com/api/file/\(id)/info"),
                   let (infoData, _) = try? await URLSession.shared.data(from: infoURL),
                   let json = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any] {
                    if let n = json["name"] as? String, !n.isEmpty {
                        realName = n
                    }
                    if let sz = json["size"] as? Int64 {
                        fileSize = sz
                    } else if let szNum = json["size"] as? NSNumber {
                        fileSize = szNum.int64Value
                    }
                }
                return ResolvedDownload(
                    originalURL: input,
                    finalURL: direct,
                    headers: [],
                    suggestedFilename: realName ?? "pixeldrain_\(id).7z",
                    useChunkedRange: false,
                    totalSize: fileSize
                )
            }
        }

        // 2. Buzzheavier: GET /ID/download with HX-Request: true -> hx-redirect header
        if host.contains("buzzheavier.com") {
            let parts = url.pathComponents.filter { $0 != "/" }
            if let id = parts.first {
                let dlEndpoint = "https://buzzheavier.com/\(id)/download"
                if let reqURL = URL(string: dlEndpoint) {
                    var req = URLRequest(url: reqURL)
                    req.httpMethod = "GET"
                    req.setValue("true", forHTTPHeaderField: "HX-Request")
                    req.setValue(input, forHTTPHeaderField: "Referer")
                    if let (_, resp) = try? await URLSession.shared.data(for: req),
                       let httpResp = resp as? HTTPURLResponse,
                       let redirect = httpResp.value(forHTTPHeaderField: "hx-redirect") ?? httpResp.value(forHTTPHeaderField: "Location") {
                        return ResolvedDownload(originalURL: input, finalURL: redirect, headers: ["Referer: \(input)"], suggestedFilename: nil)
                    }
                }
            }
        }

        // 3. MediaFire: scrape #downloadButton href
        if host.contains("mediafire.com") {
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let html = String(data: data, encoding: .utf8) {
                let pattern = #"href=["'](https?://download[0-9]*\.mediafire\.com/[^"']+)["']"#
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let range = Range(match.range(at: 1), in: html) {
                    let direct = String(html[range])
                    return ResolvedDownload(originalURL: input, finalURL: direct, headers: [], suggestedFilename: URL(string: direct)?.lastPathComponent)
                }
            }
        }

        // 4. Google Drive: drive.google.com/file/d/ID/view
        if host.contains("drive.google.com") {
            let parts = url.pathComponents
            if let dIdx = parts.firstIndex(of: "d"), parts.count > dIdx + 1 {
                let id = parts[dIdx + 1]
                let direct = "https://drive.usercontent.google.com/download?id=\(id)&export=download&confirm=t"
                return ResolvedDownload(originalURL: input, finalURL: direct, headers: [], suggestedFilename: nil)
            }
        }

        // 5. Gofile: gofile.io/d/ID via guest accountToken + wt token
        if host.contains("gofile.io") {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 2 && parts[0] == "d" {
                let contentId = parts[1]
                if let gofileResolved = await resolveGofileList(contentId: contentId).first {
                    return gofileResolved
                }
            }
        }

        return ResolvedDownload(originalURL: input, finalURL: input, headers: [], suggestedFilename: url.lastPathComponent)
    }

    nonisolated static func sha256HexString(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func mintGofileGuestToken(ua: String) async -> String? {
        guard let accURL = URL(string: "https://api.gofile.io/accounts") else { return nil }
        var accReq = URLRequest(url: accURL)
        accReq.httpMethod = "POST"
        accReq.setValue(ua, forHTTPHeaderField: "User-Agent")
        guard let (accData, _) = try? await URLSession.shared.data(for: accReq),
              let accJson = try? JSONSerialization.jsonObject(with: accData) as? [String: Any],
              let dataDict = accJson["data"] as? [String: Any],
              let token = dataDict["token"] as? String, !token.isEmpty else {
            return nil
        }
        UserDefaults.standard.set(token, forKey: "sf_gofile_guest_token")
        return token
    }

    nonisolated static func generateGofileWT(token: String, ua: String, lang: String) async -> String {
        let now = Date().timeIntervalSince1970
        var wtScript = UserDefaults.standard.string(forKey: "sf_gofile_wt_script")
        let savedTS = UserDefaults.standard.double(forKey: "sf_gofile_wt_ts")
        if wtScript == nil || (now - savedTS) > 7200 {
            if let wtURL = URL(string: "https://gofile.io/js/wt.obf.js") {
                var req = URLRequest(url: wtURL)
                req.setValue(ua, forHTTPHeaderField: "User-Agent")
                if let (data, _) = try? await URLSession.shared.data(for: req),
                   let text = String(data: data, encoding: .utf8),
                   text.contains("generateWT") {
                    wtScript = text
                    UserDefaults.standard.set(text, forKey: "sf_gofile_wt_script")
                    UserDefaults.standard.set(now, forKey: "sf_gofile_wt_ts")
                }
            }
        }
        if let script = wtScript, let ctx = JSContext() {
            ctx.evaluateScript("var window = globalThis; var navigator = { userAgent: \"\(ua)\", language: \"\(lang)\" };")
            ctx.evaluateScript(script)
            if let fn = ctx.objectForKeyedSubscript("generateWT"),
               let val = fn.call(withArguments: [token])?.toString(),
               !val.isEmpty, val != "undefined" {
                return val
            }
        }
        let bucket = Int(now) / 14400
        return sha256HexString("\(ua)::\(lang)::\(token)::\(bucket)::12af056dacea0b")
    }

    nonisolated static func fetchGofileContentsJSON(contentId: String, token: String, wt: String, ua: String, lang: String, passwordHash: String? = nil) async -> (Int, [String: Any]?) {
        var urlStr = "https://api.gofile.io/contents/\(contentId)?page=1&pageSize=100&sortField=name&sortDirection=1"
        if let pw = passwordHash, !pw.isEmpty {
            urlStr += "&password=\(pw)"
        }
        guard let contentURL = URL(string: urlStr) else { return (0, nil) }
        var cReq = URLRequest(url: contentURL)
        cReq.setValue(ua, forHTTPHeaderField: "User-Agent")
        cReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        cReq.setValue(wt, forHTTPHeaderField: "X-Website-Token")
        cReq.setValue(lang, forHTTPHeaderField: "X-BL")
        guard let (cData, resp) = try? await URLSession.shared.data(for: cReq) else {
            return (0, nil)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
        let json = try? JSONSerialization.jsonObject(with: cData) as? [String: Any]
        return (code, json)
    }

    nonisolated static func resolveGofileList(contentId: String, depth: Int = 0) async -> [ResolvedDownload] {
        guard depth <= 2 else { return [] }
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        let lang = "en-US"

        var token = UserDefaults.standard.string(forKey: "sf_gofile_guest_token") ?? "qmMkk3QlGAVUbei1YkhSfPaCAUqLKgsm"
        var wt = await generateGofileWT(token: token, ua: ua, lang: lang)

        var (httpCode, cJson) = await fetchGofileContentsJSON(contentId: contentId, token: token, wt: wt, ua: ua, lang: lang)
        let apiStatus = cJson?["status"] as? String
        if httpCode == 401 || httpCode == 403 || apiStatus == "error-wrongToken" || apiStatus == "error-token" {
            if let freshToken = await mintGofileGuestToken(ua: ua) {
                token = freshToken
                wt = await generateGofileWT(token: token, ua: ua, lang: lang)
                (httpCode, cJson) = await fetchGofileContentsJSON(contentId: contentId, token: token, wt: wt, ua: ua, lang: lang)
            }
        }

        guard var cRoot = cJson?["data"] as? [String: Any] else { return [] }

        // If the folder is password-protected, try passwords from our dictionary automatically
        if (cRoot["canAccess"] as? Bool) == false || (cRoot["passwordStatus"] as? String) == "passwordRequired" {
            let savedPasswords = UserDefaults.standard.stringArray(forKey: "sf_passwords_v1") ?? ["cs.rin.ru"]
            for candidate in savedPasswords {
                let pwHash = sha256HexString(candidate)
                let (_, pwJson) = await fetchGofileContentsJSON(contentId: contentId, token: token, wt: wt, ua: ua, lang: lang, passwordHash: pwHash)
                if let unlockedRoot = pwJson?["data"] as? [String: Any],
                   (unlockedRoot["canAccess"] as? Bool) == true,
                   unlockedRoot["children"] != nil {
                    cRoot = unlockedRoot
                    break
                }
            }
        }

        // Single direct file payload
        if (cRoot["type"] as? String) == "file", let directLink = cRoot["link"] as? String {
            let name = cRoot["name"] as? String
            let sz = (cRoot["size"] as? NSNumber)?.int64Value
            return [
                ResolvedDownload(
                    originalURL: "https://gofile.io/d/\(contentId)",
                    finalURL: directLink,
                    headers: ["Cookie: accountToken=\(token)"],
                    suggestedFilename: name,
                    useChunkedRange: false,
                    totalSize: sz,
                    subDirectory: nil
                )
            ]
        }

        guard let children = cRoot["children"] as? [String: Any] else { return [] }
        let folderName = (cRoot["name"] as? String)
        var list: [ResolvedDownload] = []
        for (_, rawVal) in children {
            guard let child = rawVal as? [String: Any] else { continue }
            let childType = (child["type"] as? String) ?? "file"
            if childType == "folder",
               let subId = (child["code"] as? String) ?? (child["id"] as? String) {
                let subItems = await resolveGofileList(contentId: subId, depth: depth + 1)
                list.append(contentsOf: subItems)
                continue
            }
            guard let link = child["link"] as? String else { continue }
            let name = child["name"] as? String
            let sz = (child["size"] as? NSNumber)?.int64Value
            list.append(
                ResolvedDownload(
                    originalURL: "https://gofile.io/d/\(contentId)",
                    finalURL: link,
                    headers: ["Cookie: accountToken=\(token)"],
                    suggestedFilename: name,
                    useChunkedRange: false,
                    totalSize: sz,
                    subDirectory: nil
                )
            )
        }
        let isMulti = list.count > 1
        if isMulti, let folderName = folderName, !folderName.isEmpty {
            list = list.map { item in
                ResolvedDownload(
                    originalURL: item.originalURL,
                    finalURL: item.finalURL,
                    headers: item.headers,
                    suggestedFilename: item.suggestedFilename,
                    useChunkedRange: item.useChunkedRange,
                    totalSize: item.totalSize,
                    subDirectory: item.subDirectory ?? folderName
                )
            }
        }
        list.sort { a, b in
            let na = (a.suggestedFilename ?? "").lowercased()
            let nb = (b.suggestedFilename ?? "").lowercased()
            let aIsMainSetup = na.hasPrefix("setup_") && na.hasSuffix(".exe") && !na.contains("dlc")
            let bIsMainSetup = nb.hasPrefix("setup_") && nb.hasSuffix(".exe") && !nb.contains("dlc")
            if aIsMainSetup != bIsMainSetup { return aIsMainSetup }
            return na < nb
        }
        return list
    }

    // 3MB Chunked HTTP/2 Range Accelerator with strict byte-size verification, retry backoff, and token refresh
    nonisolated func runChunkedRangeDownload(taskID: UUID, resolved: ResolvedDownload, totalSize: Int64) async {
        let downloadsDir = ("~/Downloads" as NSString).expandingTildeInPath
        let filename = resolved.suggestedFilename ?? "Download_\(Int(Date().timeIntervalSince1970)).7z"
        let destPath = (downloadsDir as NSString).appendingPathComponent(filename)

        await MainActor.run {
            self.appendLog("range-3m ▸ 检测到 VikingFile 限速策略，启用 8 路 × 3MB 切片校验引擎！", highlight: true)
        }

        FileManager.default.createFile(atPath: destPath, contents: nil)
        guard let fileHandle = FileHandle(forWritingAtPath: destPath) else { return }
        try? fileHandle.truncate(atOffset: UInt64(totalSize))
        try? fileHandle.close()

        let chunkSize: Int64 = 3 * 1024 * 1024 // 3 MB per Range request
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
        let batchSize = 8
        var completedBytes: Int64 = 0
        let totalGB = Double(totalSize) / (1024.0 * 1024.0 * 1024.0)
        var activeCDNURL = resolved.finalURL

        for batchStart in stride(from: 0, to: ranges.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, ranges.count)
            let slice = Array(ranges[batchStart..<batchEnd])

            var procs: [(Int, Int64, Int64, String, Process)] = []
            for (cIdx, cStart, cEnd) in slice {
                let tmpChunk = "/tmp/sf_chunk_\(taskID.uuidString)_\(cIdx).bin"
                try? FileManager.default.removeItem(atPath: tmpChunk)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                p.arguments = [
                    "--noproxy", "*",
                    "--http2",
                    "--fail",
                    "-A", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
                    "-s",
                    "-r", "\(cStart)-\(cEnd)",
                    "-o", tmpChunk,
                    activeCDNURL
                ]
                try? p.run()
                procs.append((cIdx, cStart, cEnd, tmpChunk, p))
            }

            guard let writer = FileHandle(forWritingAtPath: destPath) else { return }
            var batchAborted = false

            for (cIdx, cStart, cEnd, tmpChunk, p) in procs {
                p.waitUntilExit()
                let expectedBytes = Int(cEnd - cStart + 1)
                var validData: Data? = nil

                if p.terminationStatus == 0,
                   let d = try? Data(contentsOf: URL(fileURLWithPath: tmpChunk)),
                   d.count == expectedBytes {
                    validData = d
                } else {
                    // Exponential backoff retry (up to 5 attempts) + re-resolve CDN URL on failure
                    for attempt in 1...5 {
                        try? FileManager.default.removeItem(atPath: tmpChunk)
                        let delayNs = UInt64(Double(attempt) * 1.2 * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: delayNs)

                        if attempt >= 2 {
                            let refreshed = await Self.resolveHostLink(resolved.originalURL)
                            if !refreshed.finalURL.isEmpty {
                                activeCDNURL = refreshed.finalURL
                            }
                        }

                        let retryProc = Process()
                        retryProc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                        retryProc.arguments = [
                            "--noproxy", "*",
                            "--http2",
                            "--fail",
                            "-A", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
                            "-s",
                            "-r", "\(cStart)-\(cEnd)",
                            "-o", tmpChunk,
                            activeCDNURL
                        ]
                        try? retryProc.run()
                        retryProc.waitUntilExit()

                        if retryProc.terminationStatus == 0,
                           let d = try? Data(contentsOf: URL(fileURLWithPath: tmpChunk)),
                           d.count == expectedBytes {
                            validData = d
                            break
                        }
                    }
                }

                try? FileManager.default.removeItem(atPath: tmpChunk)

                if let verified = validData {
                    try? writer.seek(toOffset: UInt64(cStart))
                    try? writer.write(contentsOf: verified)
                    completedBytes += Int64(verified.count)
                } else {
                    batchAborted = true
                    let failedIdx = cIdx
                    await MainActor.run {
                        if let i = self.downloadTasks.firstIndex(where: { $0.id == taskID }) {
                            self.downloadTasks[i].status = .failed
                            self.downloadTasks[i].pill = "切片校验失败"
                        }
                        self.appendLog("error ▸ 切片 #\(failedIdx) (\(cStart)-\(cEnd)) 5 次重试后仍未通过字节数校验，已中止以防损坏压缩包！", highlight: true)
                    }
                    break
                }
            }
            try? writer.close()
            if batchAborted { return }

            let elapsed = max(0.1, Date().timeIntervalSince(startTime))
            let speedMB = (Double(completedBytes) / (1024.0 * 1024.0)) / elapsed
            let doneGB = Double(completedBytes) / (1024.0 * 1024.0 * 1024.0)
            let progress = min(0.99, max(0.02, Double(completedBytes) / Double(totalSize)))
            let snapshotSpeed = String(format: "%.1f MB/s", speedMB)
            let snapshotRight = String(format: "%.2f / %.2f GB", doneGB, totalGB)

            await MainActor.run {
                if let i = self.downloadTasks.firstIndex(where: { $0.id == taskID }) {
                    self.downloadTasks[i].status = .running(progress)
                    self.downloadTasks[i].pill = snapshotSpeed
                    self.downloadTasks[i].rightText = snapshotRight
                    self.downloadTasks[i].localPath = destPath
                }
            }
        }

        await MainActor.run {
            guard let i = self.downloadTasks.firstIndex(where: { $0.id == taskID }) else { return }
            self.downloadTasks[i].status = .done
            self.downloadTasks[i].pill = nil
            self.downloadTasks[i].rightText = String(format: "%.2f GB", totalGB)
            self.downloadTasks[i].localPath = destPath
            self.appendLog("range-3m ▸ 下载完成并通过全量切片校验: \(filename)", highlight: true)
            if self.autoRelay && Self.isArchiveFile(destPath) {
                self.appendLog("relay ▸ 自动流转至 [解压]: \(filename)", highlight: true)
                self.activeTab = .unpack
                self.startUnpack(filePath: destPath)
            }
        }
    }

    nonisolated static func locateDownloadEngineBinary() -> String? {
        let fm = FileManager.default
        let bundleHelper = (Bundle.main.bundlePath as NSString).appendingPathComponent("Contents/MacOS/sf-dl")
        if fm.fileExists(atPath: bundleHelper) {
            return bundleHelper
        }
        let bundled = ("~/Applications/Chrysa.app/Contents/MacOS/sf-dl" as NSString).expandingTildeInPath
        if fm.fileExists(atPath: bundled) {
            return bundled
        }
        let tmpHelper = "/tmp/sf-dl"
        if fm.fileExists(atPath: tmpHelper) {
            return tmpHelper
        }
        let brewAria = fm.fileExists(atPath: "/opt/homebrew/bin/aria2c") ? "/opt/homebrew/bin/aria2c" : "/usr/local/bin/aria2c"
        if fm.fileExists(atPath: brewAria) {
            try? fm.copyItem(atPath: brewAria, toPath: tmpHelper)
            return fm.fileExists(atPath: tmpHelper) ? tmpHelper : brewAria
        }
        return nil
    }

    nonisolated func runAria2Download(taskID: UUID, resolved: ResolvedDownload, suppressAutoRelay: Bool = false) async {
        if resolved.useChunkedRange, let totalSize = resolved.totalSize, totalSize > 0 {
            await runChunkedRangeDownload(taskID: taskID, resolved: resolved, totalSize: totalSize)
            return
        }

        let baseDownloadsDir = ("~/Downloads" as NSString).expandingTildeInPath
        let downloadsDir: String = {
            if let sub = resolved.subDirectory, !sub.isEmpty {
                let d = (baseDownloadsDir as NSString).appendingPathComponent(sub)
                try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
                return d
            }
            return baseDownloadsDir
        }()

        guard let aria2Path = Self.locateDownloadEngineBinary() else {
            await MainActor.run {
                self.appendLog("error ▸ 未找到下载内核 (sf-dl / aria2c)", highlight: true)
            }
            return
        }

        let lowerFinal = resolved.finalURL.lowercased()
        let isPixeldrain = lowerFinal.contains("pixeldrain.com")
        let isFileDitch = lowerFinal.contains("fileditch")
        let threads = isFileDitch ? "2" : (isPixeldrain ? "4" : "16")

        let customUA: String = {
            for h in resolved.headers {
                if h.lowercased().hasPrefix("user-agent:") {
                    return h.dropFirst("user-agent:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        }()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: aria2Path)
        var args = [
            "--no-conf",
            "-c",
            "-x", threads,
            "-s", threads,
            "-k", "1M",
            "-U", customUA,
            "--file-allocation=none",
            "--dir=\(downloadsDir)",
            "--summary-interval=1",
            "--console-log-level=warn",
            "--allow-overwrite=true"
        ]
        if Self.hostNeedsProxy(resolved.finalURL), let sysProxy = Self.detectSystemProxy() {
            args.append("--all-proxy=\(sysProxy)")
            await MainActor.run {
                self.appendLog("proxy ▸ 海外节点通过 sf-dl 挂载系统代理: \(sysProxy) (\(threads) 线程)", highlight: false)
            }
        }
        if let name = resolved.suggestedFilename, !name.isEmpty {
            args.append("--out=\(name)")
        }
        for h in resolved.headers where !h.lowercased().hasPrefix("user-agent:") {
            args.append("--header=\(h)")
        }
        args.append(resolved.finalURL)
        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.parseAria2Output(taskID: taskID, output: line)
            }
        }

        do {
            try proc.run()
            await MainActor.run {
                self.activeProcesses[taskID] = proc
            }
            proc.waitUntilExit()
            handle.readabilityHandler = nil

            let status = proc.terminationStatus
            let fallbackPath: String? = {
                if let name = resolved.suggestedFilename, !name.isEmpty {
                    return (downloadsDir as NSString).appendingPathComponent(name)
                }
                return nil
            }()

            await MainActor.run {
                self.activeProcesses.removeValue(forKey: taskID)
                if self.cancelledTaskIDs.contains(taskID) {
                    return
                }
                guard let idx = self.downloadTasks.firstIndex(where: { $0.id == taskID }) else { return }
                if status == 0 {
                    self.downloadTasks[idx].status = .done
                    self.downloadTasks[idx].pill = nil
                    let finalTitle = self.downloadTasks[idx].title
                    let finalPath = self.downloadTasks[idx].localPath
                        ?? fallbackPath
                        ?? (downloadsDir as NSString).appendingPathComponent(finalTitle)
                    self.downloadTasks[idx].localPath = finalPath
                    self.appendLog("dl ▸ 下载完成: \(finalTitle)", highlight: true)

                    if !suppressAutoRelay && self.autoRelay && Self.isArchiveFile(finalPath) {
                        self.appendLog("relay ▸ 自动流转至 [解压]: \(finalTitle)", highlight: true)
                        self.activeTab = .unpack
                        self.startUnpack(filePath: finalPath)
                    }
                } else {
                    self.downloadTasks[idx].status = .failed
                    self.downloadTasks[idx].pill = "失败"
                    self.appendLog("dl ▸ 进程退出码 \(status)", highlight: false)
                }
            }
        } catch {
            await MainActor.run {
                self.activeProcesses.removeValue(forKey: taskID)
                self.appendLog("error ▸ 无法启动下载内核: \(error.localizedDescription)", highlight: false)
            }
        }
    }


    private func parseAria2Output(taskID: UUID, output: String) {
        guard let idx = downloadTasks.firstIndex(where: { $0.id == taskID }) else { return }

        var newPctInt: Int? = nil
        if let pctMatch = try? NSRegularExpression(pattern: #"\(([0-9]{1,3})%\)"#).firstMatch(
            in: output, range: NSRange(output.startIndex..., in: output)
        ), let r = Range(pctMatch.range(at: 1), in: output), let pctVal = Double(output[r]) {
            downloadTasks[idx].status = .running(max(0.03, min(0.99, pctVal / 100.0)))
            newPctInt = Int(pctVal)
        }

        if let dlMatch = try? NSRegularExpression(pattern: #"DL:([0-9.]+[KMG]i?B)"#).firstMatch(
            in: output, range: NSRange(output.startIndex..., in: output)
        ), let r = Range(dlMatch.range(at: 1), in: output) {
            downloadTasks[idx].pill = "\(output[r])/s"
        }

        if let sizeMatch = try? NSRegularExpression(pattern: #"([0-9.]+[KMG]i?B/[0-9.]+[KMG]i?B)"#).firstMatch(
            in: output, range: NSRange(output.startIndex..., in: output)
        ), let r = Range(sizeMatch.range(at: 1), in: output) {
            downloadTasks[idx].rightText = String(output[r])
        }

        if let pInt = newPctInt, pInt != lastPrintedPctByTask[taskID], (pInt % 5 == 0 || pInt <= 2 || pInt >= 98) {
            lastPrintedPctByTask[taskID] = pInt
            print("  ↳ [DL] \(downloadTasks[idx].title): \(pInt)% | \(downloadTasks[idx].pill ?? "") | \(downloadTasks[idx].rightText)")
            fflush(stdout)
        }

        if let pathMatch = try? NSRegularExpression(pattern: #"(?:Download complete:|下载完成：)\s*(.+)"#).firstMatch(
            in: output, range: NSRange(output.startIndex..., in: output)
        ), let r = Range(pathMatch.range(at: 1), in: output) {
            let p = String(output[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            downloadTasks[idx].localPath = p
            downloadTasks[idx].title = (p as NSString).lastPathComponent
        }
    }

    nonisolated static func isArchiveFile(_ path: String) -> Bool {
        let lower = path.lowercased()
        let base = (lower as NSString).lastPathComponent
        let exts = [".7z", ".rar", ".zip", ".tar.zst", ".tar.xz", ".iso", ".001"]
        if exts.contains(where: { lower.hasSuffix($0) }) {
            return true
        }
        if let decoded = decodeBase64FilenameIfPossible((path as NSString).lastPathComponent),
           exts.contains(where: { decoded.lowercased().hasSuffix($0) }) {
            return true
        }
        // GOG / Inno Setup installers: setup_*.exe or setup_*-1.bin
        if base.hasPrefix("setup_") && (base.hasSuffix(".exe") || base.hasSuffix(".bin")) {
            return true
        }
        return false
    }

    nonisolated static func isInnoSetupInstaller(_ path: String) -> Bool {
        guard path.lowercased().hasSuffix(".exe"),
              FileManager.default.fileExists(atPath: "/opt/homebrew/bin/innoextract"),
              FileManager.default.fileExists(atPath: path) else {
            return false
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/innoextract")
        proc.arguments = ["-i", "-s", path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

}
