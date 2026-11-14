import ChrysaCore
import ChrysaApplication
import Foundation

package struct MailRuResolver: HostResolver {
    package let id = "mailru"
    package let bareDomains = ["cloud.mail.ru/"]

    package func canHandle(host: String, url: URL) -> Bool {
        host.contains("cloud.mail.ru")
    }
    package func matchesCDNHost(_ host: String) -> Bool {
        host.contains("mail.ru") || host.contains("cldmail.ru")
    }
    package func proxyNeeds() -> Bool { false }

    package func resolveDetailed(
        input: String,
        url: URL,
        passwords: [String],
        settings: DownloadSettings
    ) async -> HostResolutionResult {
        let items = await Self.resolveMailRu(input: input, url: url, policy: settings.proxyPolicy)
        return HostResolutionResult(downloads: items, failureReason: items.isEmpty ? "链接已失效" : nil)
    }

    package func refresh(
        item: ResolvedDownload,
        passwords: [String],
        settings: DownloadSettings
    ) async -> ResolvedDownload {
        await Self.refreshURLIfNeeded(item, policy: settings.proxyPolicy)
    }

    package static func resolveMailRu(
        input: String,
        url: URL,
        policy: ProxyPolicy = .smart
    ) async -> [ResolvedDownload] {
        let comps = url.pathComponents.filter { $0 != "/" }
        guard let pubIdx = comps.firstIndex(of: "public"), comps.count > pubIdx + 1 else {
            return []
        }
        let weblink = comps[(pubIdx + 1)...].joined(separator: "/")

        guard let dispResp = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: "https://cloud.mail.ru/api/v2/dispatcher",
            policy: policy,
            preferDirect: true,
            timeoutSeconds: 15
        ),
              let dispJSON = try? JSONSerialization.jsonObject(with: dispResp.bodyData) as? [String: Any],
              let dispBody = dispJSON["body"] as? [String: Any],
              let weblinkGet = dispBody["weblink_get"] as? [[String: Any]],
              let baseURL = weblinkGet.first?["url"] as? String else {
            return []
        }

        let encodedQuery = weblink.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? weblink
        if let fResp = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: "https://cloud.mail.ru/api/v2/folder?weblink=\(encodedQuery)",
            policy: policy,
            preferDirect: true,
            timeoutSeconds: 20
        ),
           let fJSON = try? JSONSerialization.jsonObject(with: fResp.bodyData) as? [String: Any],
           let fBody = fJSON["body"] as? [String: Any],
           let list = fBody["list"] as? [[String: Any]], !list.isEmpty {
            let folderName = (fBody["name"] as? String) ?? "mailru_folder"
            var results: [ResolvedDownload] = []
            for item in list {
                guard (item["type"] as? String) == "file",
                      let name = item["name"] as? String,
                      let itemWeblink = item["weblink"] as? String else { continue }
                let lowerName = name.lowercased()
                if lowerName.hasPrefix("#") || lowerName.hasSuffix(".md5") || lowerName.hasSuffix(".sfv") {
                    continue
                }
                let sizeVal: Int64? = {
                    if let s = item["size"] as? Int64 { return s }
                    if let n = item["size"] as? NSNumber { return n.int64Value }
                    return nil
                }()
                let encodedPath = itemWeblink
                    .components(separatedBy: "/")
                    .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
                    .joined(separator: "/")
                let directURL = "\(baseURL)/\(encodedPath)"
                results.append(
                    ResolvedDownload(
                        originalURL: input,
                        finalURL: directURL,
                        headers: [],
                        suggestedFilename: name,
                        useChunkedRange: false,
                        totalSize: sizeVal,
                        subDirectory: folderName,
                        mailRuWeblink: itemWeblink
                    )
                )
            }
            results.sort { a, b in
                let na = (a.suggestedFilename ?? "").lowercased()
                let nb = (b.suggestedFilename ?? "").lowercased()
                let aIsMainSetup = na.hasPrefix("setup_") && na.hasSuffix(".exe") && !na.contains("downpour") && !na.contains("watcher") && !na.contains("dlc")
                let bIsMainSetup = nb.hasPrefix("setup_") && nb.hasSuffix(".exe") && !nb.contains("downpour") && !nb.contains("watcher") && !nb.contains("dlc")
                if aIsMainSetup != bIsMainSetup { return aIsMainSetup }
                return na < nb
            }
            if !results.isEmpty {
                return results
            }
        }

        if let fiResp = await ResolverHTTPHelper.fetchWithPolicy(
            urlString: "https://cloud.mail.ru/api/v2/file?weblink=\(encodedQuery)",
            policy: policy,
            preferDirect: true,
            timeoutSeconds: 20
        ),
           let fiJSON = try? JSONSerialization.jsonObject(with: fiResp.bodyData) as? [String: Any],
           let fiBody = fiJSON["body"] as? [String: Any],
           let name = fiBody["name"] as? String {
            let sizeVal = (fiBody["size"] as? NSNumber)?.int64Value
            let encodedPath = weblink
                .components(separatedBy: "/")
                .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
                .joined(separator: "/")
            let directURL = "\(baseURL)/\(encodedPath)"
            return [
                ResolvedDownload(
                    originalURL: input,
                    finalURL: directURL,
                    headers: [],
                    suggestedFilename: name,
                    useChunkedRange: false,
                    totalSize: sizeVal,
                    mailRuWeblink: weblink
                )
            ]
        }

        return []
    }

    package static func refreshURLIfNeeded(
        _ item: ResolvedDownload,
        policy: ProxyPolicy = .smart
    ) async -> ResolvedDownload {
        guard let itemWeblink = item.mailRuWeblink,
              let dispResp = await ResolverHTTPHelper.fetchWithPolicy(
                urlString: "https://cloud.mail.ru/api/v2/dispatcher",
                policy: policy,
                preferDirect: true,
                timeoutSeconds: 15
              ),
              let dispJSON = try? JSONSerialization.jsonObject(with: dispResp.bodyData) as? [String: Any],
              let dispBody = dispJSON["body"] as? [String: Any],
              let weblinkGet = dispBody["weblink_get"] as? [[String: Any]],
              let baseURL = weblinkGet.first?["url"] as? String else {
            return item
        }
        let encodedPath = itemWeblink
            .components(separatedBy: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: "/")
        let freshDirectURL = "\(baseURL)/\(encodedPath)"
        return ResolvedDownload(
            originalURL: item.originalURL,
            finalURL: freshDirectURL,
            mirrorURLs: item.mirrorURLs,
            headers: item.headers,
            suggestedFilename: item.suggestedFilename,
            useChunkedRange: item.useChunkedRange,
            totalSize: item.totalSize,
            subDirectory: item.subDirectory,
            mailRuWeblink: item.mailRuWeblink,
            maxThreads: item.maxThreads,
            needsProxy: item.needsProxy,
            resolverID: item.resolverID,
            rateLimitNote: item.rateLimitNote
        )
    }
}
