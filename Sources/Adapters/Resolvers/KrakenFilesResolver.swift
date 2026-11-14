import ChrysaCore
import ChrysaApplication
import Foundation

package struct KrakenFilesResolver: HostResolver {
    package let id = "krakenfiles"
    package let bareDomains = ["krakenfiles.com/", "www.krakenfiles.com/"]

    package func canHandle(host: String, url: URL) -> Bool {
        host.contains("krakenfiles.com")
    }

    package func matchesCDNHost(_ host: String) -> Bool {
        host.contains("krakenfiles.com")
    }

    package func proxyNeeds() -> Bool { false }
    package func maxThreads() -> Int { 8 }

    package func resolveDetailed(
        input: String,
        url: URL,
        passwords: [String],
        settings: DownloadSettings
    ) async -> HostResolutionResult {
        let cookieFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-kraken-\(UUID().uuidString).cookies").path
        defer { try? FileManager.default.removeItem(atPath: cookieFile) }

        guard let pageResp = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: input,
            policy: settings.proxyPolicy,
            preferDirect: true,
            cookieFilePath: cookieFile,
            timeoutSeconds: 20
        ) else {
            return HostResolutionResult(downloads: [], failureReason: "无法连接 KrakenFiles")
        }

        if pageResp.statusCode >= 400 {
            let reason = ResolverHTTPHelper.classifyFailure(
                statusCode: pageResp.statusCode,
                contentType: pageResp.contentType,
                body: pageResp.bodyString
            ) ?? "链接已失效"
            return HostResolutionResult(downloads: [], failureReason: reason)
        }

        let html = pageResp.bodyString ?? ""
        if let failure = ResolverHTTPHelper.classifyFailure(
            statusCode: pageResp.statusCode,
            contentType: pageResp.contentType,
            body: html
        ) {
            return HostResolutionResult(downloads: [], failureReason: failure)
        }

        guard let parsed = Self.parseLandingPage(html: html, url: url) else {
            return HostResolutionResult(downloads: [], failureReason: "无法提取 KrakenFiles 令牌")
        }

        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        let encodedToken = parsed.token.addingPercentEncoding(withAllowedCharacters: allowed) ?? parsed.token
        let formBody = "token=\(encodedToken)"

        var headers: [String: String] = [
            "Referer": input,
            "Origin": "https://krakenfiles.com",
            "X-Requested-With": "XMLHttpRequest",
            "Accept": "application/json, text/javascript, */*; q=0.01",
            "Content-Type": "application/x-www-form-urlencoded"
        ]
        if let fileHash = parsed.fileHash {
            headers["hash"] = fileHash
        }

        guard let dlResp = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: parsed.actionURL,
            method: "POST",
            headers: headers,
            formBody: formBody,
            policy: settings.proxyPolicy,
            preferDirect: true,
            cookieFilePath: cookieFile,
            timeoutSeconds: 20
        ) else {
            return HostResolutionResult(downloads: [], failureReason: "KrakenFiles 请求失败")
        }

        if dlResp.statusCode >= 400 {
            let reason = ResolverHTTPHelper.classifyFailure(
                statusCode: dlResp.statusCode,
                contentType: dlResp.contentType,
                body: dlResp.bodyString
            ) ?? "无法提取 KrakenFiles 直链"
            return HostResolutionResult(downloads: [], failureReason: reason)
        }

        guard let directURL = Self.parseDownloadJSON(dlResp.bodyData) else {
            if let failure = ResolverHTTPHelper.classifyFailure(
                statusCode: dlResp.statusCode,
                contentType: dlResp.contentType,
                body: dlResp.bodyString
            ) {
                return HostResolutionResult(downloads: [], failureReason: failure)
            }
            return HostResolutionResult(downloads: [], failureReason: "无法提取 KrakenFiles 直链")
        }

        var extraHeaders: [String] = ["Referer: \(input)"]
        if let cookieHdr = ResolverHTTPHelper.cookieHeader(fromCookieFile: cookieFile) {
            extraHeaders.append("Cookie: \(cookieHdr)")
        }
        let headerDict = ResolverHTTPHelper.headerDictionary(from: extraHeaders)
        let useProxy = ResolverHTTPHelper.effectiveUseProxy(policy: settings.proxyPolicy, defaultNeedsProxy: false)
        let probe = await ResolverHTTPHelper.probeDirectURL(directURL, headers: headerDict, useProxy: useProxy)
        if let failure = ResolverHTTPHelper.validateDownloadProbe(probe) {
            return HostResolutionResult(downloads: [], failureReason: failure)
        }

        let resolvedName = probe?.contentDispositionFilename
            ?? parsed.filename
            ?? DownloadInputParser.inferFilenameFromURL(input)
            ?? URL(string: directURL)?.lastPathComponent

        return HostResolutionResult(downloads: [
            ResolvedDownload(
                originalURL: input,
                finalURL: probe?.finalURL ?? directURL,
                headers: extraHeaders,
                suggestedFilename: resolvedName,
                totalSize: probe?.contentLength,
                maxThreads: maxThreads(),
                needsProxy: false,
                resolverID: id
            )
        ])
    }

    package static func parseLandingPage(
        html: String,
        url: URL
    ) -> (actionURL: String, token: String, fileHash: String?, filename: String?)? {
        let parts = url.pathComponents.filter { $0 != "/" }
        let pathHash: String? = {
            if let viewIdx = parts.firstIndex(of: "view"), parts.count > viewIdx + 1 {
                return parts[viewIdx + 1]
            }
            return nil
        }()

        // Form `<form id="dl-form" action="/download/<hash>" ...><input type="hidden" name="token" value="...">`
        var actionPath: String? = nil
        if let formRegex = try? NSRegularExpression(pattern: #"<form[^>]*action=["']([^"']*download/[^"']+)["'][^>]*>"#, options: .caseInsensitive),
           let m = formRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r = Range(m.range(at: 1), in: html) {
            actionPath = String(html[r])
        }

        var token: String? = nil
        let tokenPatterns = [
            #"<input[^>]*\bname=["']token["'][^>]*\bvalue=["']([^"']+)["']"#,
            #"<input[^>]*\bvalue=["']([^"']+)["'][^>]*\bname=["']token["']"#,
            #"name=["']dl-token["'][^>]*value=["']([^"']+)["']"#
        ]
        for pattern in tokenPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let r = Range(m.range(at: 1), in: html) else { continue }
            let val = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !val.isEmpty {
                token = val
                break
            }
        }

        guard let extractedToken = token else { return nil }
        let fileHash = pathHash ?? actionPath.flatMap { URL(string: $0)?.lastPathComponent }
        let actionURL: String
        if let rawAction = actionPath {
            if rawAction.hasPrefix("http://") || rawAction.hasPrefix("https://") {
                actionURL = rawAction
            } else if rawAction.hasPrefix("/") {
                actionURL = "https://krakenfiles.com\(rawAction)"
            } else {
                actionURL = "https://krakenfiles.com/\(rawAction)"
            }
        } else if let fileHash {
            actionURL = "https://krakenfiles.com/download/\(fileHash)"
        } else {
            return nil
        }

        let filename = extractFilename(from: html)
        return (actionURL, extractedToken, fileHash, filename)
    }

    package static func parseDownloadJSON(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = json["url"] as? String,
              !url.isEmpty else {
            return nil
        }
        if url.hasPrefix("//") {
            return "https:" + url
        }
        return url.lowercased().hasPrefix("http") ? url : nil
    }

    private static func extractFilename(from html: String) -> String? {
        let patterns = [
            #"class=["'][^"']*coin-name[^"']*["'][^>]*>\s*([^<]+?)\s*<"#,
            #"<meta[^>]*property=["']og:title["'][^>]*content=["']([^"']+)["']"#,
            #"<title>\s*([^<]+?)\s*(?:-\s*Krakenfiles|\|\s*Krakenfiles|</title>)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let r = Range(m.range(at: 1), in: html) else { continue }
            let name = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, name.contains("."), !name.lowercased().contains("krakenfiles") {
                return name
            }
        }
        return nil
    }
}
