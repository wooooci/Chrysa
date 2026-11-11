import Foundation

struct VikingFileResolver: HostResolver {
    func canHandle(host: String, url: URL) -> Bool {
        host.contains("vikingfile.com")
    }

    func resolve(input: String, url: URL, passwords: [String]) async -> [ResolvedDownload] {
        var dURL = input
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count >= 2 && parts[0] == "f" {
            dURL = "https://vikingfile.com/d/\(parts[1])"
        }

        guard let headRes = try? await ProcessSupervisor.shared.run(
            executable: "/usr/bin/curl",
            arguments: ["--noproxy", "*", "-sI", dURL],
            captureOutput: true
        ) else {
            return []
        }

        var cdnURL: String? = nil
        for line in headRes.outputString.components(separatedBy: .newlines) {
            if line.lowercased().hasPrefix("location:") {
                cdnURL = line.dropFirst("location:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        guard let resolvedCDN = cdnURL, !resolvedCDN.isEmpty else {
            return [ResolvedDownload(originalURL: input, finalURL: input, headers: [], suggestedFilename: url.lastPathComponent)]
        }

        let fname = URL(string: resolvedCDN)?.lastPathComponent ?? url.lastPathComponent
        var totalBytes: Int64? = nil
        if let rangeRes = try? await ProcessSupervisor.shared.run(
            executable: "/usr/bin/curl",
            arguments: ["--noproxy", "*", "-sI", "-r", "0-0", resolvedCDN],
            captureOutput: true
        ) {
            for line in rangeRes.outputString.components(separatedBy: .newlines) {
                if line.lowercased().hasPrefix("content-range:"),
                   let slashIdx = line.lastIndex(of: "/") {
                    let numStr = line[line.index(after: slashIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    totalBytes = Int64(numStr)
                }
            }
        }

        return [
            ResolvedDownload(
                originalURL: dURL,
                finalURL: resolvedCDN,
                headers: [],
                suggestedFilename: fname,
                useChunkedRange: true,
                totalSize: totalBytes
            )
        ]
    }
}

struct PixeldrainResolver: HostResolver {
    func canHandle(host: String, url: URL) -> Bool {
        let parts = url.pathComponents.filter { $0 != "/" }
        return host.contains("pixeldrain.com") && parts.count >= 2 && (parts[0] == "u" || parts[0] == "l")
    }

    func resolve(input: String, url: URL, passwords: [String]) async -> [ResolvedDownload] {
        let parts = url.pathComponents.filter { $0 != "/" }
        let id = parts[1]
        let direct = "https://pixeldrain.com/api/file/\(id)?download"
        var realName: String? = nil
        var fileSize: Int64? = nil
        if let infoURL = URL(string: "https://pixeldrain.com/api/file/\(id)/info"),
           let (infoData, _) = try? await URLSession.shared.data(from: infoURL),
           let json = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any] {
            if let n = json["name"] as? String, !n.isEmpty {
                realName = n
            }
            if let sz = json["size"] as? Int64 {
                fileSize = sz
            } else if let szNum = json["size"] as? NSNumber {
                fileSize = szNum.int64Value
            }
        }
        return [
            ResolvedDownload(
                originalURL: input,
                finalURL: direct,
                headers: [],
                suggestedFilename: realName ?? "pixeldrain_\(id).7z",
                useChunkedRange: false,
                totalSize: fileSize
            )
        ]
    }
}

struct BuzzheavierResolver: HostResolver {
    func canHandle(host: String, url: URL) -> Bool {
        host.contains("buzzheavier.com")
    }

    func resolve(input: String, url: URL, passwords: [String]) async -> [ResolvedDownload] {
        let parts = url.pathComponents.filter { $0 != "/" }
        if let id = parts.first, let reqURL = URL(string: "https://buzzheavier.com/\(id)/download") {
            var req = URLRequest(url: reqURL)
            req.httpMethod = "GET"
            req.setValue("true", forHTTPHeaderField: "HX-Request")
            req.setValue(input, forHTTPHeaderField: "Referer")
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let httpResp = resp as? HTTPURLResponse,
               let redirect = httpResp.value(forHTTPHeaderField: "hx-redirect") ?? httpResp.value(forHTTPHeaderField: "Location") {
                return [ResolvedDownload(originalURL: input, finalURL: redirect, headers: ["Referer: \(input)"], suggestedFilename: nil)]
            }
        }
        return [ResolvedDownload(originalURL: input, finalURL: input, headers: [], suggestedFilename: url.lastPathComponent)]
    }
}

struct MediaFireResolver: HostResolver {
    func canHandle(host: String, url: URL) -> Bool {
        host.contains("mediafire.com")
    }

    func resolve(input: String, url: URL, passwords: [String]) async -> [ResolvedDownload] {
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let html = String(data: data, encoding: .utf8) {
            let pattern = #"href=["'](https?://download[0-9]*\.mediafire\.com/[^"']+)["']"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let direct = String(html[range])
                return [ResolvedDownload(originalURL: input, finalURL: direct, headers: [], suggestedFilename: URL(string: direct)?.lastPathComponent)]
            }
        }
        return [ResolvedDownload(originalURL: input, finalURL: input, headers: [], suggestedFilename: url.lastPathComponent)]
    }
}

struct GoogleDriveResolver: HostResolver {
    func canHandle(host: String, url: URL) -> Bool {
        host.contains("drive.google.com")
    }

    func resolve(input: String, url: URL, passwords: [String]) async -> [ResolvedDownload] {
        let parts = url.pathComponents
        if let dIdx = parts.firstIndex(of: "d"), parts.count > dIdx + 1 {
            let id = parts[dIdx + 1]
            let direct = "https://drive.usercontent.google.com/download?id=\(id)&export=download&confirm=t"
            return [ResolvedDownload(originalURL: input, finalURL: direct, headers: [], suggestedFilename: nil)]
        }
        return [ResolvedDownload(originalURL: input, finalURL: input, headers: [], suggestedFilename: nil)]
    }
}
