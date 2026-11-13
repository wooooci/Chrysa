import ChrysaCore
import ChrysaApplication
import Foundation

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
