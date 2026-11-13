import ChrysaCore
import ChrysaApplication
import SwiftUI

// MARK: - Authentic Things 3 Color Palette
extension Color {
    package static let t3SidebarBg     = Color(red: 0.961, green: 0.965, blue: 0.973) // #F5F6F8
    package static let t3SidebarActive = Color(red: 0.894, green: 0.902, blue: 0.914) // #E4E6E9
    package static let t3SidebarBorder = Color(red: 0.898, green: 0.906, blue: 0.918) // #E5E7EA
    package static let t3TopBoxBg      = Color(red: 0.953, green: 0.957, blue: 0.965) // #F3F4F6
    package static let t3Divider       = Color(red: 0.918, green: 0.925, blue: 0.933) // #EAECEE
    package static let t3PillBorder    = Color(red: 0.835, green: 0.851, blue: 0.875) // #D5D9DF
    package static let t3CheckBorder   = Color(red: 0.725, green: 0.753, blue: 0.784) // #B9C0C8

    // Minimalist Ink Monochrome & Semantic Status Accents
    package static let t3InkBlack      = Color(red: 0.094, green: 0.102, blue: 0.118) // #181A1E
    package static let t3IconMutedInk  = Color(red: 0.165, green: 0.176, blue: 0.196) // #2A2D32
    package static let t3Blue          = Color(red: 0.145, green: 0.494, blue: 0.965) // #257EF6
    package static let t3Amber         = Color(red: 0.945, green: 0.718, blue: 0.165) // #F1B72A
    package static let t3Green         = Color(red: 0.188, green: 0.745, blue: 0.369) // #30BE5E

    package static let t3TextMain      = Color(red: 0.133, green: 0.141, blue: 0.157) // #222428
    package static let t3TextSub       = Color(red: 0.478, green: 0.502, blue: 0.537) // #7A8089
    package static let t3TextMuted     = Color(red: 0.627, green: 0.651, blue: 0.686) // #A0A6AF
}

package enum StudioTab: Int, CaseIterable, Codable, Sendable {
    case download = 0
    case unpack = 1
    case patch = 2
    case launch = 3
    case settings = 4

    package var symbolName: String {
        switch self {
        case .download: return "tray.and.arrow.down"
        case .unpack:   return "square.grid.3x1.folder.badge.plus"
        case .patch:    return "puzzlepiece"
        case .launch:   return "gamecontroller"
        case .settings: return "slider.horizontal.3"
        }
    }
}

package enum SettingsCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case appearance = "外观"
    case download   = "下载"
    case unpack     = "解压"
    case patch      = "补丁"
    package var id: String { rawValue }
}

package struct AppIconOption: Identifiable, Sendable {
    package let id: String
    package let title: String
    package let subtitle: String
    package let category: String
}

// MARK: - Resolved Icon & Accent Theme (Pure-Black Default vs Follow App Logo)
package struct AppThemePalette: Equatable, Sendable {
    package let mode: AccentColorMode
    package let selectedIconID: String
    package let accent: Color
    package let iconActive: Color
    package let iconInactive: Color
    package let logoAccent: Color
    package let logoColorTitle: String

    package static let `default` = resolve(settings: .default)

    package static func resolve(settings: AppSettings) -> AppThemePalette {
        resolve(mode: settings.accentColorMode, selectedIconID: settings.selectedIconID)
    }

    package static func resolve(mode: AccentColorMode, selectedIconID: String) -> AppThemePalette {
        let spec = logoThemeSpec(for: selectedIconID)
        switch mode {
        case .monochrome:
            return AppThemePalette(
                mode: .monochrome,
                selectedIconID: selectedIconID,
                accent: .t3InkBlack,
                iconActive: .t3InkBlack,
                iconInactive: .t3IconMutedInk,
                logoAccent: spec.color,
                logoColorTitle: spec.name
            )
        case .followAppIcon:
            return AppThemePalette(
                mode: .followAppIcon,
                selectedIconID: selectedIconID,
                accent: spec.color,
                iconActive: spec.color,
                iconInactive: spec.color.opacity(0.82),
                logoAccent: spec.color,
                logoColorTitle: spec.name
            )
        }
    }

    package static func logoAccentColor(for iconID: String) -> Color {
        logoThemeSpec(for: iconID).color
    }

    private static func logoThemeSpec(for iconID: String) -> (color: Color, name: String) {
        switch iconID {
        case "cultured_prussian":
            // 白底 3 · 学院普鲁士蓝 (#24479E)
            return (Color(red: 0.141, green: 0.278, blue: 0.620), "学院普鲁士蓝")
        case "nordic_sage":
            // 白底 4 · 北欧莫兰迪冷杉 (#2B5B50)
            return (Color(red: 0.169, green: 0.357, blue: 0.314), "北欧冷杉绿")
        case "w6_burgundy":
            // 白底 6A · 暖砂陶土与勃艮第 (#8C2D38)
            return (Color(red: 0.549, green: 0.176, blue: 0.220), "勃艮第酒红")
        case "dark_nebula":
            // 黑底 1 · 曜石星云紫青 (#1E7CC8)
            return (Color(red: 0.118, green: 0.486, blue: 0.784), "星云电光青")
        case "dark_terracotta_gold":
            // 黑底 2 · 曜石黑金与赤陶 (#B25B28)
            return (Color(red: 0.698, green: 0.357, blue: 0.157), "干邑赤陶金")
        case "dark_emerald_mint":
            // 黑底 3 · 曜石极光翡翠 (#14846E)
            return (Color(red: 0.078, green: 0.518, blue: 0.431), "极光翡翠绿")
        default:
            return (Color(red: 0.118, green: 0.486, blue: 0.784), "星云电光青")
        }
    }
}

private struct AppThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppThemePalette = .default
}

extension EnvironmentValues {
    package var appTheme: AppThemePalette {
        get { self[AppThemeEnvironmentKey.self] }
        set { self[AppThemeEnvironmentKey.self] = newValue }
    }
}
