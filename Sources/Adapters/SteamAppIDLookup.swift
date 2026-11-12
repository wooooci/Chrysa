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

}
