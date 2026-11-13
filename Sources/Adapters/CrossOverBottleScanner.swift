import ChrysaCore
import ChrysaApplication
import Foundation

package enum CrossOverBottleScanner {
    /// Dynamically discovers installed CrossOver game bottles & shortcuts without any hardcoded game names.
    package static func scanInstalledBottles(
        bottlesDirectory: String,
        crossOverAppsDirectory: String? = nil,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) -> [LaunchGame] {
        let fm = FileManager.default
        let bottlesRoot = (bottlesDirectory as NSString).expandingTildeInPath
        guard !isCancelled(), fm.fileExists(atPath: bottlesRoot) else { return [] }

        // Map bottleName -> helper shortcut display name from ~/Applications/CrossOver/*.app
        var shortcutNameByBottle: [String: String] = [:]
        let cxAppsDir = ((crossOverAppsDirectory ?? "~/Applications/CrossOver") as NSString).expandingTildeInPath
        if let appBundles = try? fm.contentsOfDirectory(atPath: cxAppsDir) {
            for bundleName in appBundles where bundleName.hasSuffix(".app") {
                guard !isCancelled() else { return [] }
                let plistPath = (cxAppsDir as NSString).appendingPathComponent("\(bundleName)/Contents/Info.plist")
                if let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any],
                   let bottleName = dict["CXHelperAppBottleName"] as? String {
                    let displayName = (dict["CFBundleName"] as? String)
                        ?? (bundleName as NSString).deletingPathExtension
                    shortcutNameByBottle[bottleName] = displayName
                }
            }
        }

        let ignoredSystemDirs: Set<String> = [
            "program files", "program files (x86)", "programdata", "users", "windows"
        ]
        let ignoredBottleKeywords = ["steamless"]

        guard let bottleNames = try? fm.contentsOfDirectory(atPath: bottlesRoot).sorted() else {
            return []
        }

        var discovered: [LaunchGame] = []
        for bottle in bottleNames where !bottle.hasPrefix(".") {
            guard !isCancelled() else { return [] }
            if ignoredBottleKeywords.contains(where: { bottle.lowercased().contains($0) }) {
                continue
            }
            let bottlePath = (bottlesRoot as NSString).appendingPathComponent(bottle)
            let driveCPath = (bottlePath as NSString).appendingPathComponent("drive_c")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: driveCPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let displayTitle = shortcutNameByBottle[bottle] ?? bottle
            let shortcutAppPath = (cxAppsDir as NSString).appendingPathComponent("\(displayTitle).app")

            // Locate game directory inside drive_c (including symlinks)
            var gameDir: String? = nil
            if let driveItems = try? fm.contentsOfDirectory(atPath: driveCPath) {
                for item in driveItems where !item.hasPrefix(".") && !ignoredSystemDirs.contains(item.lowercased()) {
                    guard !isCancelled() else { return [] }
                    let candidate = (driveCPath as NSString).appendingPathComponent(item)
                    let resolved = (try? fm.destinationOfSymbolicLink(atPath: candidate)) ?? candidate
                    var subDir: ObjCBool = false
                    if fm.fileExists(atPath: resolved, isDirectory: &subDir), subDir.boolValue {
                        gameDir = resolved
                        break
                    }
                }
            }

            // Skip empty bottles that have neither a game directory nor a CrossOver shortcut .app
            if gameDir == nil && !fm.fileExists(atPath: shortcutAppPath) {
                continue
            }

            var candidateEXEs: [String] = []
            var unityDataDirs: [String] = []
            var foundAppID: String? = nil
            if let gDir = gameDir, let enumerator = fm.enumerator(atPath: gDir) {
                while let rel = enumerator.nextObject() as? String {
                    guard !isCancelled() else { return [] }
                    let relLower = rel.lowercased()
                    let lower = (rel as NSString).lastPathComponent.lowercased()
                    let full = (gDir as NSString).appendingPathComponent(rel)
                    if lower == "steam_appid.txt", foundAppID == nil {
                        let txt = (try? String(contentsOfFile: full, encoding: .utf8))?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if let t = txt, !t.isEmpty { foundAppID = t }
                    } else if lower.hasSuffix("_data") {
                        var dataIsDir: ObjCBool = false
                        if fm.fileExists(atPath: full, isDirectory: &dataIsDir), dataIsDir.boolValue {
                            unityDataDirs.append(full)
                        }
                    } else if lower.hasSuffix(".exe"),
                              !relLower.contains("__redist"),
                              !relLower.contains("/redist/"),
                              !lower.contains("scriptinterpreter"),
                              !lower.contains("unitycrashhandler"),
                              !lower.contains("unins"),
                              !lower.contains("vc_redist"),
                              !lower.contains("dxsetup"),
                              !lower.contains("crashreport"),
                              !lower.contains("crs-handler"),
                              !lower.contains("goggalaxy"),
                              !lower.contains("dosbox"),
                              !lower.hasPrefix("setup_") {
                        candidateEXEs.append(full)
                    }
                }
            }

            var matchedUnityEXE: String? = nil
            for dataDir in unityDataDirs {
                let dirName = (dataDir as NSString).lastPathComponent
                if dirName.lowercased().hasSuffix("_data") {
                    let prefix = String(dirName.dropLast("_data".count))
                    let parent = (dataDir as NSString).deletingLastPathComponent
                    let expectedEXE = (parent as NSString).appendingPathComponent("\(prefix).exe")
                    if fm.fileExists(atPath: expectedEXE) {
                        matchedUnityEXE = expectedEXE
                        break
                    }
                    if let ciMatch = candidateEXEs.first(where: {
                        (($0 as NSString).lastPathComponent as NSString).deletingPathExtension.caseInsensitiveCompare(prefix) == .orderedSame
                    }) {
                        matchedUnityEXE = ciMatch
                        break
                    }
                }
            }

            let foundEXE = matchedUnityEXE ?? candidateEXEs.max { a, b in
                let depthA = a.components(separatedBy: "/").count
                let depthB = b.components(separatedBy: "/").count
                if depthA != depthB {
                    return depthA > depthB
                }
                let sa = (try? fm.attributesOfItem(atPath: a)[.size] as? Int64) ?? 0
                let sb = (try? fm.attributesOfItem(atPath: b)[.size] as? Int64) ?? 0
                return sa < sb
            }

            discovered.append(
                LaunchGame(
                    title: displayTitle,
                    exePath: foundEXE,
                    gameDirectory: gameDir ?? bottlePath,
                    bottleName: bottle,
                    appID: foundAppID,
                    source: .crossoverScan
                )
            )
        }

        return discovered
    }
}
