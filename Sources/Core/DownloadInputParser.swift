import Foundation

package struct ParsedDownloadInput: Equatable, Sendable {
    package let urls: [String]
    package let extractedPasswords: [String]
    package let mirrorGroups: [String: [String]]

    package init(urls: [String], extractedPasswords: [String], mirrorGroups: [String: [String]] = [:]) {
        self.urls = urls
        self.extractedPasswords = extractedPasswords
        self.mirrorGroups = mirrorGroups
    }

    package var primaryPassword: String? {
        extractedPasswords.first
    }
}

package struct MultipartGroupItem: Equatable, Sendable {
    package let url: String
    package let filename: String?
    package let subDirectory: String?
    package let mirrorURLs: [String]

    package init(url: String, filename: String?, subDirectory: String? = nil, mirrorURLs: [String] = []) {
        self.url = url
        self.filename = filename
        self.subDirectory = subDirectory
        self.mirrorURLs = mirrorURLs
    }
}

package struct MultipartGroup: Equatable, Sendable {
    package let title: String
    package let items: [MultipartGroupItem]
    package let isMultipartSet: Bool

    package init(title: String, items: [MultipartGroupItem], isMultipartSet: Bool) {
        self.title = title
        self.items = items
        self.isMultipartSet = isMultipartSet
    }
}

package enum DownloadInputParser {
    package static let defaultKnownBareDomains: [String] = [
        "gofile.io/", "www.gofile.io/",
        "pixeldrain.com/", "www.pixeldrain.com/",
        "buzzheavier.com/", "www.buzzheavier.com/",
        "bzzhr.co/", "www.bzzhr.co/",
        "vikingfile.com/", "www.vikingfile.com/",
        "itsfileditchfiles.st/", "fileditchfiles.st/", "fileditch.com/",
        "mirroruploadx.com/", "www.mirroruploadx.com/",
        "cloud.mail.ru/",
        "mediafire.com/", "www.mediafire.com/",
        "drive.google.com/",
        "fuckingfast.co/", "www.fuckingfast.co/",
        "1fichier.com/", "www.1fichier.com/",
        "datanodes.to/", "www.datanodes.to/",
        "qiwi.gg/", "www.qiwi.gg/",
        "workupload.com/", "www.workupload.com/",
        "krakenfiles.com/", "www.krakenfiles.com/"
    ]

    package static func normalizeSingleURL(
        _ raw: String,
        knownBareDomains: [String] = defaultKnownBareDomains
    ) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("magnet:") || isTorrentURL(lower) {
            return nil
        }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return trimmed
        }
        if knownBareDomains.contains(where: { lower.hasPrefix($0.lowercased()) }) {
            return "https://" + trimmed
        }
        if !trimmed.contains(" "),
           !trimmed.contains("\n"),
           let slashIdx = trimmed.firstIndex(of: "/"),
           trimmed[..<slashIdx].contains(".") {
            let candidateHost = String(trimmed[..<slashIdx]).lowercased()
            if candidateHost != "mega.nz", !candidateHost.hasSuffix(".mega.nz") {
                return "https://" + trimmed
            }
        }
        return nil
    }

    package static func parse(
        _ rawText: String,
        knownBareDomains: [String] = defaultKnownBareDomains
    ) -> ParsedDownloadInput {
        let normalizedNewlines = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var passwords: [String] = []
        var seenPasswords: Set<String> = []
        let lines = normalizedNewlines.components(separatedBy: "\n")

        for line in lines {
            for pw in extractPasswords(fromLine: line) where !pw.isEmpty && !seenPasswords.contains(pw) {
                seenPasswords.insert(pw)
                passwords.append(pw)
            }
        }

        var urls: [String] = []
        var seenURLs: Set<String> = []
        var mirrorGroups: [String: [String]] = [:]

        func extractURLsFromTokens(_ tokens: [String], singleTokenContext: Bool) -> [String] {
            var found: [String] = []
            let httpRegex = try? NSRegularExpression(pattern: #"https?://[^\s<>"'\[\]()|｜]+"#, options: .caseInsensitive)
            for token in tokens {
                let trimmed = trimURLDelimiters(token)
                guard !trimmed.isEmpty else { continue }
                let lower = trimmed.lowercased()
                if lower.hasPrefix("magnet:") || isTorrentURL(lower) {
                    continue
                }
                if let httpRegex {
                    let ns = token as NSString
                    let matches = httpRegex.matches(in: token, range: NSRange(location: 0, length: ns.length))
                    if !matches.isEmpty {
                        for m in matches {
                            let cleaned = trimURLDelimiters(ns.substring(with: m.range))
                            let cleanedLower = cleaned.lowercased()
                            if !cleaned.isEmpty,
                               !cleanedLower.hasPrefix("magnet:"),
                               !isTorrentURL(cleanedLower),
                               URL(string: cleaned)?.host != nil {
                                found.append(cleaned)
                            }
                        }
                        continue
                    }
                }
                if knownBareDomains.contains(where: { lower.hasPrefix($0.lowercased()) }) {
                    let candidate = "https://" + trimmed
                    if URL(string: candidate)?.host != nil { found.append(candidate) }
                } else if singleTokenContext, let single = normalizeSingleURL(trimmed, knownBareDomains: knownBareDomains) {
                    if URL(string: single)?.host != nil { found.append(single) }
                }
            }
            return found
        }

        let totalTokens = normalizedNewlines.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }

            // Pipe-separated URLs on a single line represent primary | mirror1 | mirror2
            let normalizedPipes = trimmedLine.replacingOccurrences(of: "｜", with: "|")
            if normalizedPipes.contains("|") {
                let pipeSegments = normalizedPipes.components(separatedBy: "|")
                var groupURLs: [String] = []
                for seg in pipeSegments {
                    let segTokens = seg.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                    groupURLs.append(contentsOf: extractURLsFromTokens(segTokens, singleTokenContext: segTokens.count == 1))
                }
                if let primary = groupURLs.first {
                    if !seenURLs.contains(primary) {
                        seenURLs.insert(primary)
                        urls.append(primary)
                    }
                    let mirrors = groupURLs.dropFirst().filter { $0 != primary }
                    if !mirrors.isEmpty {
                        var existing = mirrorGroups[primary] ?? []
                        for m in mirrors where !existing.contains(m) {
                            existing.append(m)
                            seenURLs.insert(m)
                        }
                        mirrorGroups[primary] = existing
                    }
                    continue
                }
            }

            let lineTokens = trimmedLine.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            for u in extractURLsFromTokens(lineTokens, singleTokenContext: totalTokens.count == 1) {
                if !seenURLs.contains(u) {
                    seenURLs.insert(u)
                    urls.append(u)
                }
            }
        }

        return ParsedDownloadInput(urls: urls, extractedPasswords: passwords, mirrorGroups: mirrorGroups)
    }

    private static func trimURLDelimiters(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = CharacterSet(charactersIn: "<([{\"'`“‘")
        let trailing = CharacterSet(charactersIn: ">)]}\"'`”’.,;!?")
        while let first = s.unicodeScalars.first, leading.contains(first) {
            s.removeFirst()
        }
        while let last = s.unicodeScalars.last, trailing.contains(last) {
            s.removeLast()
        }
        return s
    }

    private static func isTorrentURL(_ lower: String) -> Bool {
        if let u = URL(string: lower), u.path.lowercased().hasSuffix(".torrent") {
            return true
        }
        return lower.hasSuffix(".torrent")
    }

    private static func extractPasswords(fromLine line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let patterns = [
            #"(?i)(?:解压密码|提取密码|访问密码|密码|password|passwd|pass|pw)\s*[:：=]\s*([^\s"'<>]+)"#,
            #"(?i)(?:解压密码|密码|password|pass|pw)\s+([^\s"'<>:：=]{2,})"#
        ]
        var found: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = trimmed as NSString
            let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
            for m in matches where m.numberOfRanges >= 2 {
                let rawVal = ns.substring(with: m.range(at: 1))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>()[]{}.,;"))
                let lowerVal = rawVal.lowercased()
                if !rawVal.isEmpty,
                   !lowerVal.hasPrefix("http://"),
                   !lowerVal.hasPrefix("https://") {
                    found.append(rawVal)
                }
            }
        }
        return found
    }

    // MARK: - Multipart Set Detection & Grouping

    package enum MultipartRole: Equatable, Sendable {
        case single(stem: String)
        case rarPart(stem: String, partIndex: Int)
        case split7z(stem: String, partIndex: Int)
        case splitGeneric(stem: String, partIndex: Int)
        case rarLegacy(stem: String, partIndex: Int)
        case gogSetup(stem: String, isDLC: Bool, binIndex: Int?)

        package var groupKey: String? {
            switch self {
            case .single:
                return nil
            case .rarPart(let stem, _):
                return "rar:\(stem.lowercased())"
            case .split7z(let stem, _):
                return "7z:\(stem.lowercased())"
            case .splitGeneric(let stem, _):
                return "split:\(stem.lowercased())"
            case .rarLegacy(let stem, _):
                return "rarlegacy:\(stem.lowercased())"
            case .gogSetup(let stem, _, _):
                return "gog:\(stem.lowercased())"
            }
        }

        package var displayStem: String {
            switch self {
            case .single(let stem),
                 .rarPart(let stem, _),
                 .split7z(let stem, _),
                 .splitGeneric(let stem, _),
                 .rarLegacy(let stem, _),
                 .gogSetup(let stem, _, _):
                return stem
            }
        }
    }

    package static func inferFilenameFromURL(_ urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        if let frag = url.fragment?.removingPercentEncoding,
           !frag.isEmpty,
           frag.contains(".") {
            return (frag as NSString).lastPathComponent
        }
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/", last.contains(".") {
            return last
        }
        return nil
    }

    package static func classifyFilename(_ filename: String) -> MultipartRole {
        let base = (filename as NSString).lastPathComponent
        let lower = base.lowercased()
        let range = NSRange(base.startIndex..., in: base)

        // 1. .part01.rar / .part1.rar
        if let regex = try? NSRegularExpression(pattern: #"^(.+?)\.part0*([0-9]+)\.rar$"#, options: .caseInsensitive),
           let m = regex.firstMatch(in: base, range: range),
           let stemRange = Range(m.range(at: 1), in: base),
           let numRange = Range(m.range(at: 2), in: base),
           let partIdx = Int(base[numRange]) {
            return .rarPart(stem: String(base[stemRange]), partIndex: partIdx)
        }

        // 2. .7z.001 / .zip.001 / .rar.001
        if let regex = try? NSRegularExpression(pattern: #"^(.+?)\.(?:7z|zip|rar)\.([0-9]{3})$"#, options: .caseInsensitive),
           let m = regex.firstMatch(in: base, range: range),
           let stemRange = Range(m.range(at: 1), in: base),
           let numRange = Range(m.range(at: 2), in: base),
           let partIdx = Int(base[numRange]) {
            return .split7z(stem: String(base[stemRange]), partIndex: partIdx)
        }

        // 3. Generic .001, .002
        if let regex = try? NSRegularExpression(pattern: #"^(.+?)\.([0-9]{3})$"#, options: .caseInsensitive),
           let m = regex.firstMatch(in: base, range: range),
           let stemRange = Range(m.range(at: 1), in: base),
           let numRange = Range(m.range(at: 2), in: base),
           let partIdx = Int(base[numRange]) {
            return .splitGeneric(stem: String(base[stemRange]), partIndex: partIdx)
        }

        // 4. Legacy .r00 / .r01
        if let regex = try? NSRegularExpression(pattern: #"^(.+?)\.r([0-9]{2,3})$"#, options: .caseInsensitive),
           let m = regex.firstMatch(in: base, range: range),
           let stemRange = Range(m.range(at: 1), in: base),
           let numRange = Range(m.range(at: 2), in: base),
           let partIdx = Int(base[numRange]) {
            return .rarLegacy(stem: String(base[stemRange]), partIndex: partIdx + 1)
        }

        // 5. GOG Inno Setup: setup_<stem>.exe, setup_<stem>-1.bin, setup_<stem>_dlc...exe
        if lower.hasPrefix("setup_") {
            if let binRegex = try? NSRegularExpression(pattern: #"^setup_(.+?)-([0-9]+)\.bin$"#, options: .caseInsensitive),
               let m = binRegex.firstMatch(in: base, range: range),
               let stemRange = Range(m.range(at: 1), in: base),
               let numRange = Range(m.range(at: 2), in: base),
               let binIdx = Int(base[numRange]) {
                return .gogSetup(stem: String(base[stemRange]), isDLC: false, binIndex: binIdx)
            }
            if lower.hasSuffix(".exe") {
                let rawStem = String(base.dropFirst("setup_".count).dropLast(".exe".count))
                let isDLC = lower.contains("dlc")
                return .gogSetup(stem: rawStem, isDLC: isDLC, binIndex: nil)
            }
        }

        let stem = (base as NSString).deletingPathExtension
        return .single(stem: stem.isEmpty ? base : stem)
    }

    package static func cleanDisplayTitle(fromRawName raw: String) -> String {
        let role = classifyFilename(raw)
        let stem = role.displayStem
        let cleaned = GameTitle.cleanGameTitle(from: stem)
        if !cleaned.isEmpty {
            return cleaned
        }
        return stem.isEmpty ? raw : stem
    }

    package static func groupMultipartItems(_ items: [MultipartGroupItem]) -> [MultipartGroup] {
        guard !items.isEmpty else { return [] }
        if items.count == 1 {
            let item = items[0]
            let rawName = item.subDirectory ?? item.filename ?? inferFilenameFromURL(item.url) ?? "Download"
            return [MultipartGroup(title: cleanDisplayTitle(fromRawName: rawName), items: [item], isMultipartSet: false)]
        }

        var buckets: [String: [MultipartGroupItem]] = [:]
        var bucketOrder: [String] = []
        var gogStems: Set<String> = []

        for item in items {
            let name = item.filename ?? inferFilenameFromURL(item.url) ?? ""
            if case .gogSetup(let stem, let isDLC, _) = classifyFilename(name), !isDLC {
                gogStems.insert(stem.lowercased())
            }
        }

        for (index, item) in items.enumerated() {
            let name = item.filename ?? inferFilenameFromURL(item.url) ?? ""
            let role = classifyFilename(name)
            var key: String
            switch role {
            case .gogSetup(let stem, let isDLC, _):
                if isDLC, let matchedMain = gogStems.first(where: { stem.lowercased().hasPrefix($0) }) {
                    key = "gog:\(matchedMain)"
                } else {
                    key = "gog:\(stem.lowercased())"
                }
            default:
                if let groupKey = role.groupKey {
                    key = groupKey
                } else if let sub = item.subDirectory, !sub.isEmpty {
                    key = "dir:\(sub.lowercased())"
                } else {
                    key = "single:\(index):\(item.url)"
                }
            }

            if buckets[key] == nil {
                bucketOrder.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(item)
        }

        return bucketOrder.compactMap { key in
            guard let groupItems = buckets[key], !groupItems.isEmpty else { return nil }
            let isSet = groupItems.count > 1 && !key.hasPrefix("single:")
            let first = groupItems[0]
            let titleSource = first.subDirectory
                ?? first.filename
                ?? inferFilenameFromURL(first.url)
                ?? "Download"
            return MultipartGroup(
                title: cleanDisplayTitle(fromRawName: titleSource),
                items: groupItems,
                isMultipartSet: isSet
            )
        }
    }
}
