import ChrysaCore
import ChrysaApplication
import Foundation

package enum CrossOverBottleScanner {
    /// Dynamically discovers installed CrossOver game bottles & shortcuts without any hardcoded game names.
    package static func scanInstalledBottles(
        bottlesDirectory: String,
        crossOverAppsDirectory: String? = nil,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) -> [Job] {
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

        var discovered: [Job] = []
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

            var foundEXE: String? = nil
            var foundAppID: String? = nil
            if let gDir = gameDir, let enumerator = fm.enumerator(atPath: gDir) {
                while let rel = enumerator.nextObject() as? String {
                    guard !isCancelled() else { return [] }
                    let lower = (rel as NSString).lastPathComponent.lowercased()
                    let full = (gDir as NSString).appendingPathComponent(rel)
                    if lower == "steam_appid.txt", foundAppID == nil {
                        let txt = (try? String(contentsOfFile: full, encoding: .utf8))?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if let t = txt, !t.isEmpty { foundAppID = t }
                    } else if foundEXE == nil, lower.hasSuffix(".exe"),
                              !rel.lowercased().contains("__redist"),
                              !lower.contains("scriptinterpreter"),
                              !lower.contains("unitycrashhandler"),
                              !lower.contains("unins"),
                              !lower.contains("vc_redist"),
                              !lower.contains("crashreport") {
                        foundEXE = full
                    }
                }
            }

            let confPath = (bottlePath as NSString).appendingPathComponent("cxbottle.conf")
            let confText = (try? String(contentsOfFile: confPath, encoding: .utf8)) ?? ""
            let gfxBackend = confText.contains("d3dmetal") ? "D3DMetal" : "DXMT"
            let appIDLabel = foundAppID ?? "已就绪"

            discovered.append(
                Job(
                    kind: .patch,
                    title: displayTitle,
                    status: .succeeded,
                    source: ArtifactRef(kind: .directory, value: gameDir ?? bottlePath),
                    output: foundEXE.map { ArtifactRef(kind: .file, value: $0) },
                    message: "Goldberg x64",
                    rightText: "▶ 启动",
                    appID: foundAppID,
                    expanded: discovered.isEmpty,
                    checklist: [
                        CheckItem(title: "Goldberg 环境 (\(appIDLabel))", isChecked: true),
                        CheckItem(title: "CrossOver 容器 [\(bottle)] (\(gfxBackend) + MSync)", isChecked: true)
                    ]
                )
            )
        }

        return discovered
    }
}
