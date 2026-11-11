import SwiftUI
import AppKit

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            if !inMemoryOnly && settings != oldValue {
                persistToDisk()
            }
        }
    }

    private let inMemoryOnly: Bool
    private let fileURL: URL

    let iconOptions: [AppIconOption] = [
        AppIconOption(id: "cultured_prussian",    title: "白底 3 · 学院普鲁士蓝",   subtitle: "雾银浅蓝 ➔ 学院钴蓝 ➔ 普鲁士皇家深蓝", category: "白瓷底系列"),
        AppIconOption(id: "nordic_sage",          title: "白底 4 · 北欧莫兰迪冷杉", subtitle: "鼠尾草灰绿 ➔ 莫兰迪青松 ➔ 北欧深冷杉墨绿", category: "白瓷底系列"),
        AppIconOption(id: "w6_burgundy",          title: "白底 6A · 暖砂陶土与勃艮第", subtitle: "香槟暖砂 ➔ 赤陶红棕 ➔ 陈年勃艮第酒红棕", category: "白瓷底系列"),
        AppIconOption(id: "dark_nebula",          title: "黑底 1 · 曜石星云紫青",   subtitle: "深空曜石 + 暮光紫 ➔ 电光冰蓝 ➔ 纯白雪光", category: "曜石黑底系列"),
        AppIconOption(id: "dark_terracotta_gold", title: "黑底 2 · 曜石黑金与赤陶", subtitle: "暖曜石黑 + 赤陶红棕 ➔ 干邑流金 ➔ 暖香槟钛白", category: "曜石黑底系列"),
        AppIconOption(id: "dark_emerald_mint",    title: "黑底 3 · 曜石极光翡翠",   subtitle: "深空曜石 + 北欧冷杉绿 ➔ 极光薄荷青 ➔ 冰川纯白", category: "曜石黑底系列")
    ]

    init(inMemoryOnly: Bool = false, customFileURL: URL? = nil) {
        self.inMemoryOnly = inMemoryOnly
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: ("~/Library/Application Support" as NSString).expandingTildeInPath)
        let dir = appSupport.appendingPathComponent("Chrysa", isDirectory: true)
        self.fileURL = customFileURL ?? dir.appendingPathComponent("settings.json")

        if inMemoryOnly {
            self.settings = .default
            return
        }

        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            var migrated = AppSettings.default
            let defaults = UserDefaults.standard
            if let pwds = defaults.stringArray(forKey: "Chrysa.PasswordDictionary.v1")
                ?? defaults.stringArray(forKey: "SteamFlow.PasswordDictionary.v1"),
               !pwds.isEmpty {
                migrated.passwords = pwds
            }
            if let iconID = defaults.string(forKey: "Chrysa.SelectedIconID.v1")
                ?? defaults.string(forKey: "SteamFlow.SelectedIconID.v1"),
               iconOptions.contains(where: { $0.id == iconID }) {
                migrated.selectedIconID = iconID
            }
            if let variant = defaults.string(forKey: "Chrysa.SelectedIconVariant.v1")
                ?? defaults.string(forKey: "SteamFlow.SelectedIconVariant.v1"),
               (variant == "A" || variant == "B") {
                migrated.selectedIconVariant = variant
            }
            self.settings = migrated
            persistToDisk()
        }
    }

    private func persistToDisk() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) {
            try? data.write(to: fileURL, options: .atomic)
        }
        // Keep legacy UserDefaults password key synced for convenience
        UserDefaults.standard.set(settings.passwords, forKey: "Chrysa.PasswordDictionary.v1")
    }

    func iconPreviewPath(id: String, variant: String) -> String {
        let bundleIcons = (Bundle.main.bundlePath as NSString).appendingPathComponent("Contents/Resources/Icons/\(id)_\(variant).png")
        if FileManager.default.fileExists(atPath: bundleIcons) {
            return bundleIcons
        }
        return ("~/Applications/Chrysa.app/Contents/Resources/Icons/\(id)_\(variant).png" as NSString).expandingTildeInPath
    }

    @discardableResult
    func applyAppIcon(id: String, variant: String) -> AppIconOption? {
        settings.selectedIconID = id
        settings.selectedIconVariant = variant

        guard !inMemoryOnly else {
            return iconOptions.first(where: { $0.id == id })
        }

        let appBundlePath: String = {
            if Bundle.main.bundlePath.hasSuffix(".app") {
                return Bundle.main.bundlePath
            }
            return ("~/Applications/Chrysa.app" as NSString).expandingTildeInPath
        }()

        let icnsPath = (appBundlePath as NSString).appendingPathComponent("Contents/Resources/Icons/\(id)_\(variant).icns")
        let targetAppIconPath = (appBundlePath as NSString).appendingPathComponent("Contents/Resources/AppIcon.icns")

        if FileManager.default.fileExists(atPath: icnsPath),
           let img = NSImage(contentsOfFile: icnsPath) {
            NSApplication.shared.applicationIconImage = img
            try? FileManager.default.removeItem(atPath: targetAppIconPath)
            try? FileManager.default.copyItem(atPath: icnsPath, toPath: targetAppIconPath)
            NSWorkspace.shared.setIcon(img, forFile: appBundlePath, options: [])
            return iconOptions.first(where: { $0.id == id })
        }
        return nil
    }
}
