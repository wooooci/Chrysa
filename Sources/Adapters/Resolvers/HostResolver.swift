import ChrysaCore
import ChrysaApplication
import Foundation

package protocol HostResolver: Sendable {
    var id: String { get }
    var bareDomains: [String] { get }
    func canHandle(host: String, url: URL) -> Bool
    func matchesCDNHost(_ host: String) -> Bool
    func initialDownloadMessage(for url: URL) -> String?
    func resolve(input: String, url: URL, passwords: [String]) async -> [ResolvedDownload]
    func resolveDetailed(input: String, url: URL, passwords: [String]) async -> HostResolutionResult
    func resolveDetailed(input: String, url: URL, passwords: [String], settings: DownloadSettings) async -> HostResolutionResult
    func refresh(item: ResolvedDownload, passwords: [String]) async -> ResolvedDownload
    func refresh(item: ResolvedDownload, passwords: [String], settings: DownloadSettings) async -> ResolvedDownload
    func proxyNeeds() -> Bool
    func proxyNeeds(for url: URL) -> Bool
    func maxThreads() -> Int
}

package extension HostResolver {
    var id: String { String(describing: Self.self) }
    var bareDomains: [String] { [] }
    func matchesCDNHost(_ host: String) -> Bool { false }
    func initialDownloadMessage(for url: URL) -> String? { nil }
    func proxyNeeds() -> Bool { true }
    func proxyNeeds(for url: URL) -> Bool { proxyNeeds() }
    func maxThreads() -> Int { 16 }

    func resolve(input: String, url: URL, passwords: [String]) async -> [ResolvedDownload] {
        await resolveDetailed(input: input, url: url, passwords: passwords, settings: DownloadSettings()).downloads
    }

    func resolveDetailed(input: String, url: URL, passwords: [String]) async -> HostResolutionResult {
        await resolveDetailed(input: input, url: url, passwords: passwords, settings: DownloadSettings())
    }

    func resolveDetailed(input: String, url: URL, passwords: [String], settings: DownloadSettings) async -> HostResolutionResult {
        HostResolutionResult(downloads: [], failureReason: "无法获取直链")
    }

    func refresh(item: ResolvedDownload, passwords: [String]) async -> ResolvedDownload {
        await refresh(item: item, passwords: passwords, settings: DownloadSettings())
    }

    func refresh(item: ResolvedDownload, passwords: [String], settings: DownloadSettings) async -> ResolvedDownload {
        guard !item.originalURL.isEmpty,
              let url = URL(string: item.originalURL) else {
            return item
        }
        let refreshed = await resolveDetailed(
            input: item.originalURL,
            url: url,
            passwords: passwords,
            settings: settings
        ).downloads
        if let match = refreshed.first(where: { $0.suggestedFilename == item.suggestedFilename }) ?? refreshed.first {
            var mergedMirrors = item.mirrorURLs
            for m in match.mirrorURLs where m != item.originalURL && !mergedMirrors.contains(m) {
                mergedMirrors.append(m)
            }
            return ResolvedDownload(
                originalURL: item.originalURL,
                finalURL: match.finalURL,
                mirrorURLs: mergedMirrors,
                headers: match.headers,
                suggestedFilename: item.suggestedFilename ?? match.suggestedFilename,
                useChunkedRange: match.useChunkedRange,
                totalSize: match.totalSize ?? item.totalSize,
                subDirectory: item.subDirectory ?? match.subDirectory,
                mailRuWeblink: match.mailRuWeblink ?? item.mailRuWeblink,
                maxThreads: match.maxThreads ?? item.maxThreads,
                needsProxy: match.needsProxy ?? item.needsProxy,
                resolverID: match.resolverID ?? item.resolverID,
                rateLimitNote: match.rateLimitNote
            )
        }
        return item
    }
}

package struct UnsupportedHostResolver: HostResolver {
    package let id = "unsupported"
    private let blockedHosts: [(domain: String, reason: String)] = [
        ("mega.nz", "不支持该网盘·需专用客户端"),
        ("mega.co.nz", "不支持该网盘·需专用客户端"),
        ("rapidgator.net", "不支持该网盘·含网页盾"),
        ("nitroflare.com", "不支持该网盘·含网页盾"),
        ("katfile.com", "不支持该网盘·含网页盾"),
        ("turbobit.net", "不支持该网盘·含网页盾"),
        ("ddownload.com", "不支持该网盘·含网页盾")
    ]

    package func canHandle(host: String, url: URL) -> Bool {
        blockedHosts.contains { host == $0.domain || host.hasSuffix(".\($0.domain)") }
    }

    package func resolveDetailed(
        input: String,
        url: URL,
        passwords: [String],
        settings: DownloadSettings
    ) async -> HostResolutionResult {
        let host = url.host?.lowercased() ?? ""
        let reason = blockedHosts.first { host == $0.domain || host.hasSuffix(".\($0.domain)") }?.reason
            ?? "不支持该网盘"
        return HostResolutionResult(downloads: [], failureReason: reason)
    }
}

package enum HostResolverRegistry {
    private static let plugins: [any HostResolver] = [
        UnsupportedHostResolver(),
        MailRuResolver(),
        GofileResolver(),
        MirrorUploadXResolver(),
        FileDitchResolver(),
        VikingFileResolver(),
        PixeldrainResolver(),
        BuzzheavierResolver(),
        DataNodesResolver(),
        QiwiResolver(),
        WorkuploadResolver(),
        KrakenFilesResolver(),
        MediaFireResolver(),
        GoogleDriveResolver(),
        FuckingFastResolver(),
        OneFichierResolver()
    ]

    package static var knownBareDomains: [String] {
        plugins.flatMap(\.bareDomains)
    }

    package static func initialDownloadMessage(for input: String) -> String? {
        guard let url = URL(string: input), let host = url.host?.lowercased() else { return nil }
        return plugins.first(where: { $0.canHandle(host: host, url: url) })?.initialDownloadMessage(for: url)
    }

    package static func proxyNeeds(for urlString: String, resolvedNeeds: Bool? = nil) -> Bool {
        if let resolvedNeeds { return resolvedNeeds }
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else {
            return false
        }
        if let plugin = plugins.first(where: { $0.canHandle(host: host, url: url) || $0.matchesCDNHost(host) }) {
            return plugin.proxyNeeds(for: url)
        }
        let lower = host
        if lower == "github.com" || lower.hasSuffix(".github.com") || lower.hasSuffix("githubusercontent.com") {
            return true
        }
        return false
    }

    package static func maxThreads(
        for urlString: String,
        resolvedMax: Int? = nil,
        configuredMax: Int
    ) -> Int {
        let clamped = max(1, min(16, configuredMax))
        if let resolvedMax {
            return min(max(1, resolvedMax), clamped)
        }
        if let url = URL(string: urlString), let host = url.host?.lowercased(),
           let plugin = plugins.first(where: { $0.canHandle(host: host, url: url) || $0.matchesCDNHost(host) }) {
            return min(plugin.maxThreads(), clamped)
        }
        return clamped
    }

    package static func normalizeDownloadInput(_ raw: String) -> String? {
        DownloadInputParser.normalizeSingleURL(raw, knownBareDomains: knownBareDomains)
    }

    package static func decodeBase64FilenameIfPossible(_ raw: String) -> String? {
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

    package static func resolveLinks(
        _ input: String,
        passwords: [String] = AppSettings.defaultPasswords,
        settings: DownloadSettings = DownloadSettings()
    ) async -> [ResolvedDownload] {
        await resolveLinksDetailed(input, passwords: passwords, settings: settings).downloads
    }

    package static func resolveLinksDetailed(
        _ input: String,
        passwords: [String] = AppSettings.defaultPasswords,
        settings: DownloadSettings = DownloadSettings()
    ) async -> HostResolutionResult {
        guard let url = URL(string: input), let host = url.host?.lowercased() else {
            return HostResolutionResult(downloads: [], failureReason: "链接格式无效")
        }

        // Fast-path: JDownloader / FileDitch CDN Base64 token link
        if let decodedFilename = decodeBase64FilenameIfPossible(url.lastPathComponent) {
            let needsProxy = proxyNeeds(for: input)
            let maxT = maxThreads(for: input, configuredMax: 16)
            return HostResolutionResult(downloads: [
                ResolvedDownload(
                    originalURL: input,
                    finalURL: input,
                    headers: [],
                    suggestedFilename: decodedFilename,
                    maxThreads: maxT,
                    needsProxy: needsProxy,
                    resolverID: "base64-direct"
                )
            ])
        }

        if let debridItem = await DebridAccelerator.tryUnrestrict(originalURL: input, url: url, settings: settings) {
            return HostResolutionResult(downloads: [debridItem])
        }

        for plugin in plugins where plugin.canHandle(host: host, url: url) {
            let res = await plugin.resolveDetailed(input: input, url: url, passwords: passwords, settings: settings)
            let enriched = res.downloads.map { item in
                ResolvedDownload(
                    originalURL: item.originalURL,
                    finalURL: item.finalURL,
                    mirrorURLs: item.mirrorURLs,
                    headers: item.headers,
                    suggestedFilename: item.suggestedFilename,
                    useChunkedRange: item.useChunkedRange,
                    totalSize: item.totalSize,
                    subDirectory: item.subDirectory,
                    mailRuWeblink: item.mailRuWeblink,
                    maxThreads: item.maxThreads ?? plugin.maxThreads(),
                    needsProxy: item.needsProxy ?? plugin.proxyNeeds(for: url),
                    resolverID: item.resolverID ?? plugin.id,
                    rateLimitNote: item.rateLimitNote
                )
            }
            return HostResolutionResult(
                downloads: enriched,
                failureReason: res.failureReason,
                diagnostic: res.diagnostic
            )
        }

        return await resolveBareDirectURL(input: input, url: url, settings: settings)
    }

    private static func resolveBareDirectURL(
        input: String,
        url: URL,
        settings: DownloadSettings = DownloadSettings()
    ) async -> HostResolutionResult {
        let lastComp = url.lastPathComponent
        let hasValidExt = !lastComp.isEmpty && lastComp != "/" && ResolverHTTPHelper.hasKnownBinaryOrArchiveExtension(lastComp)
        let defaultNeedsProxy = proxyNeeds(for: input)
        let useProxyProbe = ResolverHTTPHelper.effectiveUseProxy(policy: settings.proxyPolicy, defaultNeedsProxy: defaultNeedsProxy)

        if hasValidExt {
            return HostResolutionResult(downloads: [
                ResolvedDownload(
                    originalURL: input,
                    finalURL: input,
                    headers: [],
                    suggestedFilename: lastComp,
                    needsProxy: defaultNeedsProxy,
                    resolverID: "direct"
                )
            ])
        }

        // Bare CDN link without valid file extension in path -> HEAD / Range: bytes=0-0 probe
        if let probe = await ResolverHTTPHelper.probeDirectURL(input, useProxy: useProxyProbe) {
            if let failure = ResolverHTTPHelper.validateDownloadProbe(probe) {
                return HostResolutionResult(downloads: [], failureReason: failure)
            }
            let finalURLObj = URL(string: probe.finalURL)
            let finalPathName = finalURLObj?.lastPathComponent
            let resolvedFilename = probe.contentDispositionFilename
                ?? (finalPathName?.contains(".") == true ? finalPathName : nil)
                ?? (lastComp.isEmpty || lastComp == "/" ? nil : lastComp)
            return HostResolutionResult(downloads: [
                ResolvedDownload(
                    originalURL: input,
                    finalURL: probe.finalURL,
                    headers: [],
                    suggestedFilename: resolvedFilename,
                    totalSize: probe.contentLength,
                    needsProxy: proxyNeeds(for: probe.finalURL),
                    resolverID: "direct-probed"
                )
            ])
        }

        return HostResolutionResult(downloads: [
            ResolvedDownload(
                originalURL: input,
                finalURL: input,
                headers: [],
                suggestedFilename: lastComp.isEmpty || lastComp == "/" ? nil : lastComp,
                needsProxy: defaultNeedsProxy,
                resolverID: "direct"
            )
        ])
    }

    package static func resolveSingleLink(
        _ input: String,
        passwords: [String] = AppSettings.defaultPasswords,
        settings: DownloadSettings = DownloadSettings()
    ) async -> ResolvedDownload {
        if let first = await resolveLinks(input, passwords: passwords, settings: settings).first {
            return first
        }
        let fallbackName = URL(string: input)?.lastPathComponent
        return ResolvedDownload(originalURL: input, finalURL: input, headers: [], suggestedFilename: fallbackName)
    }

    package static func refreshDownload(
        _ item: ResolvedDownload,
        passwords: [String] = AppSettings.defaultPasswords,
        settings: DownloadSettings = DownloadSettings()
    ) async -> ResolvedDownload {
        if !item.originalURL.isEmpty,
           let origURL = URL(string: item.originalURL),
           let debrid = await DebridAccelerator.tryUnrestrict(originalURL: item.originalURL, url: origURL, settings: settings) {
            return debrid.appendingMirrors(item.mirrorURLs)
        }
        if let resolverID = item.resolverID,
           let plugin = plugins.first(where: { $0.id == resolverID }) {
            return await plugin.refresh(item: item, passwords: passwords, settings: settings)
        }
        if let url = URL(string: item.originalURL),
           let host = url.host?.lowercased(),
           let plugin = plugins.first(where: { $0.canHandle(host: host, url: url) || $0.matchesCDNHost(host) }) {
            return await plugin.refresh(item: item, passwords: passwords, settings: settings)
        }
        return item
    }
}
