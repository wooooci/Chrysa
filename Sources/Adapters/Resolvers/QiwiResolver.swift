import ChrysaCore
import ChrysaApplication
import Foundation

package struct QiwiResolver: HostResolver {
    package let id = "qiwi"
    package let bareDomains = ["qiwi.gg/", "www.qiwi.gg/"]

    package func canHandle(host: String, url: URL) -> Bool {
        host.contains("qiwi.gg")
    }

    package func matchesCDNHost(_ host: String) -> Bool {
        host.contains("qiwi.gg") || host.contains("spyderrock.com")
    }

    package func proxyNeeds() -> Bool { false }
    package func maxThreads() -> Int { 8 }

    package func resolveDetailed(
        input: String,
        url: URL,
        passwords: [String],
        settings: DownloadSettings
    ) async -> HostResolutionResult {
        guard let resp = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: input,
            policy: settings.proxyPolicy,
            preferDirect: true,
            timeoutSeconds: 20
        ) else {
            return HostResolutionResult(downloads: [], failureReason: "无法连接 Qiwi")
        }

        if resp.statusCode >= 400 {
            let reason = ResolverHTTPHelper.classifyFailure(
                statusCode: resp.statusCode,
                contentType: resp.contentType,
                body: resp.bodyString
            ) ?? "链接已失效"
            return HostResolutionResult(downloads: [], failureReason: reason)
        }

        let html = resp.bodyString ?? ""
        if let failure = ResolverHTTPHelper.classifyFailure(
            statusCode: resp.statusCode,
            contentType: resp.contentType,
            body: html
        ) {
            return HostResolutionResult(downloads: [], failureReason: failure)
        }

        let parsed = Self.parsePage(html: html, originalURL: url)
        guard !parsed.candidateURLs.isEmpty else {
            return HostResolutionResult(downloads: [], failureReason: "无法提取 Qiwi 直链")
        }

        let useProxy = ResolverHTTPHelper.effectiveUseProxy(policy: settings.proxyPolicy, defaultNeedsProxy: false)
        var lastFailure: String? = nil

        for candidate in parsed.candidateURLs {
            guard let probe = await ResolverHTTPHelper.probeDirectURL(
                candidate,
                headers: ["Referer": input],
                useProxy: useProxy
            ) else { continue }

            if probe.statusCode >= 400 {
                lastFailure = ResolverHTTPHelper.classifyFailure(
                    statusCode: probe.statusCode,
                    contentType: probe.contentType,
                    body: probe.bodyString
                ) ?? "链接已失效"
                continue
            }

            if let ct = probe.contentType?.lowercased(),
               ct.contains("text/html"),
               probe.contentDispositionFilename == nil {
                lastFailure = ResolverHTTPHelper.classifyFailure(
                    statusCode: probe.statusCode,
                    contentType: probe.contentType,
                    body: probe.bodyString
                ) ?? "含网页盾·请用浏览器下载"
                continue
            }

            let resolvedName = probe.contentDispositionFilename
                ?? parsed.filename
                ?? DownloadInputParser.inferFilenameFromURL(input)
                ?? URL(string: candidate)?.lastPathComponent

            return HostResolutionResult(downloads: [
                ResolvedDownload(
                    originalURL: input,
                    finalURL: probe.finalURL,
                    headers: ["Referer: \(input)"],
                    suggestedFilename: resolvedName,
                    totalSize: probe.contentLength,
                    maxThreads: maxThreads(),
                    needsProxy: false,
                    resolverID: id
                )
            ])
        }

        return HostResolutionResult(downloads: [], failureReason: lastFailure ?? "无法提取 Qiwi 直链")
    }

    package static func parsePage(html: String, originalURL: URL) -> (candidateURLs: [String], filename: String?) {
        var candidates: [String] = []

        let directPatterns = [
            #"https?://(?:[A-Za-z0-9-]+\.)?spyderrock\.com/[A-Za-z0-9._/%?=&+-]+"#,
            #"https?://(?:cdn|dl|download)[0-9]*\.qiwi\.gg/[^"'<>\s]+"#,
            #""(?:downloadUrl|directUrl|cdnUrl)"\s*:\s*"(https?://[^"]+)""#,
            #"<a[^>]*\bdownload\b[^>]*\bhref=["'](https?://[^"']+)["']"#
        ]
        for pattern in directPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for m in matches {
                let captureIdx = m.numberOfRanges > 1 ? 1 : 0
                if let r = Range(m.range(at: captureIdx), in: html) {
                    let link = String(html[r]).replacingOccurrences(of: "\\/", with: "/")
                    if !candidates.contains(link) {
                        candidates.append(link)
                    }
                }
            }
        }

        let filename = extractFilename(from: html)

        // Fallback Spyderrock CDN slug when Next.js page embeds file slug or path contains /file/<slug>
        let pathParts = originalURL.pathComponents.filter { $0 != "/" }
        if pathParts.count >= 2 && pathParts[0].lowercased() == "file" {
            let pageSlug = pathParts[1]
            let slugMatches = regexMatches(in: html, pattern: #""slug"\s*:\s*"([A-Za-z0-9._-]+)""#)
            let chosenSlug = slugMatches.first(where: { $0 != pageSlug }) ?? slugMatches.first ?? pageSlug
            let ext = filename.flatMap { ($0 as NSString).pathExtension }.flatMap { $0.isEmpty ? nil : $0 }
            if let ext {
                let withExt = "https://spyderrock.com/\(chosenSlug).\(ext)"
                if !candidates.contains(withExt) { candidates.append(withExt) }
            }
            let bare = "https://spyderrock.com/\(chosenSlug)"
            if !candidates.contains(bare) { candidates.append(bare) }
        }

        return (candidates, filename)
    }

    private static func extractFilename(from html: String) -> String? {
        let patterns = [
            #"<h1[^>]*class=["'][^"']*TextHeading[^"']*["'][^>]*>\s*([^<]+?)\s*</h1>"#,
            #"<meta[^>]*property=["']og:title["'][^>]*content=["']([^"']+)["']"#,
            #"<h1[^>]*>\s*([^<]+?)\s*</h1>"#,
            #"<title>\s*([^<]+?)\s*</title>"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let r = Range(m.range(at: 1), in: html) else { continue }
            var name = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            for suffix in [" - Qiwi", " | Qiwi", " - qiwi.gg"] {
                if name.lowercased().hasSuffix(suffix.lowercased()) {
                    name = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if !name.isEmpty, name.contains("."), !name.lowercased().contains("qiwi.gg") {
                return name
            }
        }
        return nil
    }

    private static func regexMatches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }
}
