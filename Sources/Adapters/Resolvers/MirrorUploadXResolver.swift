import ChrysaCore
import ChrysaApplication
import Foundation

package struct MirrorUploadXResolver: HostResolver {
    package let id = "mirroruploadx"
    package let bareDomains = ["mirroruploadx.com/", "www.mirroruploadx.com/"]

    package static let preferredProviders = [
        "gofile",
        "fuckingfast",
        "buzzheavier",
        "pixeldrain",
        "vikingfile"
    ]

    package func canHandle(host: String, url: URL) -> Bool {
        host.contains("mirroruploadx.com")
    }
    package func matchesCDNHost(_ host: String) -> Bool {
        host.contains("mirroruploadx.com")
    }

    package func initialDownloadMessage(for url: URL) -> String? {
        "优选分流 (约10s)"
    }

    package func resolveDetailed(
        input: String,
        url: URL,
        passwords: [String],
        settings: DownloadSettings
    ) async -> HostResolutionResult {
        await Self.resolveMirrorUploadX(urlString: input, passwords: passwords, settings: settings)
    }

    package static func resolveMirrorUploadX(
        urlString: String,
        passwords: [String],
        settings: DownloadSettings = DownloadSettings()
    ) async -> HostResolutionResult {
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:150.0) Gecko/20100101 Firefox/150.0"
        let useProxy = ResolverHTTPHelper.effectiveUseProxy(policy: settings.proxyPolicy, defaultNeedsProxy: true)
        guard let pageResp = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: urlString,
            headers: ["User-Agent": ua],
            policy: settings.proxyPolicy,
            preferDirect: false,
            timeoutSeconds: 20
        ), let rawHTML = pageResp.bodyString, !rawHTML.isEmpty else {
            return HostResolutionResult(downloads: [], failureReason: "无法连接 MirrorUploadX")
        }

        if let failure = ResolverHTTPHelper.classifyFailure(
            statusCode: pageResp.statusCode,
            contentType: pageResp.contentType,
            body: rawHTML
        ) {
            return HostResolutionResult(downloads: [], failureReason: failure)
        }

        let cleanHTML = rawHTML.replacingOccurrences(of: "\\\"", with: "\"")

        var delaySec: Double = 10.0
        if let dMatch = try? NSRegularExpression(pattern: #""downloadDelaySeconds"\s*:\s*([0-9]+)"#).firstMatch(
            in: cleanHTML, range: NSRange(cleanHTML.startIndex..., in: cleanHTML)
        ), let r = Range(dMatch.range(at: 1), in: cleanHTML), let val = Double(cleanHTML[r]) {
            delaySec = min(max(val, 1.0), 15.0)
        }

        let preferredClickURLs = extractOrderedProviders(from: cleanHTML)
        guard !preferredClickURLs.isEmpty else {
            return HostResolutionResult(downloads: [], failureReason: "未找到可用分流节点")
        }

        try? await Task.sleep(nanoseconds: UInt64((delaySec + 0.8) * 1_000_000_000))

        var lastFailure: String? = nil
        var primaryResult: HostResolutionResult? = nil
        var backupMirrors: [String] = []

        for (_, clickURL) in preferredClickURLs {
            guard let hdrResp = await ResolverHTTPHelper.fetch(
                urlString: clickURL,
                method: "HEAD",
                headers: ["User-Agent": ua, "Referer": urlString],
                useProxy: useProxy,
                followRedirects: false,
                timeoutSeconds: 15
            ) else { continue }

            if let loc = hdrResp.headers["location"],
               !loc.isEmpty,
               !loc.contains("mirroruploadx.com") {
                if let primary = primaryResult {
                    if primary.downloads.contains(where: { $0.originalURL != loc }) && !backupMirrors.contains(loc) {
                        backupMirrors.append(loc)
                    }
                    if backupMirrors.count >= 3 { break }
                    continue
                }

                let resolved = await HostResolverRegistry.resolveLinksDetailed(loc, passwords: passwords, settings: settings)
                if !resolved.downloads.isEmpty {
                    primaryResult = resolved
                } else {
                    lastFailure = resolved.failureReason ?? lastFailure
                }
            }
        }

        if let primaryResult {
            let enriched = primaryResult.downloads.map { $0.appendingMirrors(backupMirrors) }
            return HostResolutionResult(downloads: enriched, failureReason: primaryResult.failureReason, diagnostic: primaryResult.diagnostic)
        }
        return HostResolutionResult(downloads: [], failureReason: lastFailure ?? "下游分流全部失效")
    }

    package static func extractOrderedProviders(from cleanHTML: String) -> [(String, String)] {
        let pattern = #""provider"\s*:\s*"([^"]+)"[\s\S]{1,600}?"clickUrl"\s*:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }
        let matches = regex.matches(in: cleanHTML, range: NSRange(cleanHTML.startIndex..., in: cleanHTML))
        var byProvider: [String: String] = [:]
        var orderedKeys: [String] = []
        for m in matches {
            if let rProv = Range(m.range(at: 1), in: cleanHTML),
               let rClick = Range(m.range(at: 2), in: cleanHTML) {
                let prov = String(cleanHTML[rProv]).lowercased()
                let rawClick = String(cleanHTML[rClick])
                let fullClick = rawClick.hasPrefix("http") ? rawClick : "https://mirroruploadx.com\(rawClick)"
                if byProvider[prov] == nil {
                    orderedKeys.append(prov)
                }
                byProvider[prov] = fullClick
            }
        }

        var result: [(String, String)] = []
        var used: Set<String> = []
        for hostKey in preferredProviders {
            if let c = byProvider[hostKey] {
                result.append((hostKey, c))
                used.insert(hostKey)
            } else if let matchedKey = orderedKeys.first(where: { $0.contains(hostKey) && !used.contains($0) }),
                      let c = byProvider[matchedKey] {
                result.append((matchedKey, c))
                used.insert(matchedKey)
            }
        }
        for key in orderedKeys where !used.contains(key) {
            if let c = byProvider[key] {
                result.append((key, c))
            }
        }
        return result
    }
}
