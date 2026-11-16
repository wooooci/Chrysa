import ChrysaCore
import ChrysaApplication
import Foundation

package struct SteamDLCItem: Codable, Equatable, Hashable, Sendable {
    package let id: String
    package let name: String

    package init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

private actor SteamDLCCacheStore {
    static let shared = SteamDLCCacheStore()

    private struct CacheEntry: Codable {
        let fetchedAt: Date
        let items: [SteamDLCItem]
    }

    private var memoryCache: [String: CacheEntry] = [:]
    private var loadedDisk = false
    private let ttl: TimeInterval = 60 * 60 * 24 // 24 hours

    private var cacheFileURL: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("Chrysa", isDirectory: true)
            .appendingPathComponent("dlc-cache.json")
    }

    private func loadDiskIfNeeded() {
        guard !loadedDisk else { return }
        loadedDisk = true
        guard let url = cacheFileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else {
            return
        }
        for (key, value) in decoded {
            memoryCache[key] = value
        }
    }

    func freshEntry(for appID: String, now: Date = Date()) -> [SteamDLCItem]? {
        loadDiskIfNeeded()
        guard let entry = memoryCache[appID],
              now.timeIntervalSince(entry.fetchedAt) <= ttl else {
            return nil
        }
        return entry.items
    }

    func staleEntry(for appID: String) -> [SteamDLCItem]? {
        loadDiskIfNeeded()
        return memoryCache[appID]?.items
    }

    func store(_ items: [SteamDLCItem], for appID: String, now: Date = Date()) {
        loadDiskIfNeeded()
        memoryCache[appID] = CacheEntry(fetchedAt: now, items: items)
        guard let url = cacheFileURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(memoryCache) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

package enum SteamAppIDLookup {
    package static func fetch(for gameName: String) async -> String? {
        for query in searchVariants(for: gameName) {
            if let appID = await queryStoreSearch(term: query) {
                return appID
            }
        }
        return nil
    }

    private static func searchVariants(for gameName: String) -> [String] {
        let trimmed = gameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var variants: [String] = []
        func appendUnique(_ value: String) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty && !variants.contains(v) {
                variants.append(v)
            }
        }

        appendUnique(trimmed)

        var stripped = trimmed
        for suffix in [".app", ".exe", "-Win64-Shipping", "-Win32-Shipping", "-Mac-Shipping"] {
            if stripped.lowercased().hasSuffix(suffix.lowercased()) {
                stripped = String(stripped.dropLast(suffix.count))
            }
        }
        appendUnique(stripped)

        let spaced = stripped
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        appendUnique(spaced)

        let cleaned = GameTitle.cleanGameTitle(from: spaced)
        appendUnique(cleaned)

        return variants
    }

    private static func queryStoreSearch(term: String) async -> String? {
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://store.steampowered.com/api/storesearch/?term=\(encoded)&l=schinese&cc=CN") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]],
              let first = items.first,
              let idVal = first["id"] as? Int else {
            return nil
        }
        return String(idVal)
    }

    /// Fetches the public square `community_icon` CDN URL for a Steam AppID via `IStoreBrowseService`.
    package static func fetchCommunityIconURL(appID: String) async -> URL? {
        let trimmed = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let numericID = Int(trimmed), numericID > 0, trimmed != "480" else {
            return nil
        }
        let assets = await fetchStoreBrowseAssets(numericID: numericID)
        guard let iconHash = assets?["community_icon"] as? String, !iconHash.isEmpty else {
            return nil
        }
        let filename = iconHash.contains(".") ? iconHash : "\(iconHash).jpg"
        return URL(string: "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/\(numericID)/\(filename)")
    }

    private static func fetchStoreBrowseAssets(numericID: Int) async -> [String: Any]? {
        let inputPayload = "{\"ids\":[{\"appid\":\(numericID)}],\"context\":{\"language\":\"schinese\",\"country_code\":\"CN\"},\"data_request\":{\"include_assets\":true}}"
        guard let encoded = inputPayload.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.steampowered.com/IStoreBrowseService/GetItems/v1/?input_json=\(encoded)") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resp = root["response"] as? [String: Any],
              let items = resp["store_items"] as? [[String: Any]],
              let assets = items.first?["assets"] as? [String: Any] else {
            return nil
        }
        return assets
    }

    package static func fetchIconAsset(appID: String) async -> (data: Data, isSquare: Bool)? {
        let trimmed = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let numericID = Int(trimmed), numericID > 0, trimmed != "480" else {
            return nil
        }

        if let assets = await fetchStoreBrowseAssets(numericID: numericID) {
            if let iconHash = assets["community_icon"] as? String, !iconHash.isEmpty {
                let filename = iconHash.contains(".") ? iconHash : "\(iconHash).jpg"
                if let primary = URL(string: "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/\(numericID)/\(filename)"),
                   let data = await fetchFirstAvailable(from: mirroredCDNs(for: primary)) {
                    return (data, true)
                }
            }

            let format = (assets["asset_url_format"] as? String) ?? "steam/apps/\(numericID)/${FILENAME}"
            let fallbackKeys = ["library_capsule", "small_capsule", "header"]
            for key in fallbackKeys {
                if let file = assets[key] as? String, !file.isEmpty {
                    let rel = format.replacingOccurrences(of: "${FILENAME}", with: file)
                    if let url = URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/\(rel)"),
                       let data = await fetchFirstAvailable(from: [url]) {
                        return (data, false)
                    }
                }
            }
        }

        let directFallbacks = [
            "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(numericID)/capsule_231x87.jpg",
            "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(numericID)/header.jpg"
        ].compactMap { URL(string: $0) }
        if let data = await fetchFirstAvailable(from: directFallbacks) {
            return (data, false)
        }
        return nil
    }

    package static func fetchCommunityIconData(appID: String) async -> Data? {
        await fetchIconAsset(appID: appID)?.data
    }

    package static func fetchDLCs(appID: String) async -> [SteamDLCItem] {
        let trimmed = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let numericID = Int(trimmed), numericID > 0, trimmed != "480" else {
            return []
        }

        if let cached = await SteamDLCCacheStore.shared.freshEntry(for: trimmed) {
            return cached
        }

        guard let dlcIDs = await queryAppDetailsDLCIDs(numericID: numericID) else {
            // Silent degradation offline / on timeout: fallback to any stale cache or empty list.
            return await SteamDLCCacheStore.shared.staleEntry(for: trimmed) ?? []
        }

        if dlcIDs.isEmpty {
            await SteamDLCCacheStore.shared.store([], for: trimmed)
            return []
        }

        let namesByID = await queryStoreBrowseEnglishNames(dlcIDs: dlcIDs)
        var seen = Set<Int>()
        let items: [SteamDLCItem] = dlcIDs.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            let rawName = namesByID[id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (rawName?.isEmpty == false) ? rawName! : "DLC \(id)"
            return SteamDLCItem(id: String(id), name: name)
        }
        await SteamDLCCacheStore.shared.store(items, for: trimmed)
        return items
    }

    package static func parseAppDetailsDLCIDs(from data: Data, appID: String) -> [Int]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let appDict = (root[appID] as? [String: Any])
            ?? (root.values.first as? [String: Any])
        guard let appDict else { return nil }
        if let success = appDict["success"] as? Bool, !success {
            return nil
        }
        guard let payload = appDict["data"] as? [String: Any] else {
            return []
        }
        guard let rawDLCs = payload["dlc"] as? [Any] else {
            return []
        }
        var result: [Int] = []
        var seen = Set<Int>()
        for entry in rawDLCs {
            if let num = entry as? Int, num > 0, seen.insert(num).inserted {
                result.append(num)
            } else if let str = entry as? String, let num = Int(str.trimmingCharacters(in: .whitespaces)), num > 0, seen.insert(num).inserted {
                result.append(num)
            }
        }
        return result
    }

    package static func parseStoreBrowseItemNames(from data: Data) -> [Int: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resp = root["response"] as? [String: Any],
              let items = resp["store_items"] as? [[String: Any]] else {
            return [:]
        }
        var names: [Int: String] = [:]
        for item in items {
            let appID: Int? = (item["appid"] as? Int)
                ?? (item["id"] as? Int)
                ?? (item["appid"] as? String).flatMap(Int.init)
            guard let appID, appID > 0,
                  let name = item["name"] as? String else {
                continue
            }
            let cleaned = name
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                names[appID] = cleaned
            }
        }
        return names
    }

    private static func queryAppDetailsDLCIDs(numericID: Int) async -> [Int]? {
        let appIDString = String(numericID)
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appIDString)&filters=basic,dlc&l=english") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        return parseAppDetailsDLCIDs(from: data, appID: appIDString)
    }

    private static func queryStoreBrowseEnglishNames(dlcIDs: [Int]) async -> [Int: String] {
        var resolved: [Int: String] = [:]
        let batchSize = 50
        var offset = 0
        while offset < dlcIDs.count {
            let end = min(offset + batchSize, dlcIDs.count)
            let batch = dlcIDs[offset..<end]
            offset = end

            let idsJSON = batch.map { "{\"appid\":\($0)}" }.joined(separator: ",")
            let payload = "{\"ids\":[\(idsJSON)],\"context\":{\"language\":\"english\",\"country_code\":\"US\"},\"data_request\":{\"include_basic_info\":true}}"
            guard let encoded = payload.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://api.steampowered.com/IStoreBrowseService/GetItems/v1/?input_json=\(encoded)") else {
                continue
            }
            var request = URLRequest(url: url, timeoutInterval: 4)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                continue
            }
            let partial = parseStoreBrowseItemNames(from: data)
            for (id, name) in partial {
                resolved[id] = name
            }
        }
        return resolved
    }

    private static func mirroredCDNs(for primaryURL: URL) -> [URL] {
        [
            primaryURL,
            URL(string: primaryURL.absoluteString.replacingOccurrences(
                of: "cdn.cloudflare.steamstatic.com",
                with: "steamcdn-a.akamaihd.net"
            ))
        ].compactMap { $0 }
    }

    private static func fetchFirstAvailable(from urls: [URL]) async -> Data? {
        for url in urls {
            var req = URLRequest(url: url, timeoutInterval: 5)
            req.cachePolicy = .returnCacheDataElseLoad
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               !data.isEmpty {
                return data
            }
        }
        return nil
    }
}
