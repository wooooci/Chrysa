import ChrysaCore
import ChrysaApplication
import Foundation

package struct MediaFireResolver: HostResolver {
    package let id = "mediafire"
    package let bareDomains = [
        "mediafire.com/",
        "www.mediafire.com/",
        "app.mediafire.com/",
        "mfi.re/"
    ]

    package struct ExtractedDownload: Equatable, Sendable {
        package let directURL: String
        package let filename: String?
        package let totalSize: Int64?
    }

    package struct FolderFileEntry: Equatable, Sendable {
        package let quickKey: String
        package let filename: String
        package let size: Int64?
        package let pageURL: String
    }

    package struct FolderSubfolderEntry: Equatable, Sendable {
        package let folderKey: String
        package let name: String
    }

    package struct FolderFilesPage: Equatable, Sendable {
        package let files: [FolderFileEntry]
        package let moreChunks: Bool
        package let errorMessage: String?
    }

    package func canHandle(host: String, url: URL) -> Bool {
        let lower = host.lowercased()
        return lower == "mediafire.com"
            || lower.hasSuffix(".mediafire.com")
            || lower == "mfi.re"
            || lower.hasSuffix(".mfi.re")
    }

    package func matchesCDNHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "mediafire.com"
            || lower.hasSuffix(".mediafire.com")
            || lower == "mfi.re"
            || lower.hasSuffix(".mfi.re")
    }

    package func proxyNeeds() -> Bool { false }
    package func maxThreads() -> Int { 8 }

    package static func isDirectCDNURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.range(of: #"^download[0-9]*\.mediafire\.com$"#, options: .regularExpression) != nil
    }

    package static func extractFolderKeys(from url: URL) -> [String] {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0].lowercased() == "folder" else {
            return []
        }
        return parts[1]
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.range(of: #"^[A-Za-z0-9]{8,32}$"#, options: .regularExpression) != nil }
    }

    package static func canonicalFilePageURL(from url: URL) -> String {
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count >= 2, parts[0].lowercased() == "view" {
            let key = parts[1]
            if key.range(of: #"^[A-Za-z0-9]{8,32}$"#, options: .regularExpression) != nil {
                return "https://www.mediafire.com/file/\(key)/file"
            }
        }
        return url.absoluteString
    }

    package func resolveDetailed(
        input: String,
        url: URL,
        passwords: [String],
        settings: DownloadSettings
    ) async -> HostResolutionResult {
        // 1. Direct CDN link fast-path (never GET-fetch a multi-GB binary as HTML)
        if Self.isDirectCDNURL(url) {
            return await resolveDirectCDN(url: url, originalURL: input, settings: settings)
        }

        // 2. Folder share URL (/folder/<key> or /folder/<k1>,<k2>)
        let folderKeys = Self.extractFolderKeys(from: url)
        if !folderKeys.isEmpty {
            return await resolveFolders(keys: folderKeys, settings: settings)
        }

        // 3. Single file / short link / legacy query link
        return await resolveSingleFilePage(
            startURL: Self.canonicalFilePageURL(from: url),
            originalURL: input,
            fallbackFilename: nil,
            fallbackSize: nil,
            subDirectory: nil,
            settings: settings
        )
    }

    private func resolveDirectCDN(
        url: URL,
        originalURL: String,
        settings: DownloadSettings
    ) async -> HostResolutionResult {
        let route = await ResolverHTTPHelper.resolveProxyRoute(
            for: url.absoluteString,
            policy: settings.proxyPolicy,
            headers: ["Referer": "https://www.mediafire.com/"],
            timeoutSeconds: 6
        )
        if let probeFailure = ResolverHTTPHelper.validateDownloadProbe(route.probe) {
            return HostResolutionResult(downloads: [], failureReason: probeFailure)
        }
        let rawName = route.probe?.contentDispositionFilename
            ?? url.lastPathComponent.removingPercentEncoding
        let finalName = (rawName?.isEmpty == false) ? rawName : nil
        return HostResolutionResult(downloads: [
            ResolvedDownload(
                originalURL: originalURL,
                finalURL: route.probe?.finalURL ?? url.absoluteString,
                headers: ["Referer: https://www.mediafire.com/"],
                suggestedFilename: finalName,
                totalSize: route.probe?.contentLength,
                maxThreads: maxThreads(),
                needsProxy: route.route.useProxy,
                resolverID: id
            )
        ])
    }

    private func resolveSingleFilePage(
        startURL: String,
        originalURL: String,
        fallbackFilename: String?,
        fallbackSize: Int64?,
        subDirectory: String?,
        settings: DownloadSettings
    ) async -> HostResolutionResult {
        var currentURL = startURL
        var lastResp: HTTPProbeResponse? = nil

        // Follow redirects hop-by-hop so direct CDN 302s never stream multi-GB bodies into memory
        for _ in 0..<6 {
            guard let resp = await ResolverHTTPHelper.fetchWithPolicy(
                urlString: currentURL,
                policy: settings.proxyPolicy,
                preferDirect: true,
                followRedirects: false,
                timeoutSeconds: 15
            ) else {
                return HostResolutionResult(downloads: [], failureReason: "无法连接 MediaFire")
            }
            lastResp = resp

            if (300...399).contains(resp.statusCode),
               let rawLoc = resp.headers["location"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawLoc.isEmpty,
               let base = URL(string: currentURL),
               let nextURL = URL(string: rawLoc, relativeTo: base)?.absoluteURL {
                let lowerNext = nextURL.absoluteString.lowercased()
                if lowerNext.contains("/error.php") {
                    return HostResolutionResult(downloads: [], failureReason: Self.classifyErrorRedirect(nextURL))
                }
                if Self.isDirectCDNURL(nextURL) {
                    let rawName = fallbackFilename
                        ?? nextURL.lastPathComponent.removingPercentEncoding
                    return HostResolutionResult(downloads: [
                        ResolvedDownload(
                            originalURL: originalURL,
                            finalURL: nextURL.absoluteString,
                            headers: ["Referer: https://www.mediafire.com/"],
                            suggestedFilename: rawName,
                            totalSize: fallbackSize,
                            subDirectory: subDirectory,
                            maxThreads: maxThreads(),
                            needsProxy: proxyNeeds(),
                            resolverID: id
                        )
                    ])
                }
                let redirectedFolderKeys = Self.extractFolderKeys(from: nextURL)
                if !redirectedFolderKeys.isEmpty {
                    return await resolveFolders(keys: redirectedFolderKeys, settings: settings)
                }
                currentURL = Self.canonicalFilePageURL(from: nextURL)
                continue
            }

            break
        }

        guard let resp = lastResp else {
            return HostResolutionResult(downloads: [], failureReason: "无法连接 MediaFire")
        }

        if resp.statusCode >= 400 {
            let reason = ResolverHTTPHelper.classifyFailure(
                statusCode: resp.statusCode,
                contentType: resp.contentType,
                body: resp.bodyString
            ) ?? "链接已失效"
            return HostResolutionResult(downloads: [], failureReason: reason)
        }

        // If the server returned a direct binary attachment without redirecting
        if let ct = resp.contentType?.lowercased(),
           !ct.contains("text/html"),
           !ct.contains("application/xhtml"),
           resp.contentDispositionFilename != nil || ct.contains("application/octet-stream") {
            let resolvedName = fallbackFilename
                ?? resp.contentDispositionFilename
                ?? URL(string: resp.finalURL)?.lastPathComponent.removingPercentEncoding
            return HostResolutionResult(downloads: [
                ResolvedDownload(
                    originalURL: originalURL,
                    finalURL: resp.finalURL,
                    headers: ["Referer: https://www.mediafire.com/"],
                    suggestedFilename: resolvedName,
                    totalSize: fallbackSize ?? resp.contentLength,
                    subDirectory: subDirectory,
                    maxThreads: maxThreads(),
                    needsProxy: proxyNeeds(),
                    resolverID: id
                )
            ])
        }

        guard let html = resp.bodyString, !html.isEmpty else {
            return HostResolutionResult(downloads: [], failureReason: "MediaFire 返回空页面")
        }

        // IMPORTANT: Always extract the download link BEFORE calling generic classifyFailure,
        // because normal MediaFire pages include words like "captcha" / "password" in footer/JS templates.
        if let extracted = Self.extractDirectDownload(from: html) {
            let finalName = fallbackFilename
                ?? extracted.filename
                ?? URL(string: extracted.directURL)?.lastPathComponent.removingPercentEncoding
            return HostResolutionResult(downloads: [
                ResolvedDownload(
                    originalURL: originalURL,
                    finalURL: extracted.directURL,
                    headers: ["Referer: https://www.mediafire.com/"],
                    suggestedFilename: finalName,
                    totalSize: fallbackSize ?? extracted.totalSize,
                    subDirectory: subDirectory,
                    maxThreads: maxThreads(),
                    needsProxy: proxyNeeds(),
                    resolverID: id
                )
            ])
        }

        if let mfReason = Self.classifyMediaFireFailureHTML(html) {
            return HostResolutionResult(downloads: [], failureReason: mfReason)
        }

        if let genericFailure = ResolverHTTPHelper.classifyFailure(
            statusCode: resp.statusCode,
            contentType: resp.contentType,
            body: html
        ) {
            return HostResolutionResult(downloads: [], failureReason: genericFailure)
        }

        let preview = String(html.prefix(600))
        return HostResolutionResult(
            downloads: [],
            failureReason: "无法提取 MediaFire 直链",
            diagnostic: "HTTP \(resp.statusCode) (\(currentURL))\n\(preview)"
        )
    }

    private func resolveFolders(
        keys: [String],
        settings: DownloadSettings
    ) async -> HostResolutionResult {
        var collectedFiles: [(entry: FolderFileEntry, subDir: String?)] = []
        var visitedFolderKeys: Set<String> = []
        var firstError: String? = nil

        func walkFolder(folderKey: String, parentSubDir: String?, depth: Int) async {
            guard depth <= 3, visitedFolderKeys.count < 24, !visitedFolderKeys.contains(folderKey) else {
                return
            }
            visitedFolderKeys.insert(folderKey)

            let folderName = await fetchFolderName(folderKey: folderKey, settings: settings)
            let currentSubDir: String? = {
                let cleanName = folderName.flatMap { PathSafety.safeFilename($0) }
                switch (parentSubDir, cleanName) {
                case (let p?, let c?): return "\(p)/\(c)"
                case (let p?, nil): return p
                case (nil, let c?): return c
                case (nil, nil): return nil
                }
            }()

            // Paginate files in folder
            for chunk in 1...20 {
                let apiURL = "https://www.mediafire.com/api/1.5/folder/get_content.php?content_type=files&folder_key=\(folderKey)&chunk=\(chunk)&response_format=json"
                guard let resp = await ResolverHTTPHelper.fetchWithPolicy(
                    urlString: apiURL,
                    policy: settings.proxyPolicy,
                    preferDirect: true,
                    timeoutSeconds: 15
                ) else {
                    if firstError == nil { firstError = "无法连接 MediaFire 文件夹接口" }
                    break
                }
                let page = Self.parseFolderFilesJSON(resp.bodyData)
                if let err = page.errorMessage {
                    if firstError == nil { firstError = err }
                    break
                }
                for f in page.files {
                    collectedFiles.append((f, currentSubDir))
                }
                if !page.moreChunks || page.files.isEmpty {
                    break
                }
            }

            // Paginate subfolders
            var subfolders: [FolderSubfolderEntry] = []
            for chunk in 1...10 {
                let subURL = "https://www.mediafire.com/api/1.5/folder/get_content.php?content_type=folders&folder_key=\(folderKey)&chunk=\(chunk)&response_format=json"
                guard let resp = await ResolverHTTPHelper.fetchWithPolicy(
                    urlString: subURL,
                    policy: settings.proxyPolicy,
                    preferDirect: true,
                    timeoutSeconds: 15
                ) else { break }
                let (subs, more) = Self.parseFolderSubfoldersJSON(resp.bodyData)
                subfolders.append(contentsOf: subs)
                if !more || subs.isEmpty { break }
            }

            for sub in subfolders {
                await walkFolder(folderKey: sub.folderKey, parentSubDir: currentSubDir, depth: depth + 1)
            }
        }

        for key in keys {
            await walkFolder(folderKey: key, parentSubDir: nil, depth: 0)
        }

        guard !collectedFiles.isEmpty else {
            return HostResolutionResult(downloads: [], failureReason: firstError ?? "MediaFire 文件夹为空或已失效")
        }

        // Resolve individual file pages in bounded parallel batches (4 at a time)
        var resolvedByIndex: [(Int, ResolvedDownload)] = []
        var failureReason: String? = nil
        let batchSize = 4

        for batchStart in stride(from: 0, to: collectedFiles.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, collectedFiles.count)
            let batch = Array(collectedFiles[batchStart..<batchEnd])
            await withTaskGroup(of: (Int, HostResolutionResult).self) { group in
                for (offset, item) in batch.enumerated() {
                    let globalIdx = batchStart + offset
                    group.addTask {
                        let res = await self.resolveSingleFilePage(
                            startURL: item.entry.pageURL,
                            originalURL: item.entry.pageURL,
                            fallbackFilename: item.entry.filename,
                            fallbackSize: item.entry.size,
                            subDirectory: item.subDir,
                            settings: settings
                        )
                        return (globalIdx, res)
                    }
                }
                for await (idx, res) in group {
                    if let dl = res.downloads.first {
                        resolvedByIndex.append((idx, dl))
                    } else if failureReason == nil {
                        failureReason = res.failureReason
                    }
                }
            }
        }

        resolvedByIndex.sort { $0.0 < $1.0 }
        let downloads = resolvedByIndex.map(\.1)
        if downloads.isEmpty {
            return HostResolutionResult(downloads: [], failureReason: failureReason ?? "无法提取 MediaFire 文件夹直链")
        }
        return HostResolutionResult(downloads: downloads)
    }

    private func fetchFolderName(folderKey: String, settings: DownloadSettings) async -> String? {
        let infoURL = "https://www.mediafire.com/api/1.5/folder/get_info.php?folder_key=\(folderKey)&response_format=json"
        guard let resp = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: infoURL,
            policy: settings.proxyPolicy,
            preferDirect: true,
            timeoutSeconds: 10
        ) else { return nil }
        return Self.parseFolderInfoName(resp.bodyData)
    }

    // MARK: - Pure HTML & JSON Parsers (Unit-Testable)

    package static func extractDirectDownload(from html: String) -> ExtractedDownload? {
        let filenameHint = extractFilenameHint(from: html)
        let sizeHint = extractSizeHint(from: html)

        // 1. Modern MediaFire `data-scrambled-url="<base64>"` (commonly on <a id="downloadButton">)
        if let scrambledRegex = try? NSRegularExpression(
            pattern: #"data-scrambled-url\s*=\s*["']([A-Za-z0-9+/=_-]{16,})["']"#,
            options: [.caseInsensitive]
        ) {
            let nsRange = NSRange(html.startIndex..., in: html)
            for match in scrambledRegex.matches(in: html, range: nsRange) {
                if let r = Range(match.range(at: 1), in: html),
                   let decoded = decodeBase64URL(String(html[r])),
                   isValidMediaFireDownloadURL(decoded) {
                    return ExtractedDownload(
                        directURL: decoded,
                        filename: filenameFromDirectURL(decoded) ?? filenameHint,
                        totalSize: sizeHint
                    )
                }
            }
        }

        // 2. <a ... id="downloadButton" ...> or <a ... aria-label="Download file" ...>
        if let btnRegex = try? NSRegularExpression(
            pattern: #"<a\b[^>]*\b(?:id\s*=\s*["']downloadButton["']|aria-label\s*=\s*["']Download file["'])[^>]*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            let nsRange = NSRange(html.startIndex..., in: html)
            for match in btnRegex.matches(in: html, range: nsRange) {
                if let tagRange = Range(match.range, in: html) {
                    let tag = String(html[tagRange])
                    if let href = extractAttribute("href", from: tag) {
                        let cleaned = normalizeCandidateURL(href)
                        if isValidMediaFireDownloadURL(cleaned) {
                            return ExtractedDownload(
                                directURL: cleaned,
                                filename: filenameFromDirectURL(cleaned) ?? filenameHint,
                                totalSize: sizeHint
                            )
                        }
                    }
                }
            }
        }

        // 3. Direct href="https://download*.mediafire.com/..." (or protocol-relative //download*.mediafire.com/...)
        if let hrefRegex = try? NSRegularExpression(
            pattern: #"href\s*=\s*["']((?:https?:)?//download[0-9]*\.mediafire\.com/[^"']+)["']"#,
            options: [.caseInsensitive]
        ),
           let match = hrefRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r = Range(match.range(at: 1), in: html) {
            let cleaned = normalizeCandidateURL(String(html[r]))
            if isValidMediaFireDownloadURL(cleaned) {
                return ExtractedDownload(
                    directURL: cleaned,
                    filename: filenameFromDirectURL(cleaned) ?? filenameHint,
                    totalSize: sizeHint
                )
            }
        }

        // 4. Inline JS direct URL or atob("...")
        if let jsURLRegex = try? NSRegularExpression(
            pattern: #"https?:\\?/\\?/download[0-9]*\.mediafire\.com[^"'\s<>]+"#,
            options: [.caseInsensitive]
        ),
           let match = jsURLRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r = Range(match.range, in: html) {
            let cleaned = normalizeCandidateURL(String(html[r]).replacingOccurrences(of: "\\/", with: "/"))
            if isValidMediaFireDownloadURL(cleaned) {
                return ExtractedDownload(
                    directURL: cleaned,
                    filename: filenameFromDirectURL(cleaned) ?? filenameHint,
                    totalSize: sizeHint
                )
            }
        }

        if let atobRegex = try? NSRegularExpression(
            pattern: #"atob\(\s*["']([A-Za-z0-9+/=_-]{20,})["']\s*\)"#,
            options: [.caseInsensitive]
        ) {
            let nsRange = NSRange(html.startIndex..., in: html)
            for match in atobRegex.matches(in: html, range: nsRange) {
                if let r = Range(match.range(at: 1), in: html),
                   let decoded = decodeBase64URL(String(html[r])),
                   isValidMediaFireDownloadURL(decoded) {
                    return ExtractedDownload(
                        directURL: decoded,
                        filename: filenameFromDirectURL(decoded) ?? filenameHint,
                        totalSize: sizeHint
                    )
                }
            }
        }

        return nil
    }

    package static func parseFolderInfoName(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let folderInfo = response["folder_info"] as? [String: Any],
              let name = folderInfo["name"] as? String else {
            return nil
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    package static func parseFolderFilesJSON(_ data: Data) -> FolderFilesPage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any] else {
            return FolderFilesPage(files: [], moreChunks: false, errorMessage: "MediaFire 接口返回格式异常")
        }
        if let result = response["result"] as? String, result.lowercased() != "success" {
            let errCode = response["error"] as? Int
            let msg = (response["message"] as? String)?.lowercased() ?? ""
            if errCode == 112 || errCode == 114 || msg.contains("invalid") || msg.contains("unknown") {
                return FolderFilesPage(files: [], moreChunks: false, errorMessage: "链接已失效")
            }
            if msg.contains("private") || msg.contains("password") {
                return FolderFilesPage(files: [], moreChunks: false, errorMessage: "需访问密码")
            }
            return FolderFilesPage(files: [], moreChunks: false, errorMessage: "MediaFire 文件夹解析失败")
        }

        guard let folderContent = response["folder_content"] as? [String: Any] else {
            return FolderFilesPage(files: [], moreChunks: false, errorMessage: nil)
        }
        let moreChunks = (folderContent["more_chunks"] as? String)?.lowercased() == "yes"
        let rawFiles = folderContent["files"] as? [[String: Any]] ?? []
        var entries: [FolderFileEntry] = []
        for item in rawFiles {
            guard let quickKey = item["quickkey"] as? String, !quickKey.isEmpty,
                  let filename = item["filename"] as? String, !filename.isEmpty else { continue }
            let size: Int64? = {
                if let n = item["size"] as? Int64 { return n }
                if let n = item["size"] as? Int { return Int64(n) }
                if let s = item["size"] as? String { return Int64(s) }
                return nil
            }()
            let links = item["links"] as? [String: Any]
            let normalDownload = (links?["normal_download"] as? String)?
                .replacingOccurrences(of: "http://", with: "https://")
                ?? "https://www.mediafire.com/file/\(quickKey)/file"
            entries.append(FolderFileEntry(
                quickKey: quickKey,
                filename: filename,
                size: size,
                pageURL: normalDownload
            ))
        }
        return FolderFilesPage(files: entries, moreChunks: moreChunks, errorMessage: nil)
    }

    package static func parseFolderSubfoldersJSON(_ data: Data) -> (folders: [FolderSubfolderEntry], moreChunks: Bool) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let folderContent = response["folder_content"] as? [String: Any] else {
            return ([], false)
        }
        let moreChunks = (folderContent["more_chunks"] as? String)?.lowercased() == "yes"
        let rawFolders = folderContent["folders"] as? [[String: Any]] ?? []
        let parsed: [FolderSubfolderEntry] = rawFolders.compactMap { item in
            guard let key = item["folderkey"] as? String, !key.isEmpty,
                  let name = item["name"] as? String, !name.isEmpty else { return nil }
            return FolderSubfolderEntry(folderKey: key, name: name)
        }
        return (parsed, moreChunks)
    }

    private static func classifyErrorRedirect(_ url: URL) -> String {
        let query = url.query?.lowercased() ?? ""
        if query.contains("errno=320") || query.contains("errno=380") || query.contains("errno=388") || query.contains("errno=389") {
            return "链接已失效"
        }
        return "链接已失效"
    }

    private static func classifyMediaFireFailureHTML(_ html: String) -> String? {
        let lower = html.lowercased()
        if lower.contains("name=\"form_password\"")
            || lower.contains("name='form_password'")
            || lower.contains("this file is password protected")
            || lower.contains("download_password") {
            return "需访问密码"
        }
        if lower.contains("something appears to be missing")
            || lower.contains("invalid or deleted file")
            || lower.contains("file blocked for violation")
            || lower.contains("dangerous file blocked")
            || lower.contains("permission denied")
            || lower.contains("the key you provided for file access was invalid") {
            return "链接已失效"
        }
        if lower.contains("cf-browser-verification")
            || lower.contains("just a moment...")
            || lower.contains("challenges.cloudflare.com")
            || lower.contains("cf-turnstile") {
            return "含网页盾·请用浏览器下载"
        }
        return nil
    }

    private static func decodeBase64URL(_ raw: String) -> String? {
        var b64 = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem > 0 {
            b64 += String(repeating: "=", count: 4 - rem)
        }
        guard let data = Data(base64Encoded: b64),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return unescapeHTML(str.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isValidMediaFireDownloadURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        return host.range(of: #"^download[0-9]*\.mediafire\.com$"#, options: .regularExpression) != nil
    }

    private static func filenameFromDirectURL(_ raw: String) -> String? {
        guard let url = URL(string: raw) else { return nil }
        let comp = (url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comp.isEmpty, comp != "/", comp.lowercased() != "file" else { return nil }
        return comp
    }

    private static func extractFilenameHint(from html: String) -> String? {
        let patterns = [
            #"<div[^>]*class=["'][^"']*dl-btn-label[^"']*["'][^>]*title=["']([^"']+)["']"#,
            #"<meta[^>]*property=["']og:title["'][^>]*content=["']([^"']+)["']"#,
            #"<div[^>]*class=["']filename["'][^>]*>\s*([^<]+?)\s*</div>"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let r = Range(match.range(at: 1), in: html) {
                let candidate = unescapeHTML(String(html[r])).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty, !candidate.lowercased().contains("mediafire") {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func extractSizeHint(from html: String) -> Int64? {
        let patterns = [
            #"Download\s*\(\s*([0-9]+(?:\.[0-9]+)?)\s*(KB|MB|GB|TB|B)\s*\)"#,
            #"File size:\s*<span>\s*([0-9]+(?:\.[0-9]+)?)\s*(KB|MB|GB|TB|B)\s*</span>"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let numRange = Range(match.range(at: 1), in: html),
               let unitRange = Range(match.range(at: 2), in: html),
               let val = Double(html[numRange]) {
                let unit = String(html[unitRange]).uppercased()
                let mult: Double = switch unit {
                case "TB": 1024 * 1024 * 1024 * 1024
                case "GB": 1024 * 1024 * 1024
                case "MB": 1024 * 1024
                case "KB": 1024
                default: 1
                }
                return Int64(val * mult)
            }
        }
        return nil
    }

    private static func extractAttribute(_ name: String, from tag: String) -> String? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let r = Range(match.range(at: 1), in: tag) else {
            return nil
        }
        return String(tag[r])
    }

    private static func normalizeCandidateURL(_ raw: String) -> String {
        let cleaned = unescapeHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("//") {
            return "https:" + cleaned
        }
        return cleaned
    }

    private static func unescapeHTML(_ str: String) -> String {
        str.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
