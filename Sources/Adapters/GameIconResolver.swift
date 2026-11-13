import ChrysaCore
import ChrysaApplication
import CryptoKit
import CoreGraphics
import Foundation
import ImageIO

package actor GameIconResolver {
    package static let shared = GameIconResolver()

    private let cacheDirectory: URL
    private let crossOverAppsDirectory: String
    private let allowNetworkFallback: Bool
    private var memoryCache: [String: Data] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]

    package init(
        cacheDirectory: URL? = nil,
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

    private static func fetchAndNormalize(
        game: LaunchGame,
        crossOverAppsDirectory: String,
        allowNetworkFallback: Bool
    ) async -> Data? {
        // 1. Windows PE .exe resource section (RT_GROUP_ICON / RT_ICON)
        // Ignore installer/redist helpers (e.g. scriptinterpreter.exe) and auto-discover the real game EXE if needed.
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

        // 2. Steam official square community_icon by AppID (or title lookup when missing/480)
        if allowNetworkFallback {
            var effectiveAppID = game.appID?.trimmingCharacters(in: .whitespacesAndNewlines)
            if effectiveAppID == nil || effectiveAppID?.isEmpty == true || effectiveAppID == "480" {
                effectiveAppID = await SteamAppIDLookup.fetch(for: game.title)
            }
            if let appID = effectiveAppID,
               let iconData = await SteamAppIDLookup.fetchCommunityIconData(appID: appID),
               let png = normalizeToSquarePNG(iconData, pixelSize: 64) {
                return png
            }
        }

        // 3. CrossOver helper .app .icns fallback (used when no EXE/Steam icon was obtained)
        if let icnsData = loadCrossOverShortcutIcon(title: game.title, cxAppsDir: crossOverAppsDirectory),
           let png = normalizeToSquarePNG(icnsData, pixelSize: 64) {
            return png
        }

        return nil
    }

    private static func loadCrossOverShortcutIcon(title: String, cxAppsDir: String) -> Data? {
        let fm = FileManager.default
        let appURL = URL(fileURLWithPath: cxAppsDir).appendingPathComponent("\(title).app", isDirectory: true)
        guard fm.fileExists(atPath: appURL.path) else { return nil }
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)

        if let dict = NSDictionary(contentsOf: plistURL) as? [String: Any],
           let iconName = dict["CFBundleIconFile"] as? String, !iconName.isEmpty {
            let fileName = iconName.hasSuffix(".icns") ? iconName : "\(iconName).icns"
            let iconURL = resourcesURL.appendingPathComponent(fileName)
            if let data = try? Data(contentsOf: iconURL), !data.isEmpty {
                return data
            }
        }

        if let files = try? fm.contentsOfDirectory(atPath: resourcesURL.path),
           let icns = files.first(where: { $0.lowercased().hasSuffix(".icns") }) {
            let iconURL = resourcesURL.appendingPathComponent(icns)
            if let data = try? Data(contentsOf: iconURL), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    package static func normalizeToSquarePNG(_ rawData: Data, pixelSize: Int = 64) -> Data? {
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
        guard let cgImage = bestImage else { return nil }

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
        ctx.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))

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
        let appID = game.appID ?? ""
        let normTitle = LaunchGame.normalizedIdentityTitle(game.title)
        let seed = "v2|\(exe)|\(appID)|\(normTitle)|\(game.id.uuidString)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
