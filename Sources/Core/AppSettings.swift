import Foundation

package enum AccentColorMode: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case monochrome = "monochrome"
    case followAppIcon = "followAppIcon"

    package var id: String { rawValue }

    package var displayName: String {
        switch self {
        case .monochrome:
            return "基础纯黑"
        case .followAppIcon:
            return "跟随 Logo 主题色"
        }
    }
}

package struct AppearanceSettings: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case selectedIconID
        case selectedIconVariant
        case accentColorMode
    }

    package var selectedIconID: String
    package var selectedIconVariant: String
    package var accentColorMode: AccentColorMode

    package init(
        selectedIconID: String = "dark_nebula",
        selectedIconVariant: String = "B",
        accentColorMode: AccentColorMode = .monochrome
    ) {
        self.selectedIconID = selectedIconID
        self.selectedIconVariant = selectedIconVariant
        self.accentColorMode = accentColorMode
    }

    package init(from decoder: Decoder) throws {
        let defaults = AppearanceSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedIconID = try container.decodeIfPresent(String.self, forKey: .selectedIconID) ?? defaults.selectedIconID
        selectedIconVariant = try container.decodeIfPresent(String.self, forKey: .selectedIconVariant) ?? defaults.selectedIconVariant
        accentColorMode = (try? container.decodeIfPresent(AccentColorMode.self, forKey: .accentColorMode)) ?? defaults.accentColorMode
    }
}

package struct DownloadSettings: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case downloadDirectory, maxConcurrentConnections, maxConcurrentDownloads
    }

    package var downloadDirectory: String
    package var maxConcurrentConnections: Int
    package var maxConcurrentDownloads: Int

    package init(
        downloadDirectory: String = ("~/Downloads" as NSString).expandingTildeInPath,
        maxConcurrentConnections: Int = 16,
        maxConcurrentDownloads: Int = 2
    ) {
        self.downloadDirectory = downloadDirectory
        self.maxConcurrentConnections = maxConcurrentConnections
        self.maxConcurrentDownloads = Self.clampedConcurrentDownloads(maxConcurrentDownloads)
    }

    package init(from decoder: Decoder) throws {
        let defaults = DownloadSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downloadDirectory = try container.decodeIfPresent(String.self, forKey: .downloadDirectory) ?? defaults.downloadDirectory
        maxConcurrentConnections = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentConnections) ?? defaults.maxConcurrentConnections
        let rawConcurrent = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentDownloads) ?? defaults.maxConcurrentDownloads
        maxConcurrentDownloads = Self.clampedConcurrentDownloads(rawConcurrent)
    }

    package static func clampedConcurrentDownloads(_ value: Int) -> Int {
        min(4, max(1, value))
    }
}

package struct UnpackSettings: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey { case autoRelay, deleteArchiveAfterUnpack, passwords }

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

    package init(from decoder: Decoder) throws {
        let defaults = UnpackSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoRelay = try container.decodeIfPresent(Bool.self, forKey: .autoRelay) ?? defaults.autoRelay
        deleteArchiveAfterUnpack = try container.decodeIfPresent(Bool.self, forKey: .deleteArchiveAfterUnpack) ?? defaults.deleteArchiveAfterUnpack
        passwords = try container.decodeIfPresent([String].self, forKey: .passwords) ?? defaults.passwords
    }
}

package struct PatchSettings: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey { case bottlesDirectory, defaultLanguage }

    package var bottlesDirectory: String
    package var defaultLanguage: SteamLanguageOption

    package init(
        bottlesDirectory: String = ("~/Library/Application Support/CrossOver/Bottles" as NSString).expandingTildeInPath,
        defaultLanguage: SteamLanguageOption = .schinese
    ) {
        self.bottlesDirectory = bottlesDirectory
        self.defaultLanguage = defaultLanguage
    }

    package init(from decoder: Decoder) throws {
        let defaults = PatchSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bottlesDirectory = try container.decodeIfPresent(String.self, forKey: .bottlesDirectory) ?? defaults.bottlesDirectory
        defaultLanguage = (try? container.decodeIfPresent(SteamLanguageOption.self, forKey: .defaultLanguage)) ?? defaults.defaultLanguage
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
        case accentColorMode
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

    package var maxConcurrentDownloads: Int {
        get { download.maxConcurrentDownloads }
        set { download.maxConcurrentDownloads = DownloadSettings.clampedConcurrentDownloads(newValue) }
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

    package var accentColorMode: AccentColorMode {
        get { appearance.accentColorMode }
        set { appearance.accentColorMode = newValue }
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
        maxConcurrentDownloads: Int = 2,
        deleteArchiveAfterUnpack: Bool,
        bottlesDirectory: String,
        defaultLanguage: SteamLanguageOption,
        selectedIconID: String,
        selectedIconVariant: String,
        accentColorMode: AccentColorMode = .monochrome,
        passwords: [String]
    ) {
        self.appearance = AppearanceSettings(
            selectedIconID: selectedIconID,
            selectedIconVariant: selectedIconVariant,
            accentColorMode: accentColorMode
        )
        self.download = DownloadSettings(
            downloadDirectory: downloadDirectory,
            maxConcurrentConnections: maxConcurrentConnections,
            maxConcurrentDownloads: maxConcurrentDownloads
        )
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
        let accentMode = (try? container.decodeIfPresent(AccentColorMode.self, forKey: .accentColorMode))
            ?? decodedAppearance?.accentColorMode ?? defaults.accentColorMode
        let dlDir = try container.decodeIfPresent(String.self, forKey: .downloadDirectory)
            ?? decodedDownload?.downloadDirectory ?? defaults.downloadDirectory
        let maxConn = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentConnections)
            ?? decodedDownload?.maxConcurrentConnections ?? defaults.maxConcurrentConnections
        let maxDl = decodedDownload?.maxConcurrentDownloads ?? defaults.maxConcurrentDownloads

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
            maxConcurrentDownloads: maxDl,
            deleteArchiveAfterUnpack: delArchive,
            bottlesDirectory: bottlesDir,
            defaultLanguage: lang,
            selectedIconID: iconID,
            selectedIconVariant: iconVariant,
            accentColorMode: accentMode,
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
