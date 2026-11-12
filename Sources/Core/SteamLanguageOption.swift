import Foundation

package enum SteamLanguageOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case schinese = "schinese"
    case tchinese = "tchinese"
    case english  = "english"
    case japanese = "japanese"

    package var id: String { rawValue }

    package var shortLabel: String {
        switch self {
        case .schinese: return "简中"
        case .tchinese: return "繁中"
        case .english:  return "英文"
        case .japanese: return "日文"
        }
    }

    package var ipCountry: String {
        switch self {
        case .schinese: return "CN"
        case .tchinese: return "TW"
        case .english:  return "US"
        case .japanese: return "JP"
        }
    }
}
