import ChrysaCore
import ChrysaApplication
import Foundation

package struct VikingFileResolver: HostResolver {
    package let id = "vikingfile"
    package let bareDomains = ["vikingfile.com/", "www.vikingfile.com/"]

    package func canHandle(host: String, url: URL) -> Bool {
        host.contains("vikingfile.com")
    }
    package func matchesCDNHost(_ host: String) -> Bool {
        host.contains("vikingfile.com")
    }
    package func proxyNeeds() -> Bool { false }
    package func maxThreads() -> Int { 8 }

    package func resolveDetailed(
        input: String,
        url: URL,
        passwords: [String],
        settings: DownloadSettings
    ) async -> HostResolutionResult {
        var dURL = input
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count >= 2 && parts[0] == "f" {
            dURL = "https://vikingfile.com/d/\(parts[1])"
        }

        let useProxy = ResolverHTTPHelper.effectiveUseProxy(policy: settings.proxyPolicy, defaultNeedsProxy: proxyNeeds())
        guard let headRes = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: dURL,
            method: "HEAD",
            policy: settings.proxyPolicy,
            preferDirect: true,
            followRedirects: false,
            timeoutSeconds: 15
        ) else {
            return HostResolutionResult(downloads: [], failureReason: "无法连接 VikingFile")
        }

        if headRes.statusCode >= 400 {
            let reason = ResolverHTTPHelper.classifyFailure(statusCode: headRes.statusCode, contentType: headRes.contentType, body: headRes.bodyString) ?? "链接已失效"
            return HostResolutionResult(downloads: [], failureReason: reason)
        }

        guard let resolvedCDN = headRes.headers["location"], !resolvedCDN.isEmpty else {
            // Check GET body in case page returned an HTML error or captcha
            if let getRes = await ResolverHTTPHelper.fetchWithPolicy(
                urlString: dURL,
                policy: settings.proxyPolicy,
                preferDirect: true,
                timeoutSeconds: 15
            ),
               let reason = ResolverHTTPHelper.classifyFailure(statusCode: getRes.statusCode, contentType: getRes.contentType, body: getRes.bodyString) {
                return HostResolutionResult(downloads: [], failureReason: reason)
            }
            return HostResolutionResult(downloads: [], failureReason: "链接已失效")
        }

        let probe = await ResolverHTTPHelper.probeDirectURL(resolvedCDN, useProxy: useProxy)
        let fname = probe?.contentDispositionFilename
            ?? URL(string: resolvedCDN)?.lastPathComponent
            ?? url.lastPathComponent
        let totalBytes = probe?.contentLength

        return HostResolutionResult(downloads: [
            ResolvedDownload(
                originalURL: dURL,
                finalURL: resolvedCDN,
                headers: [],
                suggestedFilename: fname,
                useChunkedRange: true,
                totalSize: totalBytes,
                maxThreads: maxThreads(),
                needsProxy: false,
                resolverID: id
            )
        ])
    }
}

package struct PixeldrainResolver: HostResolver {
    package let id = "pixeldrain"
    package let bareDomains = ["pixeldrain.com/", "www.pixeldrain.com/"]

    package func canHandle(host: String, url: URL) -> Bool {
        let parts = url.pathComponents.filter { $0 != "/" }
        return host.contains("pixeldrain.com") && parts.count >= 2 && (parts[0] == "u" || parts[0] == "l")
    }
    package func matchesCDNHost(_ host: String) -> Bool {
        host.contains("pixeldrain.com")
    }
    package func proxyNeeds() -> Bool { false }
    package func maxThreads() -> Int { 4 }

    package static func basicAuthHeaderValue(for apiKey: String) -> String? {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = ":\(trimmed)".data(using: .utf8)?.base64EncodedString() else {
            return nil
        }
        return "Basic \(encoded)"
    }

    package func resolveDetailed(
        input: String,
        url: URL,
        passwords: [String],
        settings: DownloadSettings
    ) async -> HostResolutionResult {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else {
            return HostResolutionResult(downloads: [], failureReason: "链接格式无效")
        }
        let kind = parts[0].lowercased()
        let itemID = parts[1]

        let basicAuth = Self.basicAuthHeaderValue(for: settings.pixeldrainAPIKey)
        let reqHeaders: [String: String] = basicAuth.map { ["Authorization": $0] } ?? [:]
        let itemHeaders: [String] = basicAuth.map { ["Authorization: \($0)"] } ?? []
        let hasKey = basicAuth != nil

        if kind == "l" {
            guard let listResp = await ResolverHTTPHelper.fetchWithPolicy(
                urlString: "https://pixeldrain.com/api/list/\(itemID)",
                headers: reqHeaders,
                policy: settings.proxyPolicy,
                preferDirect: true,
                timeoutSeconds: 20
            ) else {
                return HostResolutionResult(downloads: [], failureReason: "无法连接 Pixeldrain")
            }
            if listResp.statusCode >= 400 {
                let reason = ResolverHTTPHelper.classifyFailure(statusCode: listResp.statusCode, contentType: listResp.contentType, body: listResp.bodyString) ?? "链接已失效"
                return HostResolutionResult(downloads: [], failureReason: reason)
            }
            return Self.parseListJSON(
                listResp.bodyData,
                listID: itemID,
                originalInput: input,
                authHeaders: itemHeaders,
                hasAPIKey: hasKey
            )
        }

        let direct = "https://pixeldrain.com/api/file/\(itemID)?download"
        var realName: String? = nil
        var fileSize: Int64? = nil
        var rateLimitNote: String? = nil

        if let infoResp = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: "https://pixeldrain.com/api/file/\(itemID)/info",
            headers: reqHeaders,
            policy: settings.proxyPolicy,
            preferDirect: true,
            timeoutSeconds: 15
        ) {
            if infoResp.statusCode == 401 && hasKey {
                return HostResolutionResult(downloads: [], failureReason: "Pixeldrain API Key 无效")
            }
            if infoResp.statusCode == 404 || infoResp.statusCode == 410 {
                return HostResolutionResult(downloads: [], failureReason: "链接已失效")
            }
            if infoResp.statusCode == 429 {
                return HostResolutionResult(downloads: [], failureReason: "今日额度已满")
            }
            let parsedInfo = Self.parseFileInfoJSON(infoResp.bodyData, hasAPIKey: hasKey)
            if let failure = parsedInfo.failureReason {
                return HostResolutionResult(downloads: [], failureReason: failure)
            }
            realName = parsedInfo.name
            fileSize = parsedInfo.size
            rateLimitNote = parsedInfo.rateLimitNote
        }

        return HostResolutionResult(downloads: [
            ResolvedDownload(
                originalURL: input,
                finalURL: direct,
                headers: itemHeaders,
                suggestedFilename: realName ?? "pixeldrain_\(itemID).7z",
                useChunkedRange: false,
                totalSize: fileSize,
                maxThreads: hasKey ? 8 : maxThreads(),
                needsProxy: false,
                resolverID: id,
                rateLimitNote: rateLimitNote
            )
        ])
    }

    package static func parseFileInfoJSON(
        _ data: Data,
        hasAPIKey: Bool = false
    ) -> (name: String?, size: Int64?, rateLimitNote: String?, failureReason: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil, nil)
        }
        if (json["success"] as? Bool) == false {
            let val = (json["value"] as? String)?.lowercased() ?? ""
            if val.contains("not_found") {
                return (nil, nil, nil, "链接已失效")
            }
            if val.contains("limit") || val.contains("quota") {
                return (nil, nil, nil, "今日额度已满")
            }
        }

        let avail = (json["availability"] as? String)?.lowercased() ?? ""
        let canDownload = (json["can_download"] as? Bool) ?? true
        if !hasAPIKey {
            if !canDownload && avail.contains("captcha") {
                return (nil, nil, "限速 1MB/s", "今日额度已满")
            }
            if avail.contains("virus") && !canDownload {
                return (nil, nil, nil, "含网页盾·请用浏览器下载")
            }
        }

        let speedLimit = (json["download_speed_limit"] as? NSNumber)?.intValue ?? 0
        var rateNote: String? = nil
        if !hasAPIKey && (speedLimit > 0 || avail.contains("rate_limited")) {
            rateNote = "限速 1MB/s"
        }

        let rawName = (json["name"] as? String)
        let name = (rawName?.isEmpty == false) ? rawName : nil
        let size = (json["size"] as? NSNumber)?.int64Value
        return (name, size, rateNote, nil)
    }

    package static func parseListJSON(
        _ data: Data,
        listID: String,
        originalInput: String,
        authHeaders: [String] = [],
        hasAPIKey: Bool = false
    ) -> HostResolutionResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return HostResolutionResult(downloads: [], failureReason: "解析列表失败")
        }
        if (json["success"] as? Bool) == false {
            let val = (json["value"] as? String)?.lowercased() ?? ""
            if val.contains("not_found") {
                return HostResolutionResult(downloads: [], failureReason: "链接已失效")
            }
            if val.contains("limit") || val.contains("quota") {
                return HostResolutionResult(downloads: [], failureReason: "今日额度已满")
            }
            return HostResolutionResult(downloads: [], failureReason: "链接已失效")
        }

        guard let files = json["files"] as? [[String: Any]], !files.isEmpty else {
            return HostResolutionResult(downloads: [], failureReason: "分享列表为空")
        }

        let rawTitle = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let listTitle = (rawTitle?.isEmpty == false) ? rawTitle! : "pixeldrain_\(listID)"
        let subDir = files.count > 1 ? listTitle : nil

        var results: [ResolvedDownload] = []
        for file in files {
            guard let fid = file["id"] as? String, !fid.isEmpty else { continue }
            let name = (file["name"] as? String) ?? "pixeldrain_\(fid)"
            let size = (file["size"] as? NSNumber)?.int64Value
            let speedLimit = (file["download_speed_limit"] as? NSNumber)?.intValue ?? 0
            let avail = (file["availability"] as? String)?.lowercased() ?? ""
            let rateNote = (!hasAPIKey && (speedLimit > 0 || avail.contains("rate_limited"))) ? "限速 1MB/s" : nil
            results.append(
                ResolvedDownload(
                    originalURL: "https://pixeldrain.com/u/\(fid)",
                    finalURL: "https://pixeldrain.com/api/file/\(fid)?download",
                    headers: authHeaders,
                    suggestedFilename: name,
                    useChunkedRange: false,
                    totalSize: size,
                    subDirectory: subDir,
                    maxThreads: hasAPIKey ? 8 : 4,
                    needsProxy: false,
                    resolverID: "pixeldrain",
                    rateLimitNote: rateNote
                )
            )
        }

        if results.isEmpty {
            return HostResolutionResult(downloads: [], failureReason: "分享列表无有效文件")
        }
        return HostResolutionResult(downloads: results)
    }
}

package struct BuzzheavierResolver: HostResolver {
    package let id = "buzzheavier"
    package let bareDomains = ["buzzheavier.com/", "www.buzzheavier.com/", "bzzhr.co/", "www.bzzhr.co/"]

    package func canHandle(host: String, url: URL) -> Bool {
        host.contains("buzzheavier.com") || host.contains("bzzhr.co")
    }
    package func matchesCDNHost(_ host: String) -> Bool {
        host.contains("buzzheavier.com") || host.contains("bzzhr.co")
    }
    package func proxyNeeds() -> Bool { false }

    package func resolveDetailed(
        input: String,
        url: URL,
        passwords: [String],
        settings: DownloadSettings
    ) async -> HostResolutionResult {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let fileID = parts.first, !fileID.isEmpty else {
            return HostResolutionResult(downloads: [], failureReason: "链接格式无效")
        }
        let hostName = url.host ?? "buzzheavier.com"
        let useProxy = ResolverHTTPHelper.effectiveUseProxy(policy: settings.proxyPolicy, defaultNeedsProxy: false)

        // 1. Fetch landing page HTML to extract title/filename and catch 404/challenge
        var pageFilename: String? = nil
        if let pageResp = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: input,
            policy: settings.proxyPolicy,
            preferDirect: true,
            timeoutSeconds: 15
        ) {
            if pageResp.statusCode >= 400 {
                let reason = ResolverHTTPHelper.classifyFailure(statusCode: pageResp.statusCode, contentType: pageResp.contentType, body: pageResp.bodyString) ?? "链接已失效"
                return HostResolutionResult(downloads: [], failureReason: reason)
            }
            if let html = pageResp.bodyString {
                if let failure = ResolverHTTPHelper.classifyFailure(statusCode: pageResp.statusCode, contentType: pageResp.contentType, body: html) {
                    return HostResolutionResult(downloads: [], failureReason: failure)
                }
                pageFilename = Self.extractFilenameFromHTML(html)
            }
        }

        // 2. Request `/<id>/download` with HX-Request to get HX-Redirect / Location
        let dlEndpoint = "https://\(hostName)/\(fileID)/download"
        guard let dlResp = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: dlEndpoint,
            headers: [
                "HX-Request": "true",
                "Referer": input
            ],
            policy: settings.proxyPolicy,
            preferDirect: true,
            followRedirects: false,
            timeoutSeconds: 15
        ) else {
            return HostResolutionResult(downloads: [], failureReason: "无法连接 Buzzheavier")
        }

        guard let rawRedirect = dlResp.headers["hx-redirect"] ?? dlResp.headers["location"],
              !rawRedirect.isEmpty else {
            let reason = ResolverHTTPHelper.classifyFailure(
                statusCode: dlResp.statusCode,
                contentType: dlResp.contentType,
                body: dlResp.bodyString
            ) ?? "无法获取直链"
            return HostResolutionResult(downloads: [], failureReason: reason)
        }

        let finalRedirect: String
        if rawRedirect.hasPrefix("http://") || rawRedirect.hasPrefix("https://") {
            finalRedirect = rawRedirect
        } else if rawRedirect.hasPrefix("/") {
            finalRedirect = "https://\(hostName)\(rawRedirect)"
        } else {
            finalRedirect = "https://\(hostName)/\(rawRedirect)"
        }

        // 3. Probe redirect URL headers for Content-Disposition and Content-Length
        let probe = await ResolverHTTPHelper.probeDirectURL(
            finalRedirect,
            headers: ["Referer": input],
            useProxy: useProxy
        )
        let urlName = URL(string: probe?.finalURL ?? finalRedirect)?.lastPathComponent
        let urlNameHasExt = urlName.map { $0.contains(".") && $0 != fileID } ?? false

        let resolvedName = probe?.contentDispositionFilename
            ?? (urlNameHasExt ? urlName : nil)
            ?? pageFilename
            ?? (urlName?.isEmpty == false ? urlName : nil)

        return HostResolutionResult(downloads: [
            ResolvedDownload(
                originalURL: input,
                finalURL: finalRedirect,
                headers: ["Referer: \(input)"],
                suggestedFilename: resolvedName,
                totalSize: probe?.contentLength,
                maxThreads: maxThreads(),
                needsProxy: false,
                resolverID: id
            )
        ])
    }

    package static func extractFilenameFromHTML(_ html: String) -> String? {
        // Check <span class="...title..."> or <h1> or <title>
        let patterns = [
            #"<title>\s*([^<]+?)\s*</title>"#,
            #"<h1[^>]*>\s*([^<]+?)\s*</h1>"#,
            #"data-filename=["']([^"']+)["']"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let r = Range(m.range(at: 1), in: html) else { continue }
            var candidate = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            for suffix in [" - Buzzheavier", " | Buzzheavier", " - bzzhr", " | bzzhr"] {
                if candidate.lowercased().hasSuffix(suffix.lowercased()) {
                    candidate = String(candidate.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            for prefix in ["Buzzheavier - ", "bzzhr - "] {
                if candidate.lowercased().hasPrefix(prefix.lowercased()) {
                    candidate = String(candidate.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if !candidate.isEmpty, candidate.contains("."), !candidate.lowercased().contains("buzzheavier") {
                return candidate
            }
        }
        return nil
    }
}

package struct GoogleDriveResolver: HostResolver {
    package let id = "googledrive"
    package let bareDomains = ["drive.google.com/"]

    package func canHandle(host: String, url: URL) -> Bool {
        host.contains("drive.google.com") || host.contains("drive.usercontent.google.com")
    }
    package func matchesCDNHost(_ host: String) -> Bool {
        host.contains("drive.google.com") || host.contains("googleusercontent.com")
    }

    package func resolveDetailed(
        input: String,
        url: URL,
        passwords: [String],
        settings: DownloadSettings
    ) async -> HostResolutionResult {
        guard let fileID = Self.extractFileID(from: url) else {
            return HostResolutionResult(downloads: [], failureReason: "链接格式无效")
        }

        let probeURL = "https://drive.usercontent.google.com/download?id=\(fileID)&export=download"
        guard let resp = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: probeURL,
            policy: settings.proxyPolicy,
            preferDirect: false,
            rangeHeader: "bytes=0-0",
            timeoutSeconds: 20
        ) else {
            return HostResolutionResult(downloads: [], failureReason: "无法连接 Google Drive")
        }

        if resp.statusCode >= 400 {
            let reason = ResolverHTTPHelper.classifyFailure(
                statusCode: resp.statusCode,
                contentType: resp.contentType,
                body: resp.bodyString
            ) ?? "链接已失效"
            return HostResolutionResult(downloads: [], failureReason: reason)
        }

        let isHTML = resp.contentType?.lowercased().contains("text/html") == true
        if !isHTML {
            return HostResolutionResult(downloads: [
                ResolvedDownload(
                    originalURL: input,
                    finalURL: resp.finalURL,
                    headers: [],
                    suggestedFilename: resp.contentDispositionFilename ?? URL(string: resp.finalURL)?.lastPathComponent,
                    totalSize: resp.contentLength,
                    maxThreads: maxThreads(),
                    needsProxy: proxyNeeds(),
                    resolverID: id
                )
            ])
        }

        // Large file (>100MB) virus scan confirmation HTML or error HTML
        let fullResp = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: "https://drive.google.com/uc?export=download&id=\(fileID)",
            policy: settings.proxyPolicy,
            preferDirect: false,
            timeoutSeconds: 20
        ) ?? resp
        let html = fullResp.bodyString ?? resp.bodyString ?? ""

        if let parsed = Self.parseVirusScanForm(html: html, fallbackID: fileID) {
            let useProxy = ResolverHTTPHelper.effectiveUseProxy(policy: settings.proxyPolicy, defaultNeedsProxy: proxyNeeds())
            let headProbe = await ResolverHTTPHelper.probeDirectURL(parsed.finalURL, useProxy: useProxy)
            let filename = headProbe?.contentDispositionFilename ?? parsed.filename
            return HostResolutionResult(downloads: [
                ResolvedDownload(
                    originalURL: input,
                    finalURL: parsed.finalURL,
                    headers: [],
                    suggestedFilename: filename,
                    totalSize: headProbe?.contentLength,
                    maxThreads: maxThreads(),
                    needsProxy: proxyNeeds(),
                    resolverID: id
                )
            ])
        }

        if let failure = ResolverHTTPHelper.classifyFailure(statusCode: fullResp.statusCode, contentType: fullResp.contentType, body: html) {
            return HostResolutionResult(downloads: [], failureReason: failure)
        }

        return HostResolutionResult(downloads: [], failureReason: "无法绕过 Google Drive 确认页")
    }

    package static func extractFileID(from url: URL) -> String? {
        let parts = url.pathComponents
        if let dIdx = parts.firstIndex(of: "d"), parts.count > dIdx + 1 {
            return parts[dIdx + 1]
        }
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let idVal = comps.queryItems?.first(where: { $0.name == "id" })?.value,
           !idVal.isEmpty {
            return idVal
        }
        return nil
    }

    package static func parseVirusScanForm(html: String, fallbackID: String) -> (finalURL: String, filename: String?)? {
        // Match `<form id="download-form" action="..." ...>` or any form posting/getting to usercontent/uc
        let formPattern = #"<form[^>]*\baction=["']([^"']+)["'][^>]*>([\s\S]*?)</form>"#
        guard let formRegex = try? NSRegularExpression(pattern: formPattern, options: .caseInsensitive) else {
            return nil
        }
        let matches = formRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var chosenAction: String? = nil
        var chosenBody: String? = nil

        for m in matches where m.numberOfRanges >= 3 {
            guard let ar = Range(m.range(at: 1), in: html),
                  let br = Range(m.range(at: 2), in: html) else { continue }
            let action = String(html[ar])
            let body = String(html[br])
            if action.contains("download") || body.contains("confirm") || body.contains("uuid") {
                chosenAction = action
                chosenBody = body
                break
            }
        }

        guard let actionRaw = chosenAction, let formBody = chosenBody else {
            return nil
        }
        let action = actionRaw.replacingOccurrences(of: "&amp;", with: "&")

        // Extract all `<input type="hidden" name="..." value="...">` regardless of attribute order
        var params: [(String, String)] = []
        if let inputRegex = try? NSRegularExpression(pattern: #"<input\b[^>]*>"#, options: .caseInsensitive) {
            let inputMatches = inputRegex.matches(in: formBody, range: NSRange(formBody.startIndex..., in: formBody))
            for im in inputMatches {
                guard let ir = Range(im.range, in: formBody) else { continue }
                let tag = String(formBody[ir])
                guard let name = extractAttribute("name", from: tag),
                      let value = extractAttribute("value", from: tag) else { continue }
                params.append((name, value))
            }
        }

        if !params.contains(where: { $0.0 == "id" }) {
            params.append(("id", fallbackID))
        }
        if !params.contains(where: { $0.0 == "export" }) {
            params.append(("export", "download"))
        }
        if !params.contains(where: { $0.0 == "confirm" }) {
            params.append(("confirm", "t"))
        }

        guard var comps = URLComponents(string: action) else { return nil }
        var queryItems = comps.queryItems ?? []
        for (k, v) in params {
            if !queryItems.contains(where: { $0.name == k }) {
                queryItems.append(URLQueryItem(name: k, value: v))
            }
        }
        comps.queryItems = queryItems
        guard let builtURL = comps.url?.absoluteString else { return nil }

        // Extract filename from `<span class="uc-name-size"><a ...>filename</a>`
        var filename: String? = nil
        if let nameRegex = try? NSRegularExpression(pattern: #"uc-name-size[^>]*>\s*<a[^>]*>([^<]+)</a>"#, options: .caseInsensitive),
           let nm = nameRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let nr = Range(nm.range(at: 1), in: html) {
            let raw = String(html[nr]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty { filename = raw }
        }

        return (builtURL, filename)
    }

    private static func extractAttribute(_ attr: String, from tag: String) -> String? {
        let pattern = "\\b\(attr)\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let r = Range(m.range(at: 1), in: tag) else { return nil }
        return String(tag[r])
    }
}
