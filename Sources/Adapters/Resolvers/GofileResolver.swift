import ChrysaCore
import ChrysaApplication
import Foundation
import JavaScriptCore
import CryptoKit

package struct GofileResolver: HostResolver {
    package let id = "gofile"
    package let bareDomains = ["gofile.io/", "www.gofile.io/"]

    package func canHandle(host: String, url: URL) -> Bool {
        let parts = url.pathComponents.filter { $0 != "/" }
        return host.contains("gofile.io") && parts.count >= 2 && parts[0] == "d"
    }

    package func matchesCDNHost(_ host: String) -> Bool {
        host.contains("gofile.io")
    }

    package func resolveDetailed(input: String, url: URL, passwords: [String]) async -> HostResolutionResult {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 && parts[0] == "d" else {
            return HostResolutionResult(downloads: [], failureReason: "链接格式无效")
        }
        return await Self.resolveGofileDetailed(contentId: parts[1], passwords: passwords)
    }

    package func proxyNeeds() -> Bool { true }
    package func maxThreads() -> Int { 16 }
    private static func sha256HexString(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func mintGuestToken(ua: String) async -> String? {
        guard let accURL = URL(string: "https://api.gofile.io/accounts") else { return nil }
        var accReq = URLRequest(url: accURL)
        accReq.httpMethod = "POST"
        accReq.setValue(ua, forHTTPHeaderField: "User-Agent")
        guard let (accData, _) = try? await URLSession.shared.data(for: accReq),
              let accJson = try? JSONSerialization.jsonObject(with: accData) as? [String: Any],
              let dataDict = accJson["data"] as? [String: Any],
              let token = dataDict["token"] as? String, !token.isEmpty else {
            return nil
        }
        UserDefaults.standard.set(token, forKey: "sf_gofile_guest_token")
        return token
    }

    private static func generateWT(token: String, ua: String, lang: String) async -> String {
        let now = Date().timeIntervalSince1970
        var wtScript = UserDefaults.standard.string(forKey: "sf_gofile_wt_script")
        let savedTS = UserDefaults.standard.double(forKey: "sf_gofile_wt_ts")
        if wtScript == nil || (now - savedTS) > 7200 {
            if let wtURL = URL(string: "https://gofile.io/js/wt.obf.js") {
                var req = URLRequest(url: wtURL)
                req.setValue(ua, forHTTPHeaderField: "User-Agent")
                if let (data, _) = try? await URLSession.shared.data(for: req),
                   let text = String(data: data, encoding: .utf8),
                   text.contains("generateWT") {
                    wtScript = text
                    UserDefaults.standard.set(text, forKey: "sf_gofile_wt_script")
                    UserDefaults.standard.set(now, forKey: "sf_gofile_wt_ts")
                }
            }
        }
        if let script = wtScript, let ctx = JSContext() {
            ctx.evaluateScript("var window = globalThis; var navigator = { userAgent: \"\(ua)\", language: \"\(lang)\" };")
            ctx.evaluateScript(script)
            if let fn = ctx.objectForKeyedSubscript("generateWT"),
               let val = fn.call(withArguments: [token])?.toString(),
               !val.isEmpty, val != "undefined" {
                return val
            }
        }
        let bucket = Int(now) / 14400
        return sha256HexString("\(ua)::\(lang)::\(token)::\(bucket)::12af056dacea0b")
    }

    private static func fetchContentsJSON(
        contentId: String,
        token: String,
        wt: String,
        ua: String,
        lang: String,
        passwordHash: String? = nil
    ) async -> (Int, [String: Any]?) {
        var urlStr = "https://api.gofile.io/contents/\(contentId)?page=1&pageSize=100&sortField=name&sortDirection=1"
        if let pw = passwordHash, !pw.isEmpty {
            urlStr += "&password=\(pw)"
        }
        guard let contentURL = URL(string: urlStr) else { return (0, nil) }
        var cReq = URLRequest(url: contentURL)
        cReq.setValue(ua, forHTTPHeaderField: "User-Agent")
        cReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        cReq.setValue(wt, forHTTPHeaderField: "X-Website-Token")
        cReq.setValue(lang, forHTTPHeaderField: "X-BL")
        guard let (cData, resp) = try? await URLSession.shared.data(for: cReq) else {
            return (0, nil)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
        let json = try? JSONSerialization.jsonObject(with: cData) as? [String: Any]
        return (code, json)
    }

    package static func resolveGofileList(contentId: String, passwords: [String], depth: Int = 0) async -> [ResolvedDownload] {
        await resolveGofileDetailed(contentId: contentId, passwords: passwords, depth: depth).downloads
    }

    package static func resolveGofileDetailed(contentId: String, passwords: [String], depth: Int = 0) async -> HostResolutionResult {
        guard depth <= 2 else { return HostResolutionResult(downloads: [], failureReason: "目录层级过深") }
        let ua = ResolverHTTPHelper.browserUserAgent
        let lang = "en-US"

        var token = UserDefaults.standard.string(forKey: "sf_gofile_guest_token") ?? "qmMkk3QlGAVUbei1YkhSfPaCAUqLKgsm"
        var wt = await generateWT(token: token, ua: ua, lang: lang)

        var (httpCode, cJson) = await fetchContentsJSON(contentId: contentId, token: token, wt: wt, ua: ua, lang: lang)
        let apiStatus = cJson?["status"] as? String
        if httpCode == 401 || httpCode == 403 || apiStatus == "error-wrongToken" || apiStatus == "error-token" {
            if let freshToken = await mintGuestToken(ua: ua) {
                token = freshToken
                wt = await generateWT(token: token, ua: ua, lang: lang)
                (httpCode, cJson) = await fetchContentsJSON(contentId: contentId, token: token, wt: wt, ua: ua, lang: lang)
            }
        }

        let finalAPIStatus = (cJson?["status"] as? String)?.lowercased() ?? ""
        if finalAPIStatus.contains("notfound") || httpCode == 404 {
            return HostResolutionResult(downloads: [], failureReason: "链接已失效")
        }
        if finalAPIStatus.contains("overlimit") || httpCode == 429 {
            return HostResolutionResult(downloads: [], failureReason: "今日额度已满")
        }

        guard var cRoot = cJson?["data"] as? [String: Any] else {
            return HostResolutionResult(downloads: [], failureReason: "链接已失效")
        }

        // Automatically unlock password-protected Gofile shares using user's live password dictionary
        if (cRoot["canAccess"] as? Bool) == false || (cRoot["passwordStatus"] as? String) == "passwordRequired" {
            var unlocked = false
            for candidate in passwords where !candidate.isEmpty {
                let pwHash = sha256HexString(candidate)
                let (_, pwJson) = await fetchContentsJSON(contentId: contentId, token: token, wt: wt, ua: ua, lang: lang, passwordHash: pwHash)
                if let unlockedRoot = pwJson?["data"] as? [String: Any],
                   (unlockedRoot["canAccess"] as? Bool) == true,
                   (unlockedRoot["children"] != nil || (unlockedRoot["type"] as? String) == "file") {
                    cRoot = unlockedRoot
                    unlocked = true
                    break
                }
            }
            if !unlocked {
                return HostResolutionResult(downloads: [], failureReason: "需访问密码")
            }
        }

        if (cRoot["type"] as? String) == "file", let directLink = cRoot["link"] as? String {
            let name = cRoot["name"] as? String
            let sz = (cRoot["size"] as? NSNumber)?.int64Value
            return HostResolutionResult(downloads: [
                ResolvedDownload(
                    originalURL: "https://gofile.io/d/\(contentId)",
                    finalURL: directLink,
                    headers: ["Cookie: accountToken=\(token)"],
                    suggestedFilename: name,
                    useChunkedRange: false,
                    totalSize: sz,
                    subDirectory: nil,
                    maxThreads: 16,
                    needsProxy: true,
                    resolverID: "gofile"
                )
            ])
        }

        guard let children = cRoot["children"] as? [String: Any] else {
            return HostResolutionResult(downloads: [], failureReason: "分享内容为空")
        }
        let folderName = cRoot["name"] as? String
        var list: [ResolvedDownload] = []
        for (_, rawVal) in children {
            guard let child = rawVal as? [String: Any] else { continue }
            let childType = (child["type"] as? String) ?? "file"
            if childType == "folder",
               let subId = (child["code"] as? String) ?? (child["id"] as? String) {
                let subItems = await resolveGofileList(contentId: subId, passwords: passwords, depth: depth + 1)
                list.append(contentsOf: subItems)
                continue
            }
            guard let link = child["link"] as? String else { continue }
            let name = child["name"] as? String
            let sz = (child["size"] as? NSNumber)?.int64Value
            list.append(
                ResolvedDownload(
                    originalURL: "https://gofile.io/d/\(contentId)",
                    finalURL: link,
                    headers: ["Cookie: accountToken=\(token)"],
                    suggestedFilename: name,
                    useChunkedRange: false,
                    totalSize: sz,
                    subDirectory: nil,
                    maxThreads: 16,
                    needsProxy: true,
                    resolverID: "gofile"
                )
            )
        }
        let isMulti = list.count > 1
        if isMulti, let folderName = folderName, !folderName.isEmpty {
            list = list.map { item in
                ResolvedDownload(
                    originalURL: item.originalURL,
                    finalURL: item.finalURL,
                    headers: item.headers,
                    suggestedFilename: item.suggestedFilename,
                    useChunkedRange: item.useChunkedRange,
                    totalSize: item.totalSize,
                    subDirectory: item.subDirectory ?? folderName,
                    maxThreads: item.maxThreads,
                    needsProxy: item.needsProxy,
                    resolverID: item.resolverID
                )
            }
        }
        list.sort { a, b in
            let na = (a.suggestedFilename ?? "").lowercased()
            let nb = (b.suggestedFilename ?? "").lowercased()
            let aIsMainSetup = na.hasPrefix("setup_") && na.hasSuffix(".exe") && !na.contains("dlc")
            let bIsMainSetup = nb.hasPrefix("setup_") && nb.hasSuffix(".exe") && !nb.contains("dlc")
            if aIsMainSetup != bIsMainSetup { return aIsMainSetup }
            return na < nb
        }
        return HostResolutionResult(downloads: list, failureReason: list.isEmpty ? "分享目录无文件" : nil)
    }
}
