import ChrysaCore
import ChrysaApplication
import Foundation

package enum SteamAppIDLookup {
    package static func fetch(for gameName: String) async -> String? {
        guard let encoded = gameName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://store.steampowered.com/api/storesearch/?term=\(encoded)&l=schinese&cc=CN") else {
            return nil
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
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
              let assets = items.first?["assets"] as? [String: Any],
              let iconHash = assets["community_icon"] as? String,
              !iconHash.isEmpty else {
            return nil
        }
        let filename = iconHash.contains(".") ? iconHash : "\(iconHash).jpg"
        return URL(string: "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/\(numericID)/\(filename)")
    }

    package static func fetchCommunityIconData(appID: String) async -> Data? {
        guard let primaryURL = await fetchCommunityIconURL(appID: appID) else { return nil }
        let urls: [URL] = [
            primaryURL,
            URL(string: primaryURL.absoluteString.replacingOccurrences(
                of: "cdn.cloudflare.steamstatic.com",
                with: "steamcdn-a.akamaihd.net"
            ))
        ].compactMap { $0 }

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
