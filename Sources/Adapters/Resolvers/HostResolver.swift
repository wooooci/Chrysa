import ChrysaCore
import ChrysaApplication
import Foundation

package protocol HostResolver: Sendable {
    func canHandle(host: String, url: URL) -> Bool
    func resolve(input: String, url: URL, passwords: [String]) async -> [ResolvedDownload]
}

package enum HostResolverRegistry {
    private static let plugins: [any HostResolver] = [
        MailRuResolver(),
        GofileResolver(),
        MirrorUploadXResolver(),
        FileDitchResolver(),
        VikingFileResolver(),
        PixeldrainResolver(),
        BuzzheavierResolver(),
        MediaFireResolver(),
        GoogleDriveResolver()
    ]

    package static func normalizeDownloadInput(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("magnet:") {
            return trimmed
        }
        let lower = trimmed.lowercased()
        let knownDomains = [
            "gofile.io/", "www.gofile.io/",
            "pixeldrain.com/", "www.pixeldrain.com/",
            "buzzheavier.com/", "www.buzzheavier.com/",
            "vikingfile.com/", "www.vikingfile.com/",
            "itsfileditchfiles.st/", "fileditchfiles.st/", "fileditch.com/",
            "mirroruploadx.com/", "www.mirroruploadx.com/",
            "cloud.mail.ru/",
            "mediafire.com/", "www.mediafire.com/",
            "drive.google.com/",
            "mega.nz/",
            "1fichier.com/"
        ]
        if knownDomains.contains(where: { lower.hasPrefix($0) }) {
            return "https://" + trimmed
        }
        if !trimmed.contains(" "),
           let slashIdx = trimmed.firstIndex(of: "/"),
           trimmed[..<slashIdx].contains(".") {
            return "https://" + trimmed
        }
        return nil
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

    package static func resolveLinks(_ input: String, passwords: [String] = AppSettings.defaultPasswords) async -> [ResolvedDownload] {
        guard let url = URL(string: input), let host = url.host?.lowercased() else {
            return [ResolvedDownload(originalURL: input, finalURL: input, headers: [], suggestedFilename: nil)]
        }

        // Fast-path: JDownloader / FileDitch CDN Base64 token link
        if let decodedFilename = decodeBase64FilenameIfPossible(url.lastPathComponent) {
            return [
                ResolvedDownload(
                    originalURL: input,
                    finalURL: input,
                    headers: [],
                    suggestedFilename: decodedFilename
                )
            ]
        }

        for plugin in plugins where plugin.canHandle(host: host, url: url) {
            return await plugin.resolve(input: input, url: url, passwords: passwords)
        }

        return [
            ResolvedDownload(
                originalURL: input,
                finalURL: input,
                headers: [],
                suggestedFilename: url.lastPathComponent.isEmpty ? nil : url.lastPathComponent
            )
        ]
    }

    package static func resolveSingleLink(_ input: String, passwords: [String] = AppSettings.defaultPasswords) async -> ResolvedDownload {
        if let first = await resolveLinks(input, passwords: passwords).first {
            return first
        }
        let fallbackName = URL(string: input)?.lastPathComponent
        return ResolvedDownload(originalURL: input, finalURL: input, headers: [], suggestedFilename: fallbackName)
    }
}
