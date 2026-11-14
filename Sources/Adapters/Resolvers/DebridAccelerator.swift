import ChrysaCore
import ChrysaApplication
import Foundation

package enum DebridAccelerator {
    /// Attempts to unrestrict a single-file share link using configured Real-Debrid or TorBox credentials.
    /// Multi-file folder links (e.g. gofile.io/d/, pixeldrain.com/l/, cloud.mail.ru/public/) are skipped so folder resolvers can expand all items.
    package static func tryUnrestrict(
        originalURL: String,
        url: URL,
        settings: DownloadSettings
    ) async -> ResolvedDownload? {
        let rdToken = settings.realDebridToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let tbToken = settings.torBoxToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rdToken.isEmpty || !tbToken.isEmpty else { return nil }

        let host = url.host?.lowercased() ?? ""
        let pathLower = url.path.lowercased()
        if isFolderOrDirectLink(host: host, pathLower: pathLower, url: url) {
            return nil
        }

        // If user specifically provided a Pixeldrain API Key, prefer Pixeldrain native Basic Auth directly for pixeldrain.com/u/.
        if host.contains("pixeldrain.com"),
           !settings.pixeldrainAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }

        if !rdToken.isEmpty,
           let rd = await unrestrictRealDebrid(originalURL: originalURL, token: rdToken, policy: settings.proxyPolicy) {
            return rd
        }
        if !tbToken.isEmpty,
           let tb = await unrestrictTorBox(originalURL: originalURL, token: tbToken, policy: settings.proxyPolicy) {
            return tb
        }
        return nil
    }

    private static func isFolderOrDirectLink(host: String, pathLower: String, url: URL) -> Bool {
        if host.contains("gofile.io") && pathLower.hasPrefix("/d/") { return true }
        if host.contains("pixeldrain.com") && pathLower.hasPrefix("/l/") { return true }
        if host.contains("cloud.mail.ru") && pathLower.hasPrefix("/public/") { return true }
        if host.contains("qiwi.gg") && pathLower.hasPrefix("/folder/") { return true }
        let last = url.lastPathComponent
        if !last.isEmpty && last != "/" && ResolverHTTPHelper.hasKnownBinaryOrArchiveExtension(last) {
            return true
        }
        return false
    }

    private static func unrestrictRealDebrid(
        originalURL: String,
        token: String,
        policy: ProxyPolicy
    ) async -> ResolvedDownload? {
        let encoded = formURLEncode(["link": originalURL])
        guard let resp = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: "https://api.real-debrid.com/rest/1.0/unrestrict/link",
            method: "POST",
            headers: [
                "Authorization": "Bearer \(token)",
                "Content-Type": "application/x-www-form-urlencoded"
            ],
            formBody: encoded,
            policy: policy,
            preferDirect: true,
            timeoutSeconds: 15
        ), resp.statusCode >= 200, resp.statusCode < 300 else {
            return nil
        }
        return parseRealDebridJSON(resp.bodyData, originalURL: originalURL)
    }

    package static func parseRealDebridJSON(_ data: Data, originalURL: String) -> ResolvedDownload? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let downloadURL = json["download"] as? String,
              downloadURL.lowercased().hasPrefix("http") else {
            return nil
        }
        let filename = (json["filename"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let size = (json["filesize"] as? NSNumber)?.int64Value
        let cleanName = (filename?.isEmpty == false) ? filename : URL(string: downloadURL)?.lastPathComponent
        return ResolvedDownload(
            originalURL: originalURL,
            finalURL: downloadURL,
            headers: [],
            suggestedFilename: cleanName,
            totalSize: size,
            maxThreads: 16,
            needsProxy: false,
            resolverID: "realdebrid"
        )
    }

    private static func unrestrictTorBox(
        originalURL: String,
        token: String,
        policy: ProxyPolicy
    ) async -> ResolvedDownload? {
        guard let createResp = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: "https://api.torbox.app/v1/api/webdl/createwebdownload",
            method: "POST",
            headers: ["Authorization": "Bearer \(token)"],
            formFields: [("link", originalURL)],
            policy: policy,
            preferDirect: true,
            timeoutSeconds: 15
        ), createResp.statusCode >= 200, createResp.statusCode < 300,
              let createJSON = try? JSONSerialization.jsonObject(with: createResp.bodyData) as? [String: Any],
              (createJSON["success"] as? Bool) == true,
              let dataDict = createJSON["data"] as? [String: Any],
              let webIDNum = (dataDict["webdownload_id"] as? NSNumber) ?? (dataDict["id"] as? NSNumber) else {
            return nil
        }

        let webID = webIDNum.intValue
        let encodedToken = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        let requestURL = "https://api.torbox.app/v1/api/webdl/requestdl?token=\(encodedToken)&web_id=\(webID)&redirect=false"

        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let dlResp = await ResolverHTTPHelper.fetchWithPolicy(
                urlString: requestURL,
                policy: policy,
                preferDirect: true,
                timeoutSeconds: 15
            ), dlResp.statusCode >= 200, dlResp.statusCode < 300,
                  let dlJSON = try? JSONSerialization.jsonObject(with: dlResp.bodyData) as? [String: Any],
                  (dlJSON["success"] as? Bool) == true,
                  let directURL = dlJSON["data"] as? String,
                  directURL.lowercased().hasPrefix("http") else {
                continue
            }

            let probe = await ResolverHTTPHelper.probeDirectURL(directURL, useProxy: false, timeoutSeconds: 8)
            let name = probe?.contentDispositionFilename
                ?? (dataDict["name"] as? String)
                ?? URL(string: directURL)?.lastPathComponent
            return ResolvedDownload(
                originalURL: originalURL,
                finalURL: directURL,
                headers: [],
                suggestedFilename: name,
                totalSize: probe?.contentLength,
                maxThreads: 16,
                needsProxy: false,
                resolverID: "torbox"
            )
        }
        return nil
    }

    private static func formURLEncode(_ pairs: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return pairs.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
    }
}
