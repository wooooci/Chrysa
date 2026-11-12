import ChrysaCore
import ChrysaApplication
import SwiftUI
import AppKit

private struct SettingsEnvelope: Codable {
    package let schemaVersion: Int
    package let payload: AppSettings
}

@MainActor
package final class AppSettingsStore: ObservableObject {
    private static let schemaVersion = 1
    @Published package var settings: AppSettings {
        didSet {
            if !inMemoryOnly && settings != oldValue {
                persistToDisk()
            }
        }
    }

    private let inMemoryOnly: Bool
    private let fileURL: URL
    private var preserveUnsupportedFile = false

    package let iconOptions: [AppIconOption] = [
        AppIconOption(id: "cultured_prussian",    title: "白底 3 · 学院普鲁士蓝",   subtitle: "雾银浅蓝 ➔ 学院钴蓝 ➔ 普鲁士皇家深蓝", category: "白瓷底系列"),
        AppIconOption(id: "nordic_sage",          title: "白底 4 · 北欧莫兰迪冷杉", subtitle: "鼠尾草灰绿 ➔ 莫兰迪青松 ➔ 北欧深冷杉墨绿", category: "白瓷底系列"),
        AppIconOption(id: "w6_burgundy",          title: "白底 6A · 暖砂陶土与勃艮第", subtitle: "香槟暖砂 ➔ 赤陶红棕 ➔ 陈年勃艮第酒红棕", category: "白瓷底系列"),
        AppIconOption(id: "dark_nebula",          title: "黑底 1 · 曜石星云紫青",   subtitle: "深空曜石 + 暮光紫 ➔ 电光冰蓝 ➔ 纯白雪光", category: "曜石黑底系列"),
        AppIconOption(id: "dark_terracotta_gold", title: "黑底 2 · 曜石黑金与赤陶", subtitle: "暖曜石黑 + 赤陶红棕 ➔ 干邑流金 ➔ 暖香槟钛白", category: "曜石黑底系列"),
        AppIconOption(id: "dark_emerald_mint",    title: "黑底 3 · 曜石极光翡翠",   subtitle: "深空曜石 + 北欧冷杉绿 ➔ 极光薄荷青 ➔ 冰川纯白", category: "曜石黑底系列")
    ]

    package init(inMemoryOnly: Bool = false, customFileURL: URL? = nil) {
        self.inMemoryOnly = inMemoryOnly
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: ("~/Library/Application Support" as NSString).expandingTildeInPath)
        let dir = appSupport.appendingPathComponent("Chrysa", isDirectory: true)
        self.fileURL = customFileURL ?? dir.appendingPathComponent("settings.json")

        if inMemoryOnly {
            self.settings = .default
            return
        }

        if let data = try? Data(contentsOf: self.fileURL) {
            if Self.hasUnsupportedSchema(data) {
                self.preserveUnsupportedFile = true
                self.settings = .default
                print("[persistence] settings schema is newer than this app; file left untouched: \(self.fileURL.path)")
                return
            }
            if let decoded = Self.decodeSettings(data) {
                self.preserveUnsupportedFile = false
                self.settings = decoded
                return
            }
            Self.preserveCorruptFile(at: self.fileURL)
            if let backup = Self.readBackup(for: self.fileURL),
               let decoded = Self.decodeSettings(backup) {
                self.settings = decoded
                print("[persistence] restored settings from backup: \(self.fileURL.path).bak")
                return
            }
            print("[persistence] settings file is corrupt; defaults will be used: \(self.fileURL.path)")
        }

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

    private static func hasUnsupportedSchema(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? Int else { return false }
        return version > schemaVersion
    }

    private static func decodeSettings(_ data: Data) -> AppSettings? {
        let decoder = JSONDecoder()
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["schemaVersion"] != nil {
            guard let envelope = try? decoder.decode(SettingsEnvelope.self, from: data),
                  envelope.schemaVersion > 0,
                  envelope.schemaVersion <= schemaVersion else { return nil }
            return envelope.payload
        }
        // Existing installations contain the unwrapped AppSettings payload.
        return try? decoder.decode(AppSettings.self, from: data)
    }

    private static func readBackup(for url: URL) -> Data? {
        try? Data(contentsOf: url.appendingPathExtension("bak"))
    }

    private static func preserveCorruptFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var target = url.appendingPathExtension("corrupt")
        if FileManager.default.fileExists(atPath: target.path) {
            target = url.appendingPathExtension("corrupt-\(UUID().uuidString)")
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            print("[persistence] preserved corrupt settings file: \(target.path)")
        } catch {
            print("[persistence] failed to preserve corrupt settings file: \(error.localizedDescription)")
        }
    }

    private func persistToDisk() {
        guard !preserveUnsupportedFile else {
            print("[persistence] skipped settings save because the file belongs to a newer schema: \(fileURL.path)")
            return
        }
        let dir = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(SettingsEnvelope(schemaVersion: Self.schemaVersion, payload: settings))
            let backupURL = fileURL.appendingPathExtension("bak")
            if let existingData = try? Data(contentsOf: fileURL) {
                try existingData.write(to: backupURL, options: [.atomic])
            }
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            print("[persistence] failed to save settings: \(error.localizedDescription)")
        }
        // Keep legacy UserDefaults password key synced for convenience
        UserDefaults.standard.set(settings.passwords, forKey: "Chrysa.PasswordDictionary.v1")
    }

    package func iconPreviewPath(id: String, variant: String) -> String {
        let bundleIcons = (Bundle.main.bundlePath as NSString).appendingPathComponent("Contents/Resources/Icons/\(id)_\(variant).png")
        if FileManager.default.fileExists(atPath: bundleIcons) {
            return bundleIcons
        }
        return ("~/Applications/Chrysa.app/Contents/Resources/Icons/\(id)_\(variant).png" as NSString).expandingTildeInPath
    }

    @discardableResult
    package func applyAppIcon(id: String, variant: String) -> AppIconOption? {
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
        if FileManager.default.fileExists(atPath: icnsPath),
           let img = NSImage(contentsOfFile: icnsPath) {
            // Keep the saved selection in the Dock without modifying the signed bundle.
            NSApplication.shared.applicationIconImage = img
            return iconOptions.first(where: { $0.id == id })
        }
        return nil
    }
}
