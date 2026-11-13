import Foundation

package struct HTTPProbeResponse: Sendable {
    package let statusCode: Int
    package let finalURL: String
    package let headers: [String: String]
    package let bodyData: Data

    package var bodyString: String? {
        String(data: bodyData, encoding: .utf8) ?? String(data: bodyData, encoding: .isoLatin1)
    }

    package var contentType: String? {
        headers["content-type"]
    }

    package var contentDispositionFilename: String? {
        guard let cd = headers["content-disposition"] else { return nil }
        return ResolverHTTPHelper.parseContentDispositionFilename(from: cd)
    }

    package var contentLength: Int64? {
        if let cr = headers["content-range"],
           let slash = cr.lastIndex(of: "/") {
            let totalStr = cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let v = Int64(totalStr), v > 0 { return v }
        }
        if let cl = headers["content-length"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let v = Int64(cl), v > 0 {
            return v
        }
        return nil
    }
}

package enum ResolverHTTPHelper {
    package static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    package static func fetch(
        urlString: String,
        method: String = "GET",
        headers: [String: String] = [:],
        formBody: String? = nil,
        useProxy: Bool,
        followRedirects: Bool = true,
        rangeHeader: String? = nil,
        cookieFilePath: String? = nil,
        timeoutSeconds: Int = 25
    ) async -> HTTPProbeResponse? {
        var args: [String] = [
            "-sS",
            "-D", "-",
            "--max-time", "\(timeoutSeconds)",
            "-A", headers["User-Agent"] ?? browserUserAgent
        ]
        if followRedirects {
            args.append("-L")
            args.append("--max-redirs")
            args.append("8")
        }
        if useProxy, let proxy = ToolchainLocator.detectSystemProxy() {
            args.append("-x")
            args.append(proxy)
        } else if !useProxy {
            args.append("--noproxy")
            args.append("*")
        }
        if method.uppercased() == "HEAD" {
            args.append("-I")
        } else if method.uppercased() != "GET" {
            args.append("-X")
            args.append(method.uppercased())
        }
        if let rangeHeader {
            args.append("-H")
            args.append("Range: \(rangeHeader)")
        }
        if let cookieFilePath {
            args.append("-b")
            args.append(cookieFilePath)
            args.append("-c")
            args.append(cookieFilePath)
        }
        for (key, value) in headers where key.caseInsensitiveCompare("User-Agent") != .orderedSame {
            args.append("-H")
            args.append("\(key): \(value)")
        }
        if let formBody {
            args.append("--data")
            args.append(formBody)
        }
        args.append("-w")
        args.append("\n__CHRYSA_EFFECTIVE_URL__:%{url_effective}__CHRYSA_STATUS__:%{http_code}")
        args.append(urlString)

        guard let res = try? await ProcessSupervisor.shared.run(
            executable: "/usr/bin/curl",
            arguments: args,
            captureOutput: true
        ) else {
            return nil
        }

        return parseCurlDumpedOutput(res.outputData, fallbackURL: urlString)
    }

    package static func probeDirectURL(
        _ urlString: String,
        headers: [String: String] = [:],
        useProxy: Bool
    ) async -> HTTPProbeResponse? {
        if let head = await fetch(
            urlString: urlString,
            method: "HEAD",
            headers: headers,
            useProxy: useProxy,
            followRedirects: true,
            timeoutSeconds: 15
        ), head.statusCode > 0, head.statusCode < 400,
           (head.contentDispositionFilename != nil || head.contentLength != nil) {
            return head
        }

        return await fetch(
            urlString: urlString,
            method: "GET",
            headers: headers,
            useProxy: useProxy,
            followRedirects: true,
            rangeHeader: "bytes=0-0",
            timeoutSeconds: 15
        )
    }

    package static func parseCurlDumpedOutput(_ rawData: Data, fallbackURL: String) -> HTTPProbeResponse? {
        guard !rawData.isEmpty else { return nil }
        let marker = Data("\n__CHRYSA_EFFECTIVE_URL__:".utf8)
        var workingData = rawData
        var effectiveURL = fallbackURL
        var statusCode = 0

        if let markerRange = rawData.range(of: marker, options: .backwards) {
            let metaData = rawData[markerRange.upperBound...]
            workingData = rawData[..<markerRange.lowerBound]
            if let metaStr = String(data: metaData, encoding: .utf8) {
                let parts = metaStr.components(separatedBy: "__CHRYSA_STATUS__:")
                if let urlPart = parts.first {
                    let trimmed = urlPart.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { effectiveURL = trimmed }
                }
                if parts.count >= 2 {
                    statusCode = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                }
            }
        }

        // Split headers and body across redirect header blocks (each header block ends with \r\n\r\n or \n\n)
        let crlfSep = Data("\r\n\r\n".utf8)
        let lfSep = Data("\n\n".utf8)
        var bodyData = Data()
        var headerText = ""

        var cursor = workingData.startIndex
        var lastHeaders: [String: String] = [:]
        var foundHeaderBlock = false

        while cursor < workingData.endIndex {
            let slice = workingData[cursor...]
            let nextCRLF = slice.range(of: crlfSep)
            let nextLF = slice.range(of: lfSep)
            let sepRange: Range<Data.Index>?
            if let c = nextCRLF, let l = nextLF {
                sepRange = c.lowerBound < l.lowerBound ? c : l
            } else {
                sepRange = nextCRLF ?? nextLF
            }

            guard let sep = sepRange else { break }
            let blockData = workingData[cursor..<sep.lowerBound]
            guard let blockStr = String(data: blockData, encoding: .utf8) ?? String(data: blockData, encoding: .isoLatin1),
                  blockStr.uppercased().hasPrefix("HTTP/") else {
                break
            }
            foundHeaderBlock = true
            headerText = blockStr
            lastHeaders = parseHeaderBlock(blockStr)
            cursor = sep.upperBound
        }

        if foundHeaderBlock {
            bodyData = Data(workingData[cursor...])
        } else {
            bodyData = workingData
        }

        if statusCode == 0, !headerText.isEmpty {
            let firstLine = headerText.components(separatedBy: .newlines).first ?? ""
            let tokens = firstLine.split(separator: " ")
            if tokens.count >= 2, let code = Int(tokens[1]) {
                statusCode = code
            }
        }

        return HTTPProbeResponse(
            statusCode: statusCode,
            finalURL: effectiveURL,
            headers: lastHeaders,
            bodyData: bodyData
        )
    }

    private static func parseHeaderBlock(_ block: String) -> [String: String] {
        var dict: [String: String] = [:]
        for rawLine in block.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                dict[key] = val
            }
        }
        return dict
    }

    package static func parseContentDispositionFilename(from header: String) -> String? {
        // RFC 5987: filename*=UTF-8''encoded%20name.7z
        if let starRegex = try? NSRegularExpression(pattern: #"filename\*\s*=\s*(?:UTF-8''|utf-8''|[^']*''|)([^;]+)"#, options: .caseInsensitive),
           let m = starRegex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
           let r = Range(m.range(at: 1), in: header) {
            let raw = String(header[r])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\r\n"))
            if let decoded = raw.removingPercentEncoding, !decoded.isEmpty {
                return (decoded as NSString).lastPathComponent
            }
            if !raw.isEmpty { return (raw as NSString).lastPathComponent }
        }

        // Standard: filename="example.7z" or filename=example.7z
        if let stdRegex = try? NSRegularExpression(pattern: #"filename\s*=\s*"([^"]+)""#, options: .caseInsensitive),
           let m = stdRegex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
           let r = Range(m.range(at: 1), in: header) {
            let val = String(header[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !val.isEmpty { return (val as NSString).lastPathComponent }
        }

        if let bareRegex = try? NSRegularExpression(pattern: #"filename\s*=\s*([^;\s]+)"#, options: .caseInsensitive),
           let m = bareRegex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
           let r = Range(m.range(at: 1), in: header) {
            let val = String(header[r]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\r\n"))
            if !val.isEmpty { return (val as NSString).lastPathComponent }
        }
        return nil
    }

    package static func classifyFailure(statusCode: Int, contentType: String?, body: String?) -> String? {
        let lowerBody = (body ?? "").lowercased()

        // 1. Bot / Cloudflare / Captcha shields
        let shieldMarkers = [
            "cf-browser-verification",
            "just a moment...",
            "attention required! | cloudflare",
            "cf-turnstile",
            "challenges.cloudflare.com",
            "g-recaptcha",
            "h-captcha",
            "hcaptcha.com",
            "checking your browser before accessing",
            "ddos-guard",
            "enable javascript and cookies to continue"
        ]
        if shieldMarkers.contains(where: { lowerBody.contains($0) }) {
            return "含网页盾·请用浏览器下载"
        }

        // 2. Password protected
        let passwordMarkers = [
            "error-password",
            "passwordrequired",
            "password required",
            "this file is password protected",
            "enter the password",
            "wrong password"
        ]
        if statusCode == 401 || passwordMarkers.contains(where: { lowerBody.contains($0) }) {
            return "需访问密码"
        }

        // 3. Quota / rate limit
        let quotaMarkers = [
            "quota exceeded",
            "too many users have viewed or downloaded",
            "download quota",
            "download limit",
            "bandwidth limit",
            "traffic limit",
            "you must wait",
            "too many requests",
            "rate limit"
        ]
        if statusCode == 429 || quotaMarkers.contains(where: { lowerBody.contains($0) }) {
            return "今日额度已满"
        }

        // 4. Expired / deleted / not found
        let notFoundMarkers = [
            "file not found",
            "page not found",
            "error-notfound",
            "has been deleted",
            "file was deleted",
            "file has been removed",
            "no longer available",
            "does not exist",
            "404 not found"
        ]
        if statusCode == 404 || statusCode == 410 || notFoundMarkers.contains(where: { lowerBody.contains($0) }) {
            return "链接已失效"
        }

        if statusCode == 403 {
            return "链接已失效"
        }

        if let ct = contentType?.lowercased(), ct.contains("text/html"), !lowerBody.isEmpty {
            if lowerBody.contains("captcha") {
                return "含网页盾·请用浏览器下载"
            }
        }
        return nil
    }

    package static func hasKnownBinaryOrArchiveExtension(_ filename: String) -> Bool {
        let lower = (filename as NSString).lastPathComponent.lowercased()
        let exts = [
            ".7z", ".rar", ".zip", ".tar.zst", ".tar.xz", ".tar.gz", ".tgz", ".gz", ".xz", ".zst",
            ".iso", ".exe", ".bin", ".msi", ".dmg", ".pkg", ".apk", ".pak", ".vpk"
        ]
        if exts.contains(where: { lower.hasSuffix($0) }) { return true }
        if lower.range(of: #"\.[0-9]{3}$"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"\.r[0-9]{2,3}$"#, options: .regularExpression) != nil { return true }
        return false
    }

    package static func validateStagedPayload(at fileURL: URL, expectedFilename: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int64 else {
            return "文件缺失"
        }
        if size <= 0 {
            return "文件为空"
        }

        let lowerName = expectedFilename.lowercased()
        let expectsHTMLOrText = lowerName.hasSuffix(".html") || lowerName.hasSuffix(".htm")
            || lowerName.hasSuffix(".txt") || lowerName.hasSuffix(".json") || lowerName.hasSuffix(".xml")
        if expectsHTMLOrText {
            return nil
        }

        guard let fh = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? fh.close() }
        let prefixData = (try? fh.read(upToCount: 4096)) ?? Data()
        guard let text = String(data: prefixData, encoding: .utf8) ?? String(data: prefixData, encoding: .isoLatin1) else {
            return nil
        }
        let trimmed = text
            .replacingOccurrences(of: "\u{feff}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        let looksHTML = lower.hasPrefix("<!doctype html")
            || lower.hasPrefix("<html")
            || lower.hasPrefix("<head")
            || lower.hasPrefix("<body")
            || (size < 512 * 1024 && (lower.contains("<html") || lower.contains("<title>")))
        let looksJSONError = size < 32 * 1024 && (lower.hasPrefix("{\"error\"") || lower.hasPrefix("{\"status\":\"error\""))

        if looksHTML || looksJSONError {
            return classifyFailure(statusCode: 0, contentType: "text/html", body: text) ?? "含网页盾·请用浏览器下载"
        }
        return nil
    }
}
