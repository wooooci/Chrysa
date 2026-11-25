import Foundation

package enum AppearanceMode: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    package var id: String { rawValue }

    package var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }
}

package enum AccentColorMode: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case monochrome = "monochrome"
    case followAppIcon = "followAppIcon"
    case custom = "custom"

    package var id: String { rawValue }

    package var displayName: String {
        switch self {
        case .monochrome:
            return "纯色墨韵"
        case .followAppIcon:
            return "跟随图标"
        case .custom:
            return "自定义色"
        }
    }
}

package enum AccentSwatch: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case cobalt = "cobalt"
    case emerald = "emerald"
    case amber = "amber"
    case rose = "rose"
    case violet = "violet"

    package var id: String { rawValue }

    package var displayName: String {
        switch self {
        case .cobalt:  return "钴蓝"
        case .emerald: return "翡翠"
        case .amber:   return "琥珀"
        case .rose:    return "莓红"
        case .violet:  return "雾紫"
        }
    }
}

package enum MascotTheme: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case forestCube = "forestCube"
    case roundMochi = "roundMochi"
    case grokAstral = "grokAstral"
    case none = "none"

    package var id: String { rawValue }

    package var isEnabled: Bool {
        self != .none
    }

    package var displayName: String {
        switch self {
        case .forestCube:
            return "块块"
        case .roundMochi:
            return "糯糯"
        case .grokAstral:
            return "球球"
        case .none:
            return "无"
        }
    }

    package var companionSubtitle: String {
        switch self {
        case .forestCube:
            return "青瓷方石 + 单叶小石仔"
        case .roundMochi:
            return "无耳软团 + Q弹小汤圆"
        case .grokAstral:
            return "悬浮星陶 + 星轨小卫球"
        case .none:
            return "纯正 Things 3 静谧界面"
        }
    }
}

package struct AppearanceSettings: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case appearanceMode
        case selectedIconID
        case selectedIconVariant
        case accentColorMode
        case accentSwatch
        case mascotTheme
    }

    package var appearanceMode: AppearanceMode
    package var selectedIconID: String
    package var selectedIconVariant: String
    package var accentColorMode: AccentColorMode
    package var accentSwatch: AccentSwatch
    package var mascotTheme: MascotTheme

    package init(
        appearanceMode: AppearanceMode = .system,
        selectedIconID: String = "dark_nebula",
        selectedIconVariant: String = "B",
        accentColorMode: AccentColorMode = .monochrome,
        accentSwatch: AccentSwatch = .cobalt,
        mascotTheme: MascotTheme = .forestCube
    ) {
        self.appearanceMode = appearanceMode
        self.selectedIconID = selectedIconID
        self.selectedIconVariant = selectedIconVariant
        self.accentColorMode = accentColorMode
        self.accentSwatch = accentSwatch
        self.mascotTheme = mascotTheme
    }

    package init(from decoder: Decoder) throws {
        let defaults = AppearanceSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appearanceMode = (try? container.decodeIfPresent(AppearanceMode.self, forKey: .appearanceMode)) ?? defaults.appearanceMode
        selectedIconID = try container.decodeIfPresent(String.self, forKey: .selectedIconID) ?? defaults.selectedIconID
        selectedIconVariant = try container.decodeIfPresent(String.self, forKey: .selectedIconVariant) ?? defaults.selectedIconVariant
        accentColorMode = (try? container.decodeIfPresent(AccentColorMode.self, forKey: .accentColorMode)) ?? defaults.accentColorMode
        accentSwatch = (try? container.decodeIfPresent(AccentSwatch.self, forKey: .accentSwatch)) ?? defaults.accentSwatch
        mascotTheme = (try? container.decodeIfPresent(MascotTheme.self, forKey: .mascotTheme)) ?? defaults.mascotTheme
    }
}

package enum ProxyPolicy: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case smart = "smart"
    case systemProxy = "systemProxy"
    case directOnly = "directOnly"

    package var id: String { rawValue }

    package var displayName: String {
        switch self {
        case .smart: return "智能分流"
        case .systemProxy: return "系统代理"
        case .directOnly: return "仅直连"
        }
    }
}

package enum AccelerationCredentialKind: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case pixeldrain = "pixeldrain"
    case realDebrid = "realDebrid"
    case torBox = "torBox"

    package var id: String { rawValue }

    package var displayName: String {
        switch self {
        case .pixeldrain: return "Pixeldrain"
        case .realDebrid: return "Real-Debrid"
        case .torBox: return "TorBox"
        }
    }

    package var placeholder: String {
        switch self {
        case .pixeldrain: return "API Key（可选）"
        case .realDebrid: return "API Token（可选）"
        case .torBox: return "API Key（可选）"
        }
    }
}

package struct DownloadSettings: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case downloadDirectory, maxConcurrentConnections, maxConcurrentDownloads
        case proxyPolicy, pixeldrainAPIKey, realDebridToken, torBoxToken
    }

    package var downloadDirectory: String
    package var maxConcurrentConnections: Int
    package var maxConcurrentDownloads: Int
    package var proxyPolicy: ProxyPolicy
    package var pixeldrainAPIKey: String
    package var realDebridToken: String
    package var torBoxToken: String

    package init(
        downloadDirectory: String = ("~/Downloads" as NSString).expandingTildeInPath,
        maxConcurrentConnections: Int = 16,
        maxConcurrentDownloads: Int = 2,
        proxyPolicy: ProxyPolicy = .smart,
        pixeldrainAPIKey: String = "",
        realDebridToken: String = "",
        torBoxToken: String = ""
    ) {
        self.downloadDirectory = downloadDirectory
        self.maxConcurrentConnections = maxConcurrentConnections
        self.maxConcurrentDownloads = Self.clampedConcurrentDownloads(maxConcurrentDownloads)
        self.proxyPolicy = proxyPolicy
        self.pixeldrainAPIKey = pixeldrainAPIKey
        self.realDebridToken = realDebridToken
        self.torBoxToken = torBoxToken
    }

    package init(from decoder: Decoder) throws {
        let defaults = DownloadSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downloadDirectory = try container.decodeIfPresent(String.self, forKey: .downloadDirectory) ?? defaults.downloadDirectory
        maxConcurrentConnections = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentConnections) ?? defaults.maxConcurrentConnections
        let rawConcurrent = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentDownloads) ?? defaults.maxConcurrentDownloads
        maxConcurrentDownloads = Self.clampedConcurrentDownloads(rawConcurrent)
        proxyPolicy = (try? container.decodeIfPresent(ProxyPolicy.self, forKey: .proxyPolicy)) ?? defaults.proxyPolicy
        pixeldrainAPIKey = try container.decodeIfPresent(String.self, forKey: .pixeldrainAPIKey) ?? defaults.pixeldrainAPIKey
        realDebridToken = try container.decodeIfPresent(String.self, forKey: .realDebridToken) ?? defaults.realDebridToken
        torBoxToken = try container.decodeIfPresent(String.self, forKey: .torBoxToken) ?? defaults.torBoxToken
    }

    package var redactedSecrets: [String] {
        var secrets: [String] = []
        let pd = pixeldrainAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pd.isEmpty {
            secrets.append(pd)
            if let encoded = ":\(pd)".data(using: .utf8)?.base64EncodedString(), !encoded.isEmpty {
                secrets.append(encoded)
            }
        }
        let rd = realDebridToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rd.isEmpty { secrets.append(rd) }
        let tb = torBoxToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tb.isEmpty { secrets.append(tb) }
        return secrets
    }

    package func credentialValue(for kind: AccelerationCredentialKind) -> String {
        switch kind {
        case .pixeldrain: return pixeldrainAPIKey
        case .realDebrid: return realDebridToken
        case .torBox: return torBoxToken
        }
    }

    package mutating func setCredentialValue(_ value: String, for kind: AccelerationCredentialKind) {
        switch kind {
        case .pixeldrain: pixeldrainAPIKey = value
        case .realDebrid: realDebridToken = value
        case .torBox: torBoxToken = value
        }
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
        case appearanceMode
        case selectedIconID
        case selectedIconVariant
        case accentColorMode
        case accentSwatch
        case mascotTheme
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

    package var proxyPolicy: ProxyPolicy {
        get { download.proxyPolicy }
        set { download.proxyPolicy = newValue }
    }

    package var pixeldrainAPIKey: String {
        get { download.pixeldrainAPIKey }
        set { download.pixeldrainAPIKey = newValue }
    }

    package var realDebridToken: String {
        get { download.realDebridToken }
        set { download.realDebridToken = newValue }
    }

    package var torBoxToken: String {
        get { download.torBoxToken }
        set { download.torBoxToken = newValue }
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

    package var appearanceMode: AppearanceMode {
        get { appearance.appearanceMode }
        set { appearance.appearanceMode = newValue }
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

    package var accentSwatch: AccentSwatch {
        get { appearance.accentSwatch }
        set { appearance.accentSwatch = newValue }
    }

    package var mascotTheme: MascotTheme {
        get { appearance.mascotTheme }
        set { appearance.mascotTheme = newValue }
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
        proxyPolicy: ProxyPolicy = .smart,
        pixeldrainAPIKey: String = "",
        realDebridToken: String = "",
        torBoxToken: String = "",
        deleteArchiveAfterUnpack: Bool,
        bottlesDirectory: String,
        defaultLanguage: SteamLanguageOption,
        selectedIconID: String,
        selectedIconVariant: String,
        appearanceMode: AppearanceMode = .system,
        accentColorMode: AccentColorMode = .monochrome,
        accentSwatch: AccentSwatch = .cobalt,
        mascotTheme: MascotTheme = .forestCube,
        passwords: [String]
    ) {
        self.appearance = AppearanceSettings(
            appearanceMode: appearanceMode,
            selectedIconID: selectedIconID,
            selectedIconVariant: selectedIconVariant,
            accentColorMode: accentColorMode,
            accentSwatch: accentSwatch,
            mascotTheme: mascotTheme
        )
        self.download = DownloadSettings(
            downloadDirectory: downloadDirectory,
            maxConcurrentConnections: maxConcurrentConnections,
            maxConcurrentDownloads: maxConcurrentDownloads,
            proxyPolicy: proxyPolicy,
            pixeldrainAPIKey: pixeldrainAPIKey,
            realDebridToken: realDebridToken,
            torBoxToken: torBoxToken
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

        let appMode = (try? container.decodeIfPresent(AppearanceMode.self, forKey: .appearanceMode))
            ?? decodedAppearance?.appearanceMode ?? defaults.appearanceMode
        let iconID = try container.decodeIfPresent(String.self, forKey: .selectedIconID)
            ?? decodedAppearance?.selectedIconID ?? defaults.selectedIconID
        let iconVariant = try container.decodeIfPresent(String.self, forKey: .selectedIconVariant)
            ?? decodedAppearance?.selectedIconVariant ?? defaults.selectedIconVariant
        let accentMode = (try? container.decodeIfPresent(AccentColorMode.self, forKey: .accentColorMode))
            ?? decodedAppearance?.accentColorMode ?? defaults.accentColorMode
        let swatch = (try? container.decodeIfPresent(AccentSwatch.self, forKey: .accentSwatch))
            ?? decodedAppearance?.accentSwatch ?? defaults.accentSwatch
        let mascot = (try? container.decodeIfPresent(MascotTheme.self, forKey: .mascotTheme))
            ?? decodedAppearance?.mascotTheme ?? defaults.mascotTheme
        let dlDir = try container.decodeIfPresent(String.self, forKey: .downloadDirectory)
            ?? decodedDownload?.downloadDirectory ?? defaults.downloadDirectory
        let maxConn = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentConnections)
            ?? decodedDownload?.maxConcurrentConnections ?? defaults.maxConcurrentConnections
        let maxDl = decodedDownload?.maxConcurrentDownloads ?? defaults.maxConcurrentDownloads
        let proxyPol = decodedDownload?.proxyPolicy ?? defaults.proxyPolicy
        let pdKey = decodedDownload?.pixeldrainAPIKey ?? defaults.pixeldrainAPIKey
        let rdTok = decodedDownload?.realDebridToken ?? defaults.realDebridToken
        let tbTok = decodedDownload?.torBoxToken ?? defaults.torBoxToken

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
            proxyPolicy: proxyPol,
            pixeldrainAPIKey: pdKey,
            realDebridToken: rdTok,
            torBoxToken: tbTok,
            deleteArchiveAfterUnpack: delArchive,
            bottlesDirectory: bottlesDir,
            defaultLanguage: lang,
            selectedIconID: iconID,
            selectedIconVariant: iconVariant,
            appearanceMode: appMode,
            accentColorMode: accentMode,
            accentSwatch: swatch,
            mascotTheme: mascot,
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
