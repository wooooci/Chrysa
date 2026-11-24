import ChrysaCore
import ChrysaApplication
import SwiftUI
import AppKit

// MARK: - Studio Obsidian Dark & Architectural Light Pure-Flat Palette
extension Color {
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? dark : light
        })
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    // Core Surfaces (Obsidian Dark #0F1013 / Pure Paper Light #FFFFFF)
    package static let t3CanvasBg             = adaptive(light: rgb(1.000, 1.000, 1.000), dark: rgb(0.059, 0.063, 0.075)) // #FFFFFF / #0F1013
    package static let t3SidebarBg            = adaptive(light: rgb(0.957, 0.961, 0.969), dark: rgb(0.075, 0.078, 0.094)) // #F4F5F7 / #131418
    package static let t3SidebarVeil          = adaptive(light: rgb(0.965, 0.969, 0.976, 0.62), dark: rgb(0.055, 0.059, 0.071, 0.56))
    package static let t3SidebarActive        = adaptive(light: rgb(0.000, 0.000, 0.000, 0.068), dark: rgb(1.000, 1.000, 1.000, 0.105))
    package static let t3SidebarBorder        = adaptive(light: rgb(0.000, 0.000, 0.000, 0.075), dark: rgb(1.000, 1.000, 1.000, 0.075))

    // Grouped Cards & Inputs (Distinct +1 Step Elevation, Zero Drop Shadows)
    package static let t3GroupedCardBg        = adaptive(light: rgb(0.969, 0.973, 0.980), dark: rgb(0.090, 0.094, 0.110)) // #F7F8FA / #17181C
    package static let t3GroupedCardBorder    = adaptive(light: rgb(0.000, 0.000, 0.000, 0.068), dark: rgb(1.000, 1.000, 1.000, 0.078))
    package static let t3PreviewWellBg        = adaptive(light: rgb(0.941, 0.949, 0.961), dark: rgb(0.067, 0.071, 0.086)) // #F0F2F5 / #111216
    package static let t3TopBoxBg             = adaptive(light: rgb(0.957, 0.961, 0.969), dark: rgb(0.094, 0.098, 0.114)) // #F4F5F7 / #18191D
    package static let t3TopBoxBorder         = adaptive(light: rgb(0.000, 0.000, 0.000, 0.078), dark: rgb(1.000, 1.000, 1.000, 0.088))
    package static let t3CardBg               = adaptive(light: rgb(1.000, 1.000, 1.000), dark: rgb(0.094, 0.098, 0.114)) // #FFFFFF / #18191D
    package static let t3CardBorder           = adaptive(light: rgb(0.000, 0.000, 0.000, 0.085), dark: rgb(1.000, 1.000, 1.000, 0.095))

    // Matte Low-Glare Controls (No Harsh High-Contrast Slabs in Dark Mode)
    package static let t3ControlFill          = adaptive(light: rgb(0.000, 0.000, 0.000, 0.045), dark: rgb(1.000, 1.000, 1.000, 0.068))
    package static let t3ControlHoverFill     = adaptive(light: rgb(0.000, 0.000, 0.000, 0.082), dark: rgb(1.000, 1.000, 1.000, 0.115))
    package static let t3ControlTrackBg       = adaptive(light: rgb(0.000, 0.000, 0.000, 0.045), dark: rgb(1.000, 1.000, 1.000, 0.052))
    package static let t3ControlSelectedFill  = adaptive(light: rgb(1.000, 1.000, 1.000), dark: rgb(1.000, 1.000, 1.000, 0.125))
    package static let t3ControlSelectedStroke = adaptive(light: rgb(0.000, 0.000, 0.000, 0.085), dark: rgb(1.000, 1.000, 1.000, 0.10))
    package static let t3HoverBg              = adaptive(light: rgb(0.094, 0.102, 0.118, 0.045), dark: rgb(1.000, 1.000, 1.000, 0.055))

    // Hairlines & Checkboxes
    package static let t3Divider              = adaptive(light: rgb(0.000, 0.000, 0.000, 0.065), dark: rgb(1.000, 1.000, 1.000, 0.068))
    package static let t3PillBorder           = adaptive(light: rgb(0.000, 0.000, 0.000, 0.115), dark: rgb(1.000, 1.000, 1.000, 0.125))
    package static let t3CheckBorder          = adaptive(light: rgb(0.718, 0.749, 0.788), dark: rgb(0.322, 0.349, 0.408))
    package static let t3ToggleOffBg          = adaptive(light: rgb(0.820, 0.839, 0.871), dark: rgb(1.000, 1.000, 1.000, 0.145))
    package static let t3ToggleKnobOff        = adaptive(light: rgb(1.000, 1.000, 1.000), dark: rgb(0.860, 0.875, 0.900))

    // Monochrome Ink & Semantic Status Accents
    package static let t3InkBlack             = adaptive(light: rgb(0.094, 0.102, 0.118), dark: rgb(0.863, 0.878, 0.902)) // #181A1E / #DCE0E6
    package static let t3IconMutedInk         = adaptive(light: rgb(0.290, 0.314, 0.353), dark: rgb(0.569, 0.596, 0.651))
    package static let t3Blue                 = adaptive(light: rgb(0.145, 0.494, 0.965), dark: rgb(0.322, 0.608, 1.000))
    package static let t3Amber                = adaptive(light: rgb(0.898, 0.651, 0.110), dark: rgb(0.953, 0.745, 0.259))
    package static let t3Green                = adaptive(light: rgb(0.157, 0.722, 0.341), dark: rgb(0.235, 0.816, 0.435))

    // Typography Hierarchy
    package static let t3TextMain             = adaptive(light: rgb(0.102, 0.114, 0.133), dark: rgb(0.933, 0.941, 0.957)) // #1A1D22 / #EEF0F4
    package static let t3TextSub              = adaptive(light: rgb(0.365, 0.392, 0.439), dark: rgb(0.580, 0.608, 0.663)) // #5D6470 / #949BA9
    package static let t3TextMuted            = adaptive(light: rgb(0.506, 0.533, 0.580), dark: rgb(0.412, 0.439, 0.494)) // #818894 / #69707E
    package static let t3WarningText          = adaptive(light: rgb(0.702, 0.455, 0.047), dark: rgb(0.949, 0.745, 0.294))
    package static let t3ErrorText            = adaptive(light: rgb(0.831, 0.220, 0.220), dark: rgb(0.949, 0.427, 0.427))
    package static let t3ErrorPillBg          = adaptive(light: rgb(0.831, 0.220, 0.220, 0.10), dark: rgb(0.949, 0.427, 0.427, 0.16))

    // Watercolor Mascot Stage (Harmonized with Obsidian Dark & Warm Paper Light)
    package static let t3MascotStageBg        = adaptive(light: rgb(0.957, 0.937, 0.898), dark: rgb(0.106, 0.114, 0.133))
    package static let t3MascotStageLine      = adaptive(light: rgb(0.800, 0.769, 0.714), dark: rgb(0.220, 0.243, 0.286))
}

// MARK: - Unified macOS Typography Scale (SF Pro + PingFang SC Calibrated)
package enum ChrysaFont {
    package static let pageTitle       = Font.system(size: 22, weight: .semibold)
    package static let sheetTitle      = Font.system(size: 15, weight: .semibold)
    package static let rowTitle        = Font.system(size: 13.5, weight: .regular)
    package static let rowTitleActive  = Font.system(size: 13.5, weight: .medium)
    package static let sectionTitle    = Font.system(size: 13, weight: .semibold)
    package static let navItem         = Font.system(size: 13, weight: .regular)
    package static let navItemActive   = Font.system(size: 13, weight: .medium)
    package static let settingLabel    = Font.system(size: 13, weight: .regular)
    package static let input           = Font.system(size: 12.5, weight: .regular)
    package static let control         = Font.system(size: 12, weight: .medium)
    package static let controlSemibold = Font.system(size: 12, weight: .semibold)
    package static let sectionHeader   = Font.system(size: 11.5, weight: .semibold)
    package static let caption         = Font.system(size: 11.5, weight: .regular)
    package static let captionMedium   = Font.system(size: 11.5, weight: .medium)
    package static let helper          = Font.system(size: 11, weight: .regular)
    package static let badge           = Font.system(size: 11, weight: .medium)
    package static let mono            = Font.system(size: 12, design: .monospaced)
    package static let monoSmall       = Font.system(size: 11, design: .monospaced)
}

// MARK: - Base-4 / Base-8 Shared Alignment Grid, Corner Radius & Box Height Tokens
package enum ChrysaMetrics {
    package static let sidebarWidth: CGFloat = 196
    package static let canvasInset: CGFloat = 32
    package static let rowOuterInset: CGFloat = 32
    package static let rowInnerInset: CGFloat = 12
    package static let settingsMaxWidth: CGFloat = 660

    // Unified 4-Tier Pure-Flat Corner Radius Scale
    package static let radiusCard: CGFloat = 10
    package static let radiusControl: CGFloat = 8
    package static let radiusSmall: CGFloat = 6
    package static let radiusMicro: CGFloat = 4

    // Unified Box & Row Heights
    package static let showcaseCardHeight: CGFloat = 72
    package static let settingRowHeight: CGFloat = 48
    package static let listRowHeight: CGFloat = 38
    package static let bottomBarHeight: CGFloat = 38
    package static let topBoxHeight: CGFloat = 36
    package static let sheetFieldHeight: CGFloat = 32
    package static let navRowHeight: CGFloat = 30
    package static let controlHeight: CGFloat = 28
}

extension AppearanceMode {
    package var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    package var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
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

// MARK: - Resolved Icon & Accent Theme (Obsidian Dark & Architectural Light)
package struct AppThemePalette: Equatable, Sendable {
    package let mode: AccentColorMode
    package let swatch: AccentSwatch
    package let selectedIconID: String
    package let isDark: Bool
    package let accent: Color
    package let accentForeground: Color
    package let iconActive: Color
    package let iconInactive: Color
    package let logoAccent: Color
    package let logoColorTitle: String

    package var activeAccentTitle: String {
        switch mode {
        case .monochrome:
            return "纯色墨韵"
        case .followAppIcon:
            return "跟随图标 · \(logoColorTitle)"
        case .custom:
            return swatch.displayName
        }
    }

    package static let `default` = resolve(settings: .default, colorScheme: .light)

    package static func resolve(settings: AppSettings, colorScheme: ColorScheme = .light) -> AppThemePalette {
        resolve(
            mode: settings.accentColorMode,
            selectedIconID: settings.selectedIconID,
            swatch: settings.accentSwatch,
            colorScheme: colorScheme
        )
    }

    package static func resolve(
        mode: AccentColorMode,
        selectedIconID: String,
        swatch: AccentSwatch = .cobalt,
        colorScheme: ColorScheme = .light
    ) -> AppThemePalette {
        let isDark = (colorScheme == .dark)
        let spec = logoThemeSpec(for: selectedIconID)
        let resolvedLogoColor = isDark ? spec.dark : spec.light

        switch mode {
        case .monochrome:
            if isDark {
                let darkInkAccent = Color(red: 0.855, green: 0.871, blue: 0.898) // #DADEe5 calm porcelain
                return AppThemePalette(
                    mode: .monochrome,
                    swatch: swatch,
                    selectedIconID: selectedIconID,
                    isDark: true,
                    accent: darkInkAccent,
                    accentForeground: Color(red: 0.067, green: 0.071, blue: 0.086),
                    iconActive: Color(red: 0.933, green: 0.941, blue: 0.957),
                    iconInactive: Color(red: 0.569, green: 0.596, blue: 0.651),
                    logoAccent: resolvedLogoColor,
                    logoColorTitle: spec.name
                )
            } else {
                let lightInkAccent = Color(red: 0.102, green: 0.114, blue: 0.133) // #1A1D22
                return AppThemePalette(
                    mode: .monochrome,
                    swatch: swatch,
                    selectedIconID: selectedIconID,
                    isDark: false,
                    accent: lightInkAccent,
                    accentForeground: .white,
                    iconActive: lightInkAccent,
                    iconInactive: Color(red: 0.290, green: 0.314, blue: 0.353),
                    logoAccent: resolvedLogoColor,
                    logoColorTitle: spec.name
                )
            }
        case .followAppIcon:
            return AppThemePalette(
                mode: .followAppIcon,
                swatch: swatch,
                selectedIconID: selectedIconID,
                isDark: isDark,
                accent: resolvedLogoColor,
                accentForeground: .white,
                iconActive: resolvedLogoColor,
                iconInactive: resolvedLogoColor.opacity(isDark ? 0.82 : 0.78),
                logoAccent: resolvedLogoColor,
                logoColorTitle: spec.name
            )
        case .custom:
            let col = swatchColor(for: swatch, colorScheme: colorScheme)
            return AppThemePalette(
                mode: .custom,
                swatch: swatch,
                selectedIconID: selectedIconID,
                isDark: isDark,
                accent: col,
                accentForeground: .white,
                iconActive: col,
                iconInactive: col.opacity(isDark ? 0.82 : 0.78),
                logoAccent: resolvedLogoColor,
                logoColorTitle: spec.name
            )
        }
    }

    package static func swatchColor(for swatch: AccentSwatch, colorScheme: ColorScheme = .light) -> Color {
        let isDark = (colorScheme == .dark)
        switch swatch {
        case .cobalt:
            return isDark ? Color(red: 0.298, green: 0.565, blue: 0.969) : Color(red: 0.149, green: 0.443, blue: 0.922) // #4C90F7 / #2671EB
        case .emerald:
            return isDark ? Color(red: 0.239, green: 0.761, blue: 0.576) : Color(red: 0.110, green: 0.588, blue: 0.431) // #3DC293 / #1C966E
        case .amber:
            return isDark ? Color(red: 0.929, green: 0.690, blue: 0.247) : Color(red: 0.820, green: 0.549, blue: 0.086) // #EDB03F / #D18C16
        case .rose:
            return isDark ? Color(red: 0.902, green: 0.427, blue: 0.541) : Color(red: 0.788, green: 0.267, blue: 0.392) // #E66D8A / #C94464
        case .violet:
            return isDark ? Color(red: 0.608, green: 0.510, blue: 0.969) : Color(red: 0.451, green: 0.341, blue: 0.859) // #9B82F7 / #7357DB
        }
    }

    package static func logoAccentColor(for iconID: String, colorScheme: ColorScheme = .light) -> Color {
        let spec = logoThemeSpec(for: iconID)
        return colorScheme == .dark ? spec.dark : spec.light
    }

    private static func logoThemeSpec(for iconID: String) -> (light: Color, dark: Color, name: String) {
        switch iconID {
        case "cultured_prussian":
            return (
                Color(red: 0.192, green: 0.286, blue: 0.510),
                Color(red: 0.424, green: 0.576, blue: 0.910),
                "学院普鲁士蓝"
            )
        case "nordic_sage":
            return (
                Color(red: 0.180, green: 0.337, blue: 0.298),
                Color(red: 0.353, green: 0.722, blue: 0.624),
                "北欧冷杉绿"
            )
        case "w6_burgundy":
            return (
                Color(red: 0.498, green: 0.176, blue: 0.235),
                Color(red: 0.851, green: 0.408, blue: 0.490),
                "勃艮第酒红"
            )
        case "dark_nebula":
            return (
                Color(red: 0.180, green: 0.502, blue: 0.702),
                Color(red: 0.345, green: 0.698, blue: 0.902),
                "星云电光青"
            )
        case "dark_terracotta_gold":
            return (
                Color(red: 0.682, green: 0.392, blue: 0.204),
                Color(red: 0.875, green: 0.573, blue: 0.357),
                "干邑赤陶金"
            )
        case "dark_emerald_mint":
            return (
                Color(red: 0.114, green: 0.510, blue: 0.420),
                Color(red: 0.259, green: 0.769, blue: 0.643),
                "极光翡翠绿"
            )
        default:
            return (
                Color(red: 0.180, green: 0.502, blue: 0.702),
                Color(red: 0.345, green: 0.698, blue: 0.902),
                "星云电光青"
            )
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
