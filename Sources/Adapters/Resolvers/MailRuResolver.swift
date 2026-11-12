import ChrysaCore
import ChrysaApplication
import Foundation

package struct MailRuResolver: HostResolver {
    package func canHandle(host: String, url: URL) -> Bool {
        host.contains("cloud.mail.ru")
    }
    package func proxyNeeds() -> Bool { false }

    package func resolve(input: String, url: URL, passwords: [String]) async -> [ResolvedDownload] {
        await Self.resolveMailRu(input: input, url: url)
    }

    package static func resolveMailRu(input: String, url: URL) async -> [ResolvedDownload] {
        let comps = url.pathComponents.filter { $0 != "/" }
        guard let pubIdx = comps.firstIndex(of: "public"), comps.count > pubIdx + 1 else {
            return []
        }
        let weblink = comps[(pubIdx + 1)...].joined(separator: "/")

        guard let dispURL = URL(string: "https://cloud.mail.ru/api/v2/dispatcher"),
              let (dispData, _) = try? await URLSession.shared.data(from: dispURL),
              let dispJSON = try? JSONSerialization.jsonObject(with: dispData) as? [String: Any],
              let dispBody = dispJSON["body"] as? [String: Any],
              let weblinkGet = dispBody["weblink_get"] as? [[String: Any]],
              let baseURL = weblinkGet.first?["url"] as? String else {
            return []
        }

        let encodedQuery = weblink.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? weblink
        if let folderURL = URL(string: "https://cloud.mail.ru/api/v2/folder?weblink=\(encodedQuery)"),
           let (fData, _) = try? await URLSession.shared.data(from: folderURL),
           let fJSON = try? JSONSerialization.jsonObject(with: fData) as? [String: Any],
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

        if let fileURL = URL(string: "https://cloud.mail.ru/api/v2/file?weblink=\(encodedQuery)"),
           let (fiData, _) = try? await URLSession.shared.data(from: fileURL),
           let fiJSON = try? JSONSerialization.jsonObject(with: fiData) as? [String: Any],
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

    package static func refreshURLIfNeeded(_ item: ResolvedDownload) async -> ResolvedDownload {
        guard let itemWeblink = item.mailRuWeblink,
              let dispURL = URL(string: "https://cloud.mail.ru/api/v2/dispatcher"),
              let (dispData, _) = try? await URLSession.shared.data(from: dispURL),
              let dispJSON = try? JSONSerialization.jsonObject(with: dispData) as? [String: Any],
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
            headers: item.headers,
            suggestedFilename: item.suggestedFilename,
            useChunkedRange: item.useChunkedRange,
            totalSize: item.totalSize,
            subDirectory: item.subDirectory,
            mailRuWeblink: item.mailRuWeblink
        )
    }
}
