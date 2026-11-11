import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case autoRelay
        case downloadDirectory
        case maxConcurrentConnections
        case deleteArchiveAfterUnpack
        case bottlesDirectory
        case defaultLanguage
        case selectedIconID
        case selectedIconVariant
        case passwords
    }

    init(from decoder: Decoder) throws {
        let defaults = Self.default
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoRelay = try container.decodeIfPresent(Bool.self, forKey: .autoRelay) ?? defaults.autoRelay
        downloadDirectory = try container.decodeIfPresent(String.self, forKey: .downloadDirectory) ?? defaults.downloadDirectory
        maxConcurrentConnections = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentConnections) ?? defaults.maxConcurrentConnections
        deleteArchiveAfterUnpack = try container.decodeIfPresent(Bool.self, forKey: .deleteArchiveAfterUnpack) ?? defaults.deleteArchiveAfterUnpack
        bottlesDirectory = try container.decodeIfPresent(String.self, forKey: .bottlesDirectory) ?? defaults.bottlesDirectory
        defaultLanguage = try container.decodeIfPresent(SteamLanguageOption.self, forKey: .defaultLanguage) ?? defaults.defaultLanguage
        selectedIconID = try container.decodeIfPresent(String.self, forKey: .selectedIconID) ?? defaults.selectedIconID
        selectedIconVariant = try container.decodeIfPresent(String.self, forKey: .selectedIconVariant) ?? defaults.selectedIconVariant
        passwords = try container.decodeIfPresent([String].self, forKey: .passwords) ?? defaults.passwords
    }

    var autoRelay: Bool
    var downloadDirectory: String
    var maxConcurrentConnections: Int
    var deleteArchiveAfterUnpack: Bool
    var bottlesDirectory: String
    var defaultLanguage: SteamLanguageOption
    var selectedIconID: String
    var selectedIconVariant: String
    var passwords: [String]

    init(
        autoRelay: Bool,
        downloadDirectory: String,
        maxConcurrentConnections: Int,
        deleteArchiveAfterUnpack: Bool,
        bottlesDirectory: String,
        defaultLanguage: SteamLanguageOption,
        selectedIconID: String,
        selectedIconVariant: String,
        passwords: [String]
    ) {
        self.autoRelay = autoRelay
        self.downloadDirectory = downloadDirectory
        self.maxConcurrentConnections = maxConcurrentConnections
        self.deleteArchiveAfterUnpack = deleteArchiveAfterUnpack
        self.bottlesDirectory = bottlesDirectory
        self.defaultLanguage = defaultLanguage
        self.selectedIconID = selectedIconID
        self.selectedIconVariant = selectedIconVariant
        self.passwords = passwords
    }

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
