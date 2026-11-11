import SwiftUI

// MARK: - Authentic Things 3 Color Palette
extension Color {
    static let t3SidebarBg     = Color(red: 0.961, green: 0.965, blue: 0.973) // #F5F6F8
    static let t3SidebarActive = Color(red: 0.894, green: 0.902, blue: 0.914) // #E4E6E9
    static let t3SidebarBorder = Color(red: 0.898, green: 0.906, blue: 0.918) // #E5E7EA
    static let t3TopBoxBg      = Color(red: 0.953, green: 0.957, blue: 0.965) // #F3F4F6
    static let t3Divider       = Color(red: 0.918, green: 0.925, blue: 0.933) // #EAECEE
    static let t3PillBorder    = Color(red: 0.835, green: 0.851, blue: 0.875) // #D5D9DF
    static let t3CheckBorder   = Color(red: 0.725, green: 0.753, blue: 0.784) // #B9C0C8

    // Things 3 Iconic Triad: Inbox Blue, Today Gold, Logbook Green
    static let t3Blue          = Color(red: 0.145, green: 0.494, blue: 0.965) // #257EF6
    static let t3Amber         = Color(red: 0.945, green: 0.718, blue: 0.165) // #F1B72A
    static let t3Green         = Color(red: 0.188, green: 0.745, blue: 0.369) // #30BE5E

    static let t3TextMain      = Color(red: 0.133, green: 0.141, blue: 0.157) // #222428
    static let t3TextSub       = Color(red: 0.478, green: 0.502, blue: 0.537) // #7A8089
    static let t3TextMuted     = Color(red: 0.627, green: 0.651, blue: 0.686) // #A0A6AF
}

enum StudioTab: Int, CaseIterable, Codable, Sendable {
    case download = 0
    case unpack = 1
    case patch = 2
    case settings = 3
}

enum SettingsCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case appearance = "外观"
    case download   = "下载"
    case unpack     = "解压"
    case patch      = "补丁"
    var id: String { rawValue }
}

struct AppIconOption: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let category: String
}

enum SteamLanguageOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case schinese = "schinese"
    case tchinese = "tchinese"
    case english  = "english"
    case japanese = "japanese"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .schinese: return "简中"
        case .tchinese: return "繁中"
        case .english:  return "英文"
        case .japanese: return "日文"
        }
    }

    var ipCountry: String {
        switch self {
        case .schinese: return "CN"
        case .tchinese: return "TW"
        case .english:  return "US"
        case .japanese: return "JP"
        }
    }
}
