import ChrysaCore
import ChrysaApplication
import Foundation

package struct FileDitchResolver: HostResolver {
    package let id = "fileditch"
    package let bareDomains = ["itsfileditchfiles.st/", "fileditchfiles.st/", "fileditch.com/"]

    package func canHandle(host: String, url: URL) -> Bool {
        host.contains("fileditch")
    }

    package func matchesCDNHost(_ host: String) -> Bool {
        host.contains("fileditch")
    }

    package func initialDownloadMessage(for url: URL) -> String? {
        "优选分流 (约10s)"
    }

    package func maxThreads() -> Int { 2 }

    package func resolveDetailed(
        input: String,
        url: URL,
        passwords: [String],
        settings: DownloadSettings
    ) async -> HostResolutionResult {
        let filename = url.lastPathComponent
        if let decoded = HostResolverRegistry.decodeBase64FilenameIfPossible(filename) {
            return HostResolutionResult(downloads: [
                ResolvedDownload(
                    originalURL: input,
                    finalURL: input,
                    headers: [],
                    suggestedFilename: decoded,
                    maxThreads: maxThreads(),
                    needsProxy: proxyNeeds(),
                    resolverID: id
                )
            ])
        }

        // Resolution is limited to information in the supplied URL. Never inspect browser history.
        return HostResolutionResult(downloads: [], failureReason: "无法提取 FileDitch 直链")
    }
}
