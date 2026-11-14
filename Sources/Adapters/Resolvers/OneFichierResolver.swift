import ChrysaCore
import ChrysaApplication
import Foundation

package struct OneFichierResolver: HostResolver {
    package let id = "1fichier"
    package let bareDomains = ["1fichier.com/", "www.1fichier.com/"]

    package func canHandle(host: String, url: URL) -> Bool {
        host.contains("1fichier.com")
    }
    package func matchesCDNHost(_ host: String) -> Bool {
        host.contains("1fichier.com")
    }
    package func maxThreads() -> Int { 1 }

    package func resolveDetailed(
        input: String,
        url: URL,
        passwords: [String],
        settings: DownloadSettings
    ) async -> HostResolutionResult {
        let cookieFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-1fichier-\(UUID().uuidString).cookies").path
        defer { try? FileManager.default.removeItem(atPath: cookieFile) }

        let useProxy = ResolverHTTPHelper.effectiveUseProxy(policy: settings.proxyPolicy, defaultNeedsProxy: proxyNeeds())
        guard let initialResp = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: input,
            policy: settings.proxyPolicy,
            preferDirect: false,
            cookieFilePath: cookieFile,
            timeoutSeconds: 20
        ), let html = initialResp.bodyString else {
            return HostResolutionResult(downloads: [], failureReason: "无法连接 1fichier")
        }

        // Check if URL already returned a binary attachment directly
        if initialResp.contentType?.lowercased().contains("text/html") == false,
           let cdName = initialResp.contentDispositionFilename {
            return HostResolutionResult(downloads: [
                ResolvedDownload(
                    originalURL: input,
                    finalURL: initialResp.finalURL,
                    headers: [],
                    suggestedFilename: cdName,
                    totalSize: initialResp.contentLength,
                    maxThreads: 1,
                    needsProxy: proxyNeeds(),
                    resolverID: id
                )
            ])
        }

        if let failure = Self.classify1FichierFailure(statusCode: initialResp.statusCode, html: html) {
            return HostResolutionResult(downloads: [], failureReason: failure)
        }

        // If the page already contains a direct CDN link
        if let direct = Self.parseDownloadPage(html: html) {
            return HostResolutionResult(downloads: [
                ResolvedDownload(
                    originalURL: input,
                    finalURL: direct.directURL,
                    headers: ["Referer: \(input)"],
                    suggestedFilename: direct.filename,
                    maxThreads: 1,
                    needsProxy: proxyNeeds(),
                    resolverID: id
                )
            ])
        }

        // Otherwise extract the captcha-free form (`adz` / hidden inputs) and POST
        guard let form = Self.parseInitialForm(html: html, baseURL: input) else {
            return HostResolutionResult(downloads: [], failureReason: "含网页盾·请用浏览器下载")
        }

        let postResp = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: form.actionURL,
            method: "POST",
            headers: [
                "Referer": input,
                "Origin": "https://1fichier.com",
                "Content-Type": "application/x-www-form-urlencoded"
            ],
            formBody: form.formBody,
            policy: settings.proxyPolicy,
            preferDirect: false,
            cookieFilePath: cookieFile,
            timeoutSeconds: 20
        )

        guard let postResp else {
            return HostResolutionResult(downloads: [], failureReason: "1fichier 请求失败")
        }
        if postResp.contentType?.lowercased().contains("text/html") == false,
           let cdName = postResp.contentDispositionFilename {
            return HostResolutionResult(downloads: [
                ResolvedDownload(
                    originalURL: input,
                    finalURL: postResp.finalURL,
                    headers: [],
                    suggestedFilename: cdName,
                    totalSize: postResp.contentLength,
                    maxThreads: 1,
                    needsProxy: proxyNeeds(),
                    resolverID: id
                )
            ])
        }

        let postHTML = postResp.bodyString ?? ""
        if let failure = Self.classify1FichierFailure(statusCode: postResp.statusCode, html: postHTML) {
            return HostResolutionResult(downloads: [], failureReason: failure)
        }

        guard let direct = Self.parseDownloadPage(html: postHTML) else {
            return HostResolutionResult(downloads: [], failureReason: "无法提取 1fichier 直链")
        }

        let probe = await ResolverHTTPHelper.probeDirectURL(
            direct.directURL,
            headers: ["Referer": input],
            useProxy: useProxy
        )
        return HostResolutionResult(downloads: [
            ResolvedDownload(
                originalURL: input,
                finalURL: direct.directURL,
                headers: ["Referer: \(input)"],
                suggestedFilename: probe?.contentDispositionFilename ?? direct.filename ?? Self.extractFilenameFromTable(html: html),
                totalSize: probe?.contentLength,
                maxThreads: 1,
                needsProxy: proxyNeeds(),
                resolverID: id
            )
        ])
    }

    package static func classify1FichierFailure(statusCode: Int, html: String) -> String? {
        let lower = html.lowercased()
        if lower.contains("g-recaptcha") || lower.contains("h-captcha") || lower.contains("cf-turnstile") {
            return "含网页盾·请用浏览器下载"
        }
        if lower.contains("without subscription") && (lower.contains("you must wait") || lower.contains("minutes")) {
            return "今日额度已满"
        }
        if lower.contains("name=\"pass\"") || lower.contains("this file is password protected") {
            return "需访问密码"
        }
        if lower.contains("the requested file could not be found") || lower.contains("file has been deleted") {
            return "链接已失效"
        }
        return ResolverHTTPHelper.classifyFailure(statusCode: statusCode, contentType: "text/html", body: html)
    }

    package static func parseInitialForm(html: String, baseURL: String) -> (actionURL: String, formBody: String)? {
        let formPattern = #"<form[^>]*method=["']post["'][^>]*>([\s\S]*?)</form>"#
        guard let formRegex = try? NSRegularExpression(pattern: formPattern, options: .caseInsensitive),
              let fm = formRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let tagRange = Range(fm.range, in: html),
              let bodyRange = Range(fm.range(at: 1), in: html) else {
            return nil
        }

        let fullFormTag = String(html[tagRange])
        let formBodyHTML = String(html[bodyRange])

        var actionURL = baseURL
        if let actionRegex = try? NSRegularExpression(pattern: #"\baction=["']([^"']+)["']"#, options: .caseInsensitive),
           let am = actionRegex.firstMatch(in: fullFormTag, range: NSRange(fullFormTag.startIndex..., in: fullFormTag)),
           let ar = Range(am.range(at: 1), in: fullFormTag) {
            let rawAction = String(fullFormTag[ar])
            if rawAction.hasPrefix("http") {
                actionURL = rawAction
            } else if rawAction.hasPrefix("/") {
                actionURL = "https://1fichier.com\(rawAction)"
            }
        }

        var fields: [String] = []
        if let inputRegex = try? NSRegularExpression(pattern: #"<input\b[^>]*>"#, options: .caseInsensitive) {
            for m in inputRegex.matches(in: formBodyHTML, range: NSRange(formBodyHTML.startIndex..., in: formBodyHTML)) {
                guard let r = Range(m.range, in: formBodyHTML) else { continue }
                let tag = String(formBodyHTML[r])
                if tag.lowercased().contains("name=\"pass\"") { continue }
                guard let name = extractAttr("name", from: tag) else { continue }
                let value = extractAttr("value", from: tag) ?? ""
                let encName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
                let encVal = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                fields.append("\(encName)=\(encVal)")
            }
        }
        if !fields.contains(where: { $0.hasPrefix("dl_no_ssl=") }) {
            fields.append("dl_no_ssl=on")
        }
        guard !fields.isEmpty else { return nil }
        return (actionURL, fields.joined(separator: "&"))
    }

    package static func parseDownloadPage(html: String) -> (directURL: String, filename: String?)? {
        let linkPattern = #"href=["'](https?://[a-z0-9-]+\.1fichier\.com/[a-zA-Z0-9_-]+)["']"#
        guard let regex = try? NSRegularExpression(pattern: linkPattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let directURL = String(html[r])
        return (directURL, extractFilenameFromTable(html: html))
    }

    private static func extractFilenameFromTable(html: String) -> String? {
        let pattern = #"Filename\s*:\s*</td>\s*<td[^>]*>([^<]+)</td>"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r = Range(m.range(at: 1), in: html) {
            let name = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return nil
    }

    private static func extractAttr(_ attr: String, from tag: String) -> String? {
        let pattern = "\\b\(attr)\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let r = Range(m.range(at: 1), in: tag) else { return nil }
        return String(tag[r])
    }
}
