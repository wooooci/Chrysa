import ChrysaCore
import ChrysaApplication
import Foundation

package struct DataNodesResolver: HostResolver {
    package let id = "datanodes"
    package let bareDomains = ["datanodes.to/", "www.datanodes.to/"]

    package func canHandle(host: String, url: URL) -> Bool {
        host.contains("datanodes.to")
    }

    package func matchesCDNHost(_ host: String) -> Bool {
        host.contains("datanodes.to")
    }

    package func proxyNeeds() -> Bool { false }
    package func maxThreads() -> Int { 8 }

    package func resolveDetailed(
        input: String,
        url: URL,
        passwords: [String],
        settings: DownloadSettings
    ) async -> HostResolutionResult {
        let cookieFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-datanodes-\(UUID().uuidString).cookies").path
        defer { try? FileManager.default.removeItem(atPath: cookieFile) }

        guard let landingResp = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: input,
            policy: settings.proxyPolicy,
            preferDirect: true,
            cookieFilePath: cookieFile,
            timeoutSeconds: 20
        ) else {
            return HostResolutionResult(downloads: [], failureReason: "无法连接 DataNodes")
        }

        if landingResp.statusCode >= 400 {
            let reason = ResolverHTTPHelper.classifyFailure(
                statusCode: landingResp.statusCode,
                contentType: landingResp.contentType,
                body: landingResp.bodyString
            ) ?? "链接已失效"
            return HostResolutionResult(downloads: [], failureReason: reason)
        }

        let landingHTML = landingResp.bodyString ?? ""
        if let failure = ResolverHTTPHelper.classifyFailure(
            statusCode: landingResp.statusCode,
            contentType: landingResp.contentType,
            body: landingHTML
        ) {
            return HostResolutionResult(downloads: [], failureReason: failure)
        }

        let pageFilename = Self.extractFilename(from: landingHTML)
            ?? DownloadInputParser.inferFilenameFromURL(input)

        var directURL: String? = Self.extractDirectLink(from: landingHTML)
        var actionReferer = input

        if directURL == nil, let form = Self.parseDownloadForm(html: landingHTML, baseURL: input, url: url) {
            actionReferer = form.actionURL
            let postResp = await ResolverHTTPHelper.fetchWithPolicy(
                urlString: form.actionURL,
                method: "POST",
                headers: [
                    "Referer": input,
                    "Origin": "https://\(url.host ?? "datanodes.to")",
                    "Content-Type": "application/x-www-form-urlencoded"
                ],
                formBody: form.formBody,
                policy: settings.proxyPolicy,
                preferDirect: true,
                followRedirects: false,
                cookieFilePath: cookieFile,
                timeoutSeconds: 20
            )
            if let postResp {
                if let loc = postResp.headers["location"], loc.lowercased().hasPrefix("http") {
                    directURL = loc
                } else if let body = postResp.bodyString {
                    if let failure = ResolverHTTPHelper.classifyFailure(
                        statusCode: postResp.statusCode,
                        contentType: postResp.contentType,
                        body: body
                    ) {
                        return HostResolutionResult(downloads: [], failureReason: failure)
                    }
                    directURL = Self.extractDirectLink(fromJSONOrHTML: body)
                }
            }
        }

        guard let resolvedDirect = directURL, !resolvedDirect.isEmpty else {
            return HostResolutionResult(downloads: [], failureReason: "无法提取 DataNodes 直链")
        }

        var extraHeaders: [String] = ["Referer: \(actionReferer)"]
        if let cookieHdr = ResolverHTTPHelper.cookieHeader(fromCookieFile: cookieFile) {
            extraHeaders.append("Cookie: \(cookieHdr)")
        }

        let useProxyProbe = ResolverHTTPHelper.effectiveUseProxy(policy: settings.proxyPolicy, defaultNeedsProxy: false)
        let probeHeaderDict = ResolverHTTPHelper.headerDictionary(from: extraHeaders)
        let probe = await ResolverHTTPHelper.probeDirectURL(resolvedDirect, headers: probeHeaderDict, useProxy: useProxyProbe)
        if let failure = ResolverHTTPHelper.validateDownloadProbe(probe) {
            return HostResolutionResult(downloads: [], failureReason: failure)
        }

        let resolvedName = probe?.contentDispositionFilename
            ?? pageFilename
            ?? URL(string: resolvedDirect)?.lastPathComponent
        return HostResolutionResult(downloads: [
            ResolvedDownload(
                originalURL: input,
                finalURL: probe?.finalURL ?? resolvedDirect,
                headers: extraHeaders,
                suggestedFilename: resolvedName,
                totalSize: probe?.contentLength,
                maxThreads: maxThreads(),
                needsProxy: false,
                resolverID: id
            )
        ])
    }

    package static func extractFilename(from html: String) -> String? {
        let patterns = [
            #"<title>\s*Download\s+([^<\r\n]+?)\s*(?:\||-|</title>)"#,
            #"<h[12][^>]*>\s*([^<]+?)\s*</h[12]>"#,
            #"name=["']fname["'][^>]*value=["']([^"']+)["']"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            let candidate = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty, candidate.contains("."), !candidate.lowercased().contains("datanodes") {
                return candidate
            }
        }
        return nil
    }

    package static func parseDownloadForm(
        html: String,
        baseURL: String,
        url: URL
    ) -> (actionURL: String, formBody: String)? {
        let parts = url.pathComponents.filter { $0 != "/" }
        let fallbackID = parts.first(where: { $0.lowercased() != "download" }) ?? ""

        let formPattern = #"<form\b([^>]*)>([\s\S]*?)</form>"#
        guard let formRegex = try? NSRegularExpression(pattern: formPattern, options: .caseInsensitive) else {
            return nil
        }
        let matches = formRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var chosenAction: String? = nil
        var chosenFields: [(String, String)] = []

        for m in matches where m.numberOfRanges >= 3 {
            guard let ar = Range(m.range(at: 1), in: html),
                  let br = Range(m.range(at: 2), in: html) else { continue }
            let attrs = String(html[ar])
            let body = String(html[br])
            guard body.contains("op") || body.contains("method_free") || body.contains("download") else { continue }
            chosenAction = extractAttr("action", from: attrs)
            if let inputRegex = try? NSRegularExpression(pattern: #"<input\b[^>]*>"#, options: .caseInsensitive) {
                let ims = inputRegex.matches(in: body, range: NSRange(body.startIndex..., in: body))
                for im in ims {
                    guard let ir = Range(im.range, in: body) else { continue }
                    let tag = String(body[ir])
                    if let name = extractAttr("name", from: tag), !name.isEmpty {
                        let val = extractAttr("value", from: tag) ?? ""
                        if !chosenFields.contains(where: { $0.0 == name }) {
                            chosenFields.append((name, val))
                        }
                    }
                }
            }
            if chosenFields.contains(where: { $0.0 == "op" }) {
                break
            }
        }

        if chosenFields.isEmpty && fallbackID.isEmpty {
            return nil
        }

        if !chosenFields.contains(where: { $0.0 == "op" }) {
            chosenFields.append(("op", "download2"))
        }
        if !chosenFields.contains(where: { $0.0 == "id" }) && !fallbackID.isEmpty {
            chosenFields.append(("id", fallbackID))
        }
        if !chosenFields.contains(where: { $0.0 == "rand" }) {
            chosenFields.append(("rand", ""))
        }
        if !chosenFields.contains(where: { $0.0 == "referer" }) {
            chosenFields.append(("referer", baseURL))
        }
        if !chosenFields.contains(where: { $0.0 == "method_free" }) {
            chosenFields.append(("method_free", "Free Download >>"))
        }
        if !chosenFields.contains(where: { $0.0 == "method_premium" }) {
            chosenFields.append(("method_premium", ""))
        }

        let actionURL: String
        if let rawAct = chosenAction?.trimmingCharacters(in: .whitespacesAndNewlines), !rawAct.isEmpty {
            if rawAct.hasPrefix("http://") || rawAct.hasPrefix("https://") {
                actionURL = rawAct
            } else if rawAct.hasPrefix("/"), let host = url.host {
                actionURL = "https://\(host)\(rawAct)"
            } else {
                actionURL = baseURL
            }
        } else {
            actionURL = baseURL
        }

        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        let encoded = chosenFields.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")

        return (actionURL, encoded)
    }

    package static func extractDirectLink(fromJSONOrHTML text: String) -> String? {
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = (json["url"] as? String) ?? (json["link"] as? String) ?? (json["download"] as? String),
           raw.lowercased().hasPrefix("http") {
            return raw.removingPercentEncoding?.contains(" ") == true ? raw : raw
        }
        return extractDirectLink(from: text)
    }

    package static func extractDirectLink(from html: String) -> String? {
        let patterns = [
            #"<a[^>]*\bid=["'](?:downloadbtn|dl-btn|direct_link)["'][^>]*\bhref=["'](https?://[^"']+)["']"#,
            #"<span[^>]*\bid=["']direct_link["'][^>]*>\s*<a[^>]*\bhref=["'](https?://[^"']+)["']"#,
            #"href=["'](https?://[^"']*datanodes[^"']*/d/[^"']+)["']"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            let candidate = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                return candidate
            }
        }
        return nil
    }

    private static func extractAttr(_ attr: String, from tag: String) -> String? {
        let pattern = "\\b\(attr)\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let r = Range(m.range(at: 1), in: tag) else { return nil }
        return String(tag[r])
    }
}
