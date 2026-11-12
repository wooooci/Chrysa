import ChrysaCore
import ChrysaApplication
import Foundation

package struct MirrorUploadXResolver: HostResolver {
    package func canHandle(host: String, url: URL) -> Bool {
        host.contains("mirroruploadx.com")
    }

    package func initialDownloadMessage(for url: URL) -> String? {
        "优选分流 (约10s)"
    }

    package func resolve(input: String, url: URL, passwords: [String]) async -> [ResolvedDownload] {
        await Self.resolveMirrorUploadX(urlString: input, passwords: passwords)
    }

    package static func resolveMirrorUploadX(urlString: String, passwords: [String]) async -> [ResolvedDownload] {
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:150.0) Gecko/20100101 Firefox/150.0"
        guard let res = try? await ProcessSupervisor.shared.run(
            executable: "/usr/bin/curl",
            arguments: ["-sL", "-A", ua, urlString],
            captureOutput: true
        ) else {
            return []
        }

        let rawHTML = res.outputString
        guard !rawHTML.isEmpty else { return [] }
        let cleanHTML = rawHTML.replacingOccurrences(of: "\\\"", with: "\"")

        var delaySec: Double = 10.0
        if let dMatch = try? NSRegularExpression(pattern: #""downloadDelaySeconds"\s*:\s*([0-9]+)"#).firstMatch(
            in: cleanHTML, range: NSRange(cleanHTML.startIndex..., in: cleanHTML)
        ), let r = Range(dMatch.range(at: 1), in: cleanHTML), let val = Double(cleanHTML[r]) {
            delaySec = min(max(val, 1.0), 15.0)
        }

        var preferredClickURLs: [(String, String)] = []
        let pattern = #""provider"\s*:\s*"([^"]+)"[\s\S]{1,600}?"clickUrl"\s*:\s*"([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let matches = regex.matches(in: cleanHTML, range: NSRange(cleanHTML.startIndex..., in: cleanHTML))
            var byProvider: [String: String] = [:]
            for m in matches {
                if let rProv = Range(m.range(at: 1), in: cleanHTML),
                   let rClick = Range(m.range(at: 2), in: cleanHTML) {
                    let prov = String(cleanHTML[rProv]).lowercased()
                    let rawClick = String(cleanHTML[rClick])
                    let fullClick = rawClick.hasPrefix("http") ? rawClick : "https://mirroruploadx.com\(rawClick)"
                    byProvider[prov] = fullClick
                }
            }
            for hostKey in ["gofile", "vikingfile"] {
                if let c = byProvider[hostKey] {
                    preferredClickURLs.append((hostKey, c))
                }
            }
        }

        guard !preferredClickURLs.isEmpty else { return [] }
        try? await Task.sleep(nanoseconds: UInt64((delaySec + 0.8) * 1_000_000_000))

        for (_, clickURL) in preferredClickURLs {
            guard let hdrRes = try? await ProcessSupervisor.shared.run(
                executable: "/usr/bin/curl",
                arguments: ["-sI", "-A", ua, "-e", urlString, clickURL],
                captureOutput: true
            ) else { continue }

            var locationURL: String? = nil
            for line in hdrRes.outputString.components(separatedBy: .newlines) {
                if line.lowercased().hasPrefix("location:") {
                    let loc = line.dropFirst("location:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !loc.isEmpty && !loc.contains("mirroruploadx.com") {
                        locationURL = loc
                        break
                    }
                }
            }

            if let targetURL = locationURL {
                let resolved = await HostResolverRegistry.resolveLinks(targetURL, passwords: passwords)
                if !resolved.isEmpty {
                    return resolved
                }
            }
        }
        return []
    }
}
