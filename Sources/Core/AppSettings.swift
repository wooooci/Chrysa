import Foundation

package struct AppearanceSettings: Codable, Equatable, Sendable {
    package var selectedIconID: String
    package var selectedIconVariant: String

    package init(selectedIconID: String = "dark_nebula", selectedIconVariant: String = "B") {
        self.selectedIconID = selectedIconID
        self.selectedIconVariant = selectedIconVariant
    }
}

package struct DownloadSettings: Codable, Equatable, Sendable {
    package var downloadDirectory: String
    package var maxConcurrentConnections: Int

    package init(
        downloadDirectory: String = ("~/Downloads" as NSString).expandingTildeInPath,
        maxConcurrentConnections: Int = 16
    ) {
        self.downloadDirectory = downloadDirectory
        self.maxConcurrentConnections = maxConcurrentConnections
    }
}

package struct UnpackSettings: Codable, Equatable, Sendable {
    package var autoRelay: Bool
    package var deleteArchiveAfterUnpack: Bool
    package var passwords: [String]

    package init(
        autoRelay: Bool = true,
        deleteArchiveAfterUnpack: Bool = false,
        passwords: [String] = AppSettings.defaultPasswords
    ) {
        self.autoRelay = autoRelay
        self.deleteArchiveAfterUnpack = deleteArchiveAfterUnpack
        self.passwords = passwords
    }
}

package struct PatchSettings: Codable, Equatable, Sendable {
    package var bottlesDirectory: String
    package var defaultLanguage: SteamLanguageOption

    package init(
        bottlesDirectory: String = ("~/Library/Application Support/CrossOver/Bottles" as NSString).expandingTildeInPath,
        defaultLanguage: SteamLanguageOption = .schinese
    ) {
        self.bottlesDirectory = bottlesDirectory
        self.defaultLanguage = defaultLanguage
    }
}

package struct AppSettings: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case appearance
        case download
        case unpack
        case patch
        // Legacy flat keys kept for seamless migration of existing settings.json files
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

    package var appearance: AppearanceSettings
    package var download: DownloadSettings
    package var unpack: UnpackSettings
    package var patch: PatchSettings

    package var autoRelay: Bool {
        get { unpack.autoRelay }
        set { unpack.autoRelay = newValue }
    }

    package var downloadDirectory: String {
        get { download.downloadDirectory }
        set { download.downloadDirectory = newValue }
    }

    package var maxConcurrentConnections: Int {
        get { download.maxConcurrentConnections }
        set { download.maxConcurrentConnections = newValue }
    }

    package var deleteArchiveAfterUnpack: Bool {
        get { unpack.deleteArchiveAfterUnpack }
        set { unpack.deleteArchiveAfterUnpack = newValue }
    }

    package var bottlesDirectory: String {
        get { patch.bottlesDirectory }
        set { patch.bottlesDirectory = newValue }
    }

    package var defaultLanguage: SteamLanguageOption {
        get { patch.defaultLanguage }
        set { patch.defaultLanguage = newValue }
    }

    package var selectedIconID: String {
        get { appearance.selectedIconID }
        set { appearance.selectedIconID = newValue }
    }

    package var selectedIconVariant: String {
        get { appearance.selectedIconVariant }
        set { appearance.selectedIconVariant = newValue }
    }

    package var passwords: [String] {
        get { unpack.passwords }
        set { unpack.passwords = newValue }
    }

    package init(
        appearance: AppearanceSettings = AppearanceSettings(),
        download: DownloadSettings = DownloadSettings(),
        unpack: UnpackSettings = UnpackSettings(),
        patch: PatchSettings = PatchSettings()
    ) {
        self.appearance = appearance
        self.download = download
        self.unpack = unpack
        self.patch = patch
    }

    package init(
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
        self.appearance = AppearanceSettings(selectedIconID: selectedIconID, selectedIconVariant: selectedIconVariant)
        self.download = DownloadSettings(downloadDirectory: downloadDirectory, maxConcurrentConnections: maxConcurrentConnections)
        self.unpack = UnpackSettings(autoRelay: autoRelay, deleteArchiveAfterUnpack: deleteArchiveAfterUnpack, passwords: passwords)
        self.patch = PatchSettings(bottlesDirectory: bottlesDirectory, defaultLanguage: defaultLanguage)
    }

    package init(from decoder: Decoder) throws {
        let defaults = Self.default
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let decodedAppearance = try container.decodeIfPresent(AppearanceSettings.self, forKey: .appearance)
        let decodedDownload = try container.decodeIfPresent(DownloadSettings.self, forKey: .download)
        let decodedUnpack = try container.decodeIfPresent(UnpackSettings.self, forKey: .unpack)
        let decodedPatch = try container.decodeIfPresent(PatchSettings.self, forKey: .patch)

        let iconID = try container.decodeIfPresent(String.self, forKey: .selectedIconID)
            ?? decodedAppearance?.selectedIconID ?? defaults.selectedIconID
        let iconVariant = try container.decodeIfPresent(String.self, forKey: .selectedIconVariant)
            ?? decodedAppearance?.selectedIconVariant ?? defaults.selectedIconVariant

        let dlDir = try container.decodeIfPresent(String.self, forKey: .downloadDirectory)
            ?? decodedDownload?.downloadDirectory ?? defaults.downloadDirectory
        let maxConn = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentConnections)
            ?? decodedDownload?.maxConcurrentConnections ?? defaults.maxConcurrentConnections

        let relay = try container.decodeIfPresent(Bool.self, forKey: .autoRelay)
            ?? decodedUnpack?.autoRelay ?? defaults.autoRelay
        let delArchive = try container.decodeIfPresent(Bool.self, forKey: .deleteArchiveAfterUnpack)
            ?? decodedUnpack?.deleteArchiveAfterUnpack ?? defaults.deleteArchiveAfterUnpack
        let pwds = try container.decodeIfPresent([String].self, forKey: .passwords)
            ?? decodedUnpack?.passwords ?? defaults.passwords

        let bottlesDir = try container.decodeIfPresent(String.self, forKey: .bottlesDirectory)
            ?? decodedPatch?.bottlesDirectory ?? defaults.bottlesDirectory
        let lang = try container.decodeIfPresent(SteamLanguageOption.self, forKey: .defaultLanguage)
            ?? decodedPatch?.defaultLanguage ?? defaults.defaultLanguage

        self.init(
            autoRelay: relay,
            downloadDirectory: dlDir,
            maxConcurrentConnections: maxConn,
            deleteArchiveAfterUnpack: delArchive,
            bottlesDirectory: bottlesDir,
            defaultLanguage: lang,
            selectedIconID: iconID,
            selectedIconVariant: iconVariant,
            passwords: pwds
        )
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(download, forKey: .download)
        try container.encode(unpack, forKey: .unpack)
        try container.encode(patch, forKey: .patch)
    }

    package static let defaultPasswords: [String] = [
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

    package static var `default`: AppSettings {
        AppSettings()
    }

    package var displayDownloadDirectory: String {
        Self.abbreviateTilde(downloadDirectory)
    }

    package var displayBottlesDirectory: String {
        let abbr = Self.abbreviateTilde(bottlesDirectory)
        if abbr == "~/Library/Application Support/CrossOver/Bottles" {
            return "CrossOver Bottles"
        }
        return (abbr as NSString).lastPathComponent.isEmpty ? abbr : (abbr as NSString).lastPathComponent
    }

    package static func abbreviateTilde(_ path: String) -> String {
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
