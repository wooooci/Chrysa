import Foundation

package enum GameTitle {
    package static func cleanGameTitle(from raw: String) -> String {
        var s = raw
        if let r = try? NSRegularExpression(pattern: #"^[0-9]{4,8}_[0-9]+$"#),
           r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
            return s
        }
        if s.lowercased().hasPrefix("setup_") {
            s = String(s.dropFirst("setup_".count))
        }
        s = s.replacingOccurrences(of: "_", with: " ")
        if let bracketRegex = try? NSRegularExpression(pattern: #"\s*(\[[^\]]+\]|\([^\)]+\))"#) {
            s = bracketRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        if let regex = try? NSRegularExpression(pattern: #"\s*(v?[0-9]+\.[0-9]+.*|Build\s*[0-9]+.*|b[0-9]{6,}.*)$"#, options: .caseInsensitive) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
