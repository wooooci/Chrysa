import ChrysaCore
import Foundation

package enum ProxyRouteDecision: Sendable, Equatable {
    case direct
    case proxy(String)

    package var useProxy: Bool {
        if case .proxy = self { return true }
        return false
    }

    package var proxyAddress: String? {
        if case .proxy(let addr) = self { return addr }
        return nil
    }
}

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
    package static let defaultTimeoutSeconds: Int = 20
    package static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    /// Returns a child process environment with HTTP/HTTPS/ALL proxy variables stripped so direct connections never inherit shell proxies.
    package static func cleanedDirectEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "no_proxy", "NO_PROXY"] {
            env.removeValue(forKey: key)
        }
        return env
    }

    package static func effectiveUseProxy(
        policy: ProxyPolicy,
        defaultNeedsProxy: Bool
    ) -> Bool {
        switch policy {
        case .directOnly:
            return false
        case .systemProxy:
            return ToolchainLocator.detectSystemProxy() != nil
        case .smart:
            guard ToolchainLocator.detectSystemProxy() != nil else { return false }
            return defaultNeedsProxy
        }
    }

    package static func fetch(
        urlString: String,
        method: String = "GET",
        headers: [String: String] = [:],
        formBody: String? = nil,
        formFields: [(String, String)]? = nil,
        useProxy: Bool,
        followRedirects: Bool = true,
        rangeHeader: String? = nil,
        cookieFilePath: String? = nil,
        timeoutSeconds: Int = defaultTimeoutSeconds,
        connectTimeoutSeconds: Int = 8
    ) async -> HTTPProbeResponse? {
        var args: [String] = [
            "-sS",
            "-D", "-",
            "--connect-timeout", "\(max(2, min(connectTimeoutSeconds, timeoutSeconds)))",
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
        if let formFields {
            for (k, v) in formFields {
                args.append("-F")
                args.append("\(k)=\(v)")
            }
        } else if let formBody {
            args.append("--data")
            args.append(formBody)
        }
        args.append("-w")
        args.append("\n__CHRYSA_EFFECTIVE_URL__:%{url_effective}__CHRYSA_STATUS__:%{http_code}")
        args.append(urlString)

        guard let res = try? await ProcessSupervisor.shared.run(
            executable: "/usr/bin/curl",
            arguments: args,
            environment: useProxy ? nil : cleanedDirectEnvironment(),
            captureOutput: true
        ) else {
            return nil
        }

        return parseCurlDumpedOutput(res.outputData, fallbackURL: urlString)
    }

    /// Unified resolver HTTP entry point respecting ProxyPolicy and automatic direct-first fallback under `.smart`.
    package static func fetchWithPolicy(
        urlString: String,
        method: String = "GET",
        headers: [String: String] = [:],
        formBody: String? = nil,
        formFields: [(String, String)]? = nil,
        policy: ProxyPolicy,
        preferDirect: Bool,
        followRedirects: Bool = true,
        rangeHeader: String? = nil,
        cookieFilePath: String? = nil,
        timeoutSeconds: Int = defaultTimeoutSeconds
    ) async -> HTTPProbeResponse? {
        let hasProxy = ToolchainLocator.detectSystemProxy() != nil
        switch policy {
        case .directOnly:
            return await fetch(
                urlString: urlString,
                method: method,
                headers: headers,
                formBody: formBody,
                formFields: formFields,
                useProxy: false,
                followRedirects: followRedirects,
                rangeHeader: rangeHeader,
                cookieFilePath: cookieFilePath,
                timeoutSeconds: timeoutSeconds
            )
        case .systemProxy:
            return await fetch(
                urlString: urlString,
                method: method,
                headers: headers,
                formBody: formBody,
                formFields: formFields,
                useProxy: hasProxy,
                followRedirects: followRedirects,
                rangeHeader: rangeHeader,
                cookieFilePath: cookieFilePath,
                timeoutSeconds: timeoutSeconds
            )
        case .smart:
            if preferDirect || !hasProxy {
                let directResp = await fetch(
                    urlString: urlString,
                    method: method,
                    headers: headers,
                    formBody: formBody,
                    formFields: formFields,
                    useProxy: false,
                    followRedirects: followRedirects,
                    rangeHeader: rangeHeader,
                    cookieFilePath: cookieFilePath,
                    timeoutSeconds: timeoutSeconds,
                    connectTimeoutSeconds: 5
                )
                if let directResp, directResp.statusCode > 0 {
                    return directResp
                }
                if hasProxy {
                    return await fetch(
                        urlString: urlString,
                        method: method,
                        headers: headers,
                        formBody: formBody,
                        formFields: formFields,
                        useProxy: true,
                        followRedirects: followRedirects,
                        rangeHeader: rangeHeader,
                        cookieFilePath: cookieFilePath,
                        timeoutSeconds: timeoutSeconds
                    )
                }
                return directResp
            } else {
                let proxyResp = await fetch(
                    urlString: urlString,
                    method: method,
                    headers: headers,
                    formBody: formBody,
                    formFields: formFields,
                    useProxy: true,
                    followRedirects: followRedirects,
                    rangeHeader: rangeHeader,
                    cookieFilePath: cookieFilePath,
                    timeoutSeconds: timeoutSeconds
                )
                if let proxyResp, proxyResp.statusCode > 0 {
                    return proxyResp
                }
                return await fetch(
                    urlString: urlString,
                    method: method,
                    headers: headers,
                    formBody: formBody,
                    formFields: formFields,
                    useProxy: false,
                    followRedirects: followRedirects,
                    rangeHeader: rangeHeader,
                    cookieFilePath: cookieFilePath,
                    timeoutSeconds: timeoutSeconds,
                    connectTimeoutSeconds: 5
                )
            }
        }
    }

    /// Probes CDN connectivity prior to downloading so direct-reachable hosts never waste proxy traffic or shared IP quota.
    package static func resolveProxyRoute(
        for urlString: String,
        policy: ProxyPolicy,
        headers: [String: String] = [:],
        timeoutSeconds: Int = 5
    ) async -> (route: ProxyRouteDecision, probe: HTTPProbeResponse?, note: String) {
        let sysProxy = ToolchainLocator.detectSystemProxy()
        switch policy {
        case .directOnly:
            let probe = await probeDirectURL(urlString, headers: headers, useProxy: false, timeoutSeconds: timeoutSeconds)
            return (.direct, probe, "直连通道")
        case .systemProxy:
            if let sysProxy {
                let probe = await probeDirectURL(urlString, headers: headers, useProxy: true, timeoutSeconds: timeoutSeconds)
                return (.proxy(sysProxy), probe, "系统代理 \(sysProxy)")
            }
            let probe = await probeDirectURL(urlString, headers: headers, useProxy: false, timeoutSeconds: timeoutSeconds)
            return (.direct, probe, "直连通道")
        case .smart:
            let directProbe = await probeDirectURL(
                urlString,
                headers: headers,
                useProxy: false,
                timeoutSeconds: timeoutSeconds
            )
            if let directProbe, directProbe.statusCode > 0, directProbe.statusCode < 500 {
                return (.direct, directProbe, "直连探测畅通，走 --noproxy 直连")
            }
            if let sysProxy {
                let proxyProbe = await probeDirectURL(
                    urlString,
                    headers: headers,
                    useProxy: true,
                    timeoutSeconds: timeoutSeconds
                )
                if let proxyProbe, proxyProbe.statusCode > 0 {
                    return (.proxy(sysProxy), proxyProbe, "直连不可达，已回退系统代理 \(sysProxy)")
                }
                return (.proxy(sysProxy), directProbe, "直连超时，回退系统代理 \(sysProxy)")
            }
            return (.direct, directProbe, "直连通道")
        }
    }

    package static func cookieHeader(fromCookieFile path: String) -> String? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var pairs: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, (!trimmed.hasPrefix("#") || trimmed.hasPrefix("#HttpOnly_")) else { continue }
            let cols = trimmed.components(separatedBy: "\t")
            guard cols.count >= 7 else { continue }
            let name = cols[5].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = cols[6].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                pairs.append("\(name)=\(value)")
            }
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    package static func probeDirectURL(
        _ urlString: String,
        headers: [String: String] = [:],
        useProxy: Bool,
        timeoutSeconds: Int = 12
    ) async -> HTTPProbeResponse? {
        let connectCap = min(4, max(2, timeoutSeconds))
        if let head = await fetch(
            urlString: urlString,
            method: "HEAD",
            headers: headers,
            useProxy: useProxy,
            followRedirects: true,
            timeoutSeconds: timeoutSeconds,
            connectTimeoutSeconds: connectCap
        ), head.statusCode > 0,
           (head.statusCode >= 400 || head.contentDispositionFilename != nil || head.contentLength != nil) {
            return head
        }

        return await fetch(
            urlString: urlString,
            method: "GET",
            headers: headers,
            useProxy: useProxy,
            followRedirects: true,
            rangeHeader: "bytes=0-0",
            timeoutSeconds: timeoutSeconds,
            connectTimeoutSeconds: connectCap
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

    package static func headerDictionary(from headerLines: [String]) -> [String: String] {
        var dict: [String: String] = [:]
        for line in headerLines {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let val = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                dict[key] = val
            }
        }
        return dict
    }

    package static func validateDownloadProbe(_ probe: HTTPProbeResponse?) -> String? {
        guard let probe else { return nil }
        if probe.statusCode >= 400 {
            return classifyFailure(statusCode: probe.statusCode, contentType: probe.contentType, body: probe.bodyString)
                ?? "链接已失效"
        }
        if let ct = probe.contentType?.lowercased(),
           ct.contains("text/html"),
           probe.contentDispositionFilename == nil {
            return classifyFailure(statusCode: probe.statusCode, contentType: probe.contentType, body: probe.bodyString)
                ?? "含网页盾·请用浏览器下载"
        }
        return nil
    }
}
