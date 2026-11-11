import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    var autoRelay: Bool
    var downloadDirectory: String
    var maxConcurrentConnections: Int
    var deleteArchiveAfterUnpack: Bool
    var bottlesDirectory: String
    var defaultLanguage: SteamLanguageOption
    var selectedIconID: String
    var selectedIconVariant: String
    var passwords: [String]

    static let defaultPasswords: [String] = [
        "cs.rin.ru",
        "csrin.org",
        "steamrip.com",
        "www.ovagames.com",
        "online-fix.me",
        "elenemigos.com",
        "elamigos",
        "fitgirl",
        "gog",
        "123456"
    ]

    static var `default`: AppSettings {
        AppSettings(
            autoRelay: true,
            downloadDirectory: ("~/Downloads" as NSString).expandingTildeInPath,
            maxConcurrentConnections: 16,
            deleteArchiveAfterUnpack: false,
            bottlesDirectory: ("~/Library/Application Support/CrossOver/Bottles" as NSString).expandingTildeInPath,
            defaultLanguage: .schinese,
            selectedIconID: "dark_nebula",
            selectedIconVariant: "B",
            passwords: defaultPasswords
        )
    }

    var displayDownloadDirectory: String {
        Self.abbreviateTilde(downloadDirectory)
    }

    var displayBottlesDirectory: String {
        let abbr = Self.abbreviateTilde(bottlesDirectory)
        if abbr == "~/Library/Application Support/CrossOver/Bottles" {
            return "CrossOver Bottles"
        }
        return (abbr as NSString).lastPathComponent.isEmpty ? abbr : (abbr as NSString).lastPathComponent
    }

    static func abbreviateTilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}
