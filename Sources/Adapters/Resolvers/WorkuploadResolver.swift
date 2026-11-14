import ChrysaCore
import ChrysaApplication
import Foundation

package struct WorkuploadResolver: HostResolver {
    package let id = "workupload"
    package let bareDomains = ["workupload.com/", "www.workupload.com/"]

    package func canHandle(host: String, url: URL) -> Bool {
        host.contains("workupload.com")
    }

    package func matchesCDNHost(_ host: String) -> Bool {
        host.contains("workupload.com")
    }

    package func proxyNeeds() -> Bool { false }
    package func maxThreads() -> Int { 8 }

    package func resolveDetailed(
        input: String,
        url: URL,
        passwords: [String],
        settings: DownloadSettings
    ) async -> HostResolutionResult {
        guard let fileID = Self.extractFileID(from: url) else {
            return HostResolutionResult(downloads: [], failureReason: "链接格式无效")
        }

        let cookieFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-workupload-\(UUID().uuidString).cookies").path
        defer { try? FileManager.default.removeItem(atPath: cookieFile) }

        let filePageURL = "https://workupload.com/file/\(fileID)"
        guard let pageResp = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: filePageURL,
            policy: settings.proxyPolicy,
            preferDirect: true,
            cookieFilePath: cookieFile,
            timeoutSeconds: 20
        ) else {
            return HostResolutionResult(downloads: [], failureReason: "无法连接 Workupload")
        }

        if pageResp.statusCode >= 400 {
            let reason = ResolverHTTPHelper.classifyFailure(
                statusCode: pageResp.statusCode,
                contentType: pageResp.contentType,
                body: pageResp.bodyString
            ) ?? "链接已失效"
            return HostResolutionResult(downloads: [], failureReason: reason)
        }

        let pageHTML = pageResp.bodyString ?? ""
        if let failure = ResolverHTTPHelper.classifyFailure(
            statusCode: pageResp.statusCode,
            contentType: pageResp.contentType,
            body: pageHTML
        ) {
            return HostResolutionResult(downloads: [], failureReason: failure)
        }

        let pageFilename = Self.extractFilename(from: pageHTML)
        let startURL = "https://workupload.com/start/\(fileID)"
        _ = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: startURL,
            headers: ["Referer": filePageURL],
            policy: settings.proxyPolicy,
            preferDirect: true,
            cookieFilePath: cookieFile,
            timeoutSeconds: 15
        )

        let apiURL = "https://workupload.com/api/file/getDownloadServer/\(fileID)"
        guard let apiResp = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: apiURL,
            headers: [
                "Referer": startURL,
                "X-Requested-With": "XMLHttpRequest",
                "Accept": "application/json, text/javascript, */*; q=0.01"
            ],
            policy: settings.proxyPolicy,
            preferDirect: true,
            cookieFilePath: cookieFile,
            timeoutSeconds: 20
        ) else {
            return HostResolutionResult(downloads: [], failureReason: "无法获取 Workupload 直链")
        }

        if apiResp.statusCode >= 400 {
            let reason = ResolverHTTPHelper.classifyFailure(
                statusCode: apiResp.statusCode,
                contentType: apiResp.contentType,
                body: apiResp.bodyString
            ) ?? "链接已失效"
            return HostResolutionResult(downloads: [], failureReason: reason)
        }

        guard let directURL = Self.parseDownloadServerJSON(apiResp.bodyData) else {
            let bodyText = apiResp.bodyString ?? ""
            if let failure = ResolverHTTPHelper.classifyFailure(
                statusCode: apiResp.statusCode,
                contentType: apiResp.contentType,
                body: bodyText
            ) {
                return HostResolutionResult(downloads: [], failureReason: failure)
            }
            return HostResolutionResult(downloads: [], failureReason: "无法提取 Workupload 直链")
        }

        var extraHeaders: [String] = ["Referer: \(startURL)"]
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
            ?? pageFilename
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

    package static func extractFileID(from url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count >= 2 && (parts[0] == "file" || parts[0] == "start" || parts[0] == "archive") {
            return parts[1]
        }
        return nil
    }

    package static func parseDownloadServerJSON(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let success = json["success"] as? Bool, success,
              let dataDict = json["data"] as? [String: Any],
              let url = dataDict["url"] as? String,
              url.lowercased().hasPrefix("http") else {
            return nil
        }
        return url
    }

    package static func extractFilename(from html: String) -> String? {
        let patterns = [
            #"<div[^>]*class=["'][^"']*fileName[^"']*["'][^>]*>\s*([^<]+?)\s*</div>"#,
            #"<title>\s*([^<]+?)\s*(?:-\s*Workupload|\|\s*Workupload|</title>)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let r = Range(m.range(at: 1), in: html) else { continue }
            let name = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, name.contains("."), !name.lowercased().contains("workupload") {
                return name
            }
        }
        return nil
    }
}
