import ChrysaCore
import ChrysaApplication
import Foundation

package struct FuckingFastResolver: HostResolver {
    package let id = "fuckingfast"
    package let bareDomains = ["fuckingfast.co/", "www.fuckingfast.co/"]

    package func canHandle(host: String, url: URL) -> Bool {
        host.contains("fuckingfast.co")
    }
    package func matchesCDNHost(_ host: String) -> Bool {
        host.contains("fuckingfast.co")
    }
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
            preferDirect: false,
            timeoutSeconds: 20
        ),
              let html = resp.bodyString else {
            return HostResolutionResult(downloads: [], failureReason: "无法连接 FuckingFast")
        }

        if let failure = ResolverHTTPHelper.classifyFailure(statusCode: resp.statusCode, contentType: resp.contentType, body: html) {
            return HostResolutionResult(downloads: [], failureReason: failure)
        }

        guard let parsed = Self.parsePage(html: html, originalURL: input) else {
            return HostResolutionResult(downloads: [], failureReason: "无法提取 FuckingFast 直链")
        }

        let useProxy = ResolverHTTPHelper.effectiveUseProxy(policy: settings.proxyPolicy, defaultNeedsProxy: proxyNeeds())
        let probe = await ResolverHTTPHelper.probeDirectURL(
            parsed.directURL,
            headers: ["Referer": input],
            useProxy: useProxy
        )
        let finalFilename = probe?.contentDispositionFilename
            ?? parsed.filename
            ?? DownloadInputParser.inferFilenameFromURL(input)

        return HostResolutionResult(downloads: [
            ResolvedDownload(
                originalURL: input,
                finalURL: parsed.directURL,
                headers: ["Referer: \(input)"],
                suggestedFilename: finalFilename,
                totalSize: probe?.contentLength,
                maxThreads: maxThreads(),
                needsProxy: proxyNeeds(),
                resolverID: id
            )
        ])
    }

    package static func parsePage(html: String, originalURL: String) -> (directURL: String, filename: String?)? {
        // Extract `https://fuckingfast.co/dl/...` from JS `window.open(...)`, `fetch(...)`, or href
        let dlPattern = #"https?://(?:www\.)?fuckingfast\.co/dl/[A-Za-z0-9_-]+"#
        guard let dlRegex = try? NSRegularExpression(pattern: dlPattern, options: .caseInsensitive),
              let dlMatch = dlRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let dlRange = Range(dlMatch.range, in: html) else {
            return nil
        }
        let directURL = String(html[dlRange])

        var filename: String? = nil
        if let frag = URL(string: originalURL)?.fragment?.removingPercentEncoding,
           !frag.isEmpty,
           frag.contains(".") {
            filename = (frag as NSString).lastPathComponent
        }

        if filename == nil {
            let namePatterns = [
                #"<meta[^>]*name=["']title["'][^>]*content=["']([^"']+)["']"#,
                #"<h1[^>]*>\s*([^<]+?)\s*</h1>"#,
                #"<title>\s*([^<]+?)\s*</title>"#
            ]
            for pattern in namePatterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                      let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                      let r = Range(m.range(at: 1), in: html) else { continue }
                var candidate = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                for suffix in [" - FuckingFast", " | FuckingFast"] {
                    if candidate.lowercased().hasSuffix(suffix.lowercased()) {
                        candidate = String(candidate.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                if !candidate.isEmpty, candidate.contains("."), !candidate.lowercased().contains("fuckingfast") {
                    filename = candidate
                    break
                }
            }
        }

        return (directURL, filename)
    }
}
