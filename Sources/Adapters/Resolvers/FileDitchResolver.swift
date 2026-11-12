import ChrysaCore
import ChrysaApplication
import Foundation

package struct FileDitchResolver: HostResolver {
    package func canHandle(host: String, url: URL) -> Bool {
        host.contains("fileditch")
    }

    package func initialDownloadMessage(for url: URL) -> String? {
        "优选分流 (约10s)"
    }

    package func resolve(input: String, url: URL, passwords: [String]) async -> [ResolvedDownload] {
        let filename = url.lastPathComponent
        if let decoded = HostResolverRegistry.decodeBase64FilenameIfPossible(filename) {
            return [
                ResolvedDownload(
                    originalURL: input,
                    finalURL: input,
                    headers: [],
                    suggestedFilename: decoded
                )
            ]
        }

        // Resolution is limited to information in the supplied URL. Never inspect browser history.
        return []
    }
}
