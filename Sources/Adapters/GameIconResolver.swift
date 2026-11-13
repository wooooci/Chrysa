import AppKit
import ChrysaCore
import ChrysaApplication
import CryptoKit
import CoreGraphics
import Foundation
import ImageIO

package actor GameIconResolver {
    package static let shared = GameIconResolver()

    private let cacheDirectory: URL
    private let customIconsDirectory: URL
    private let crossOverAppsDirectory: String
    private let allowNetworkFallback: Bool
    private var memoryCache: [String: Data] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]

    package init(
        cacheDirectory: URL? = nil,
        customIconsDirectory: URL? = nil,
        crossOverAppsDirectory: String = "~/Applications/CrossOver",
        allowNetworkFallback: Bool = true
    ) {
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: ("~/Library/Caches" as NSString).expandingTildeInPath)
            self.cacheDirectory = caches
                .appendingPathComponent("Chrysa", isDirectory: true)
                .appendingPathComponent("GameIcons", isDirectory: true)
        }
        if let customIconsDirectory {
            self.customIconsDirectory = customIconsDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: ("~/Library/Application Support" as NSString).expandingTildeInPath)
            self.customIconsDirectory = appSupport
                .appendingPathComponent("Chrysa", isDirectory: true)
                .appendingPathComponent("CustomGameIcons", isDirectory: true)
        }
        self.crossOverAppsDirectory = (crossOverAppsDirectory as NSString).expandingTildeInPath
        self.allowNetworkFallback = allowNetworkFallback
    }

    package func resolveIconPNG(for game: LaunchGame) async -> Data? {
        let key = Self.cacheKey(for: game)
        if let cached = memoryCache[key] {
            return cached
        }

        let cacheFile = cacheDirectory.appendingPathComponent("\(key).png")
        if let diskData = try? Data(contentsOf: cacheFile), !diskData.isEmpty {
            memoryCache[key] = diskData
            return diskData
        }

        if let existingTask = inFlight[key] {
            return await existingTask.value
        }

        let cxAppsDir = crossOverAppsDirectory
        let networkAllowed = allowNetworkFallback
        let task = Task<Data?, Never> {
            await Self.fetchAndNormalize(
                game: game,
                crossOverAppsDirectory: cxAppsDir,
                allowNetworkFallback: networkAllowed
            )
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil

        if let png = result {
            memoryCache[key] = png
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? png.write(to: cacheFile, options: [.atomic])
        }
        return result
    }

    package func invalidateCache(for game: LaunchGame) {
        let key = Self.cacheKey(for: game)
        memoryCache.removeValue(forKey: key)
        let cacheFile = cacheDirectory.appendingPathComponent("\(key).png")
        try? FileManager.default.removeItem(at: cacheFile)
    }

    package func saveCustomIcon(from sourceURL: URL, for gameID: UUID) -> String? {
        let ext = sourceURL.pathExtension.lowercased()
        let rawData: Data?
        let cropToFill: Bool
        if ext == "app" {
            rawData = Self.loadAppBundleIcon(at: sourceURL.path)
            cropToFill = false
        } else if ext == "exe" {
            rawData = PEBinaryInspector.extractIconData(exePath: sourceURL.path)
            cropToFill = false
        } else if ext == "icns" || ext == "ico" {
            rawData = try? Data(contentsOf: sourceURL)
            cropToFill = false
        } else {
            rawData = (try? Data(contentsOf: sourceURL)) ?? NSImage(contentsOf: sourceURL)?.tiffRepresentation
            cropToFill = true
        }

        guard let rawData,
              let png = Self.normalizeToSquarePNG(rawData, pixelSize: 128, cropToFill: cropToFill) else {
            return nil
        }

        do {
            try FileManager.default.createDirectory(at: customIconsDirectory, withIntermediateDirectories: true)
            let suffix = UUID().uuidString.prefix(8)
            let destURL = customIconsDirectory.appendingPathComponent("\(gameID.uuidString)-\(suffix).png")
            try png.write(to: destURL, options: [.atomic])
            return destURL.path
        } catch {
            return nil
        }
    }

    package func removeCustomIcon(at path: String?) {
        guard let path, !path.isEmpty else { return }
        let canonicalRoot = LaunchGame.canonicalPath(customIconsDirectory.path) ?? customIconsDirectory.path
        let canonicalTarget = LaunchGame.canonicalPath(path) ?? path
        guard canonicalTarget.hasPrefix(canonicalRoot + "/") else { return }
        try? FileManager.default.removeItem(atPath: canonicalTarget)
    }

    private static func fetchAndNormalize(
        game: LaunchGame,
        crossOverAppsDirectory: String,
        allowNetworkFallback: Bool
    ) async -> Data? {
        func resolveCustomIcon() -> Data? {
            guard let path = game.customIconPath,
                  !path.isEmpty,
                  FileManager.default.fileExists(atPath: path) else {
                return nil
            }
            let ext = (path as NSString).pathExtension.lowercased()
            if ext == "app" {
                return loadAppBundleIcon(at: path).flatMap { normalizeToSquarePNG($0, pixelSize: 64) }
            } else if ext == "exe" {
                return PEBinaryInspector.extractIconData(exePath: path).flatMap { normalizeToSquarePNG($0, pixelSize: 64) }
            } else if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                return normalizeToSquarePNG(data, pixelSize: 64, cropToFill: ext != "icns" && ext != "ico")
            }
            return nil
        }

        func resolveExecutableOrLocalAppIcon() -> Data? {
            let candidateEXE: String? = {
                if let exe = game.exePath,
                   !LaunchGame.isIgnoredHelperExecutable(exe),
                   FileManager.default.fileExists(atPath: exe) {
                    return exe
                }
                if let dir = game.gameDirectory {
                    return CrossOverBottleScanner.findMainExecutable(in: dir)
                }
                return nil
            }()
            if let exePath = candidateEXE,
               let rawIcon = PEBinaryInspector.extractIconData(exePath: exePath),
               let png = normalizeToSquarePNG(rawIcon, pixelSize: 64) {
                return png
            }

            if let dir = game.gameDirectory,
               (dir as NSString).pathExtension.lowercased() == "app",
               !isCrossOverHelperApp(at: dir, cxAppsDir: crossOverAppsDirectory),
               let appIconData = loadAppBundleIcon(at: dir),
               let png = normalizeToSquarePNG(appIconData, pixelSize: 64) {
                return png
            }
            return nil
        }

        func resolveSteamIcon() async -> Data? {
            guard allowNetworkFallback else { return nil }
            var effectiveAppID = game.appID?.trimmingCharacters(in: .whitespacesAndNewlines)
            if effectiveAppID == nil || effectiveAppID?.isEmpty == true || effectiveAppID == "480" {
                effectiveAppID = await SteamAppIDLookup.fetch(for: game.title)
            }
            if let appID = effectiveAppID,
               let asset = await SteamAppIDLookup.fetchIconAsset(appID: appID),
               let png = normalizeToSquarePNG(asset.data, pixelSize: 64, cropToFill: !asset.isSquare) {
                return png
            }
            return nil
        }

        func resolveCrossOverIcon() -> Data? {
            guard let icnsData = loadCrossOverShortcutIcon(
                title: game.title,
                bottleName: game.bottleName,
                cxAppsDir: crossOverAppsDirectory
            ) else {
                return nil
            }
            return normalizeToSquarePNG(icnsData, pixelSize: 64)
        }

        switch game.iconPreference {
        case .custom:
            if let png = resolveCustomIcon() { return png }
            if let png = resolveExecutableOrLocalAppIcon() { return png }
            if let png = await resolveSteamIcon() { return png }
            return resolveCrossOverIcon()

        case .steam:
            if let png = await resolveSteamIcon() { return png }
            if let png = resolveCustomIcon() { return png }
            if let png = resolveExecutableOrLocalAppIcon() { return png }
            return resolveCrossOverIcon()

        case .executable:
            if let png = resolveExecutableOrLocalAppIcon() { return png }
            if let png = resolveCrossOverIcon() { return png }
            return await resolveSteamIcon()

        case .automatic:
            if let png = resolveCustomIcon() { return png }
            if let png = resolveExecutableOrLocalAppIcon() { return png }
            if let png = await resolveSteamIcon() { return png }
            return resolveCrossOverIcon()
        }
    }

    private static func isCrossOverHelperApp(at appPath: String, cxAppsDir: String) -> Bool {
        let canonicalApp = LaunchGame.canonicalPath(appPath) ?? appPath
        let canonicalCX = LaunchGame.canonicalPath(cxAppsDir) ?? cxAppsDir
        if canonicalApp.hasPrefix(canonicalCX + "/") {
            return true
        }
        let plistPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        if let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any],
           dict["CXHelperAppBottleName"] != nil {
            return true
        }
        return false
    }

    private static func loadCrossOverShortcutIcon(title: String, bottleName: String?, cxAppsDir: String) -> Data? {
        let fm = FileManager.default
        let directAppURL = URL(fileURLWithPath: cxAppsDir).appendingPathComponent("\(title).app", isDirectory: true)
        if fm.fileExists(atPath: directAppURL.path),
           let data = loadAppBundleIcon(at: directAppURL.path, allowWorkspaceFallback: false) {
            return data
        }

        let normBottle = bottleName.map { LaunchGame.normalizedIdentityTitle($0) }
        let normTitle = LaunchGame.normalizedIdentityTitle(title)
        if let bundles = try? fm.contentsOfDirectory(atPath: cxAppsDir) {
            for bundle in bundles where bundle.hasSuffix(".app") {
                let appURL = URL(fileURLWithPath: cxAppsDir).appendingPathComponent(bundle, isDirectory: true)
                let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
                guard let dict = NSDictionary(contentsOfFile: plistURL.path) as? [String: Any] else { continue }
                let cxBottle = (dict["CXHelperAppBottleName"] as? String).map { LaunchGame.normalizedIdentityTitle($0) }
                let bundleTitle = LaunchGame.normalizedIdentityTitle(
                    (dict["CFBundleName"] as? String) ?? (bundle as NSString).deletingPathExtension
                )
                let bottleMatched = (normBottle != nil && !normBottle!.isEmpty && cxBottle == normBottle)
                let titleMatched = (!normTitle.isEmpty && bundleTitle == normTitle)
                if bottleMatched || titleMatched,
                   let data = loadAppBundleIcon(at: appURL.path, allowWorkspaceFallback: false) {
                    return data
                }
            }
        }
        return nil
    }

    package static func loadAppBundleIcon(at appPath: String, allowWorkspaceFallback: Bool = true) -> Data? {
        let fm = FileManager.default
        let appURL = URL(fileURLWithPath: appPath, isDirectory: true)
        guard fm.fileExists(atPath: appURL.path) else { return nil }
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)

        if let dict = NSDictionary(contentsOf: plistURL) as? [String: Any] {
            for key in ["CFBundleIconFile", "CFBundleIconName"] {
                if let iconName = dict[key] as? String, !iconName.isEmpty {
                    let candidates = iconName.lowercased().hasSuffix(".icns")
                        ? [iconName]
                        : [iconName, "\(iconName).icns"]
                    for candidate in candidates {
                        let iconURL = resourcesURL.appendingPathComponent(candidate)
                        if let data = try? Data(contentsOf: iconURL), !data.isEmpty {
                            return data
                        }
                    }
                }
            }
        }

        if let files = try? fm.contentsOfDirectory(atPath: resourcesURL.path),
           let icns = files.sorted().first(where: { $0.lowercased().hasSuffix(".icns") }) {
            let iconURL = resourcesURL.appendingPathComponent(icns)
            if let data = try? Data(contentsOf: iconURL), !data.isEmpty {
                return data
            }
        }

        if allowWorkspaceFallback {
            let image = NSWorkspace.shared.icon(forFile: appURL.path)
            if let tiff = image.tiffRepresentation, !tiff.isEmpty {
                return tiff
            }
        }
        return nil
    }

    package static func normalizeToSquarePNG(_ rawData: Data, pixelSize: Int = 64, cropToFill: Bool = false) -> Data? {
        guard let source = CGImageSourceCreateWithData(rawData as CFData, nil) else {
            return nil
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        // Pick the image frame closest to (and >=) target pixelSize, or largest available.
        var bestImage: CGImage?
        var bestScore = Int.min
        for idx in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, idx, nil) else { continue }
            let dim = max(cg.width, cg.height)
            let score = (dim >= pixelSize) ? (10_000 - dim) : dim
            if score > bestScore {
                bestScore = score
                bestImage = cg
            }
        }
        guard let cgImage = bestImage, cgImage.width > 0, cgImage.height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        let target = CGFloat(pixelSize)
        let srcW = CGFloat(cgImage.width)
        let srcH = CGFloat(cgImage.height)
        let scale = cropToFill ? max(target / srcW, target / srcH) : min(target / srcW, target / srcH)
        let drawW = srcW * scale
        let drawH = srcH * scale
        let drawRect = CGRect(
            x: (target - drawW) / 2,
            y: (target - drawH) / 2,
            width: drawW,
            height: drawH
        )
        ctx.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        ctx.draw(cgImage, in: drawRect)

        guard let scaled = ctx.makeImage() else { return nil }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData,
            "public.png" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(dest, scaled, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    package static func cacheKey(for game: LaunchGame) -> String {
        let exe = LaunchGame.canonicalPath(game.exePath) ?? ""
        let dir = LaunchGame.canonicalPath(game.gameDirectory) ?? ""
        let appID = game.appID ?? ""
        let normTitle = LaunchGame.normalizedIdentityTitle(game.title)
        let pref = game.iconPreference.rawValue
        let custom = LaunchGame.canonicalPath(game.customIconPath) ?? ""
        let bottle = game.bottleName ?? ""
        let seed = "v3|\(exe)|\(dir)|\(appID)|\(normTitle)|\(pref)|\(custom)|\(bottle)|\(game.id.uuidString)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
