import ChrysaApplication
import ChrysaCore
import Foundation

package enum LaunchGameUninstaller {
    package enum BottleSafetyClassification: Equatable, Sendable {
        case dedicated(name: String, path: String)
        case shared(name: String, path: String, reason: String)
    }

    private static let reservedSharedBottleNames: Set<String> = [
        "steam", "default", "epic", "epic games", "gog", "gog galaxy",
        "ubisoft", "ubisoft connect", "uplay", "battle.net", "battlenet",
        "ea", "ea app", "origin", "shared", "common"
    ]

    private static let windowsSystemTopLevelDirs: Set<String> = [
        "windows", "users", "program files", "program files (x86)", "programdata", "crossover"
    ]

    private static let programFilesSystemDirs: Set<String> = [
        "common files", "internet explorer", "windows mail", "windows media player",
        "windows nt", "windows photo viewer", "windows portable devices", "windows sidebar",
        "windowsapps", "uninstall information", "reference assemblies", "msbuild",
        "steamworks shared", "directx", "microsoft", "microsoft.net",
        "vulkanrt", "nvidia corporation", "amd", "openal"
    ]

    private static let driveCSpecialDirectoryNames: Set<String> = [
        "drive_c", "program files", "program files (x86)", "programdata",
        "users", "windows", "steamapps", "common", "crossover"
    ]

    private static let utilityShortcutKeywords: [String] = [
        "uninstall", "uninst", "readme", "manual", "changelog", "license",
        "help", "support", "website", "homepage", "config", "setup",
        "settings", "wine", "command prompt", "notepad", "wordpad",
        "internet explorer", "directx", "vcredist", "physx"
    ]

    package static func uninstall(
        game: LaunchGame,
        knownGames: [LaunchGame],
        settings: AppSettings,
        crossOverAppsDirectory: String = "~/Applications/CrossOver",
        trashHandler: (URL) throws -> URL? = defaultTrashItem,
        wineTerminator: ((String) -> Void)? = nil
    ) -> LaunchGameUninstallOutcome {
        let fm = FileManager.default
        let expandedBottlesRoot = (settings.bottlesDirectory as NSString).expandingTildeInPath
        let expandedCXAppsRoot = (crossOverAppsDirectory as NSString).expandingTildeInPath
        let expandedDownloadRoot = (settings.downloadDirectory as NSString).expandingTildeInPath

        var trashedPaths: [String] = []
        var skippedProtectedPaths: [String] = []
        var warnings: [String] = []
        var terminatedBottleName: String? = nil

        let canonicalBottlesRoot = try? PathSafety.existingCanonicalDirectory(expandedBottlesRoot)

        // 1. Evaluate associated CrossOver bottle first (dedicated vs shared)
        var dedicatedBottle: (name: String, path: String)? = nil
        if let candidateBottle = CrossOverRegistryHelper.resolveExistingBottle(
            explicitBottleName: game.bottleName,
            gameTitle: game.title,
            exePath: game.exePath,
            bottlesDirectory: settings.bottlesDirectory
        ) {
            let bottleURL = URL(fileURLWithPath: candidateBottle.path, isDirectory: true).standardizedFileURL
            if let canonicalBottlesRoot,
               let canonicalBottle = try? PathSafety.existingCanonicalDirectory(bottleURL.path),
               let containedBottle = PathSafety.containedURL(canonicalBottle, in: canonicalBottlesRoot),
               containedBottle.path != canonicalBottlesRoot.path,
               containedBottle.deletingLastPathComponent().path == canonicalBottlesRoot.path {
                let classification = classifyBottleSafety(
                    bottleName: containedBottle.lastPathComponent,
                    bottlePath: containedBottle.path,
                    for: game,
                    knownGames: knownGames,
                    crossOverAppsDirectory: expandedCXAppsRoot
                )
                switch classification {
                case .dedicated(let name, let path):
                    dedicatedBottle = (name, path)
                case .shared(let name, let path, let reason):
                    skippedProtectedPaths.append(path)
                    warnings.append("已保留共享容器 [\(name)]: \(reason)")
                }
            }
        }

        // 2. Validate external game directory
        var externalGameDirURL: URL? = nil
        if let rawGameDir = game.gameDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawGameDir.isEmpty {
            let rawExpanded = (rawGameDir as NSString).expandingTildeInPath
            let rawURL = URL(fileURLWithPath: rawExpanded).standardizedFileURL
            let rawAttrs = try? rawURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if rawAttrs?.isSymbolicLink == true {
                skippedProtectedPaths.append(rawURL.path)
                warnings.append("已跳过符号链接目录，防止误删链接目标: \(rawURL.lastPathComponent)")
            } else if let canonicalGameDir = try? PathSafety.existingCanonicalDirectory(rawURL.path) {
                let additionalProtected = [expandedBottlesRoot, expandedCXAppsRoot, expandedDownloadRoot]
                let isBottlesDirectChild = canonicalBottlesRoot.map {
                    canonicalGameDir.deletingLastPathComponent().path == $0.path
                        || canonicalGameDir.path == $0.path
                } ?? false
                let livesInsideDedicatedBottle = dedicatedBottle.map {
                    let prefix = $0.path.hasSuffix("/") ? $0.path : $0.path + "/"
                    return canonicalGameDir.path == $0.path || canonicalGameDir.path.hasPrefix(prefix)
                } ?? false
                let sharesOrContainsOtherGame = knownGames.contains { other in
                    guard other.id != game.id else { return false }
                    if let otherDir = LaunchGame.canonicalPath(other.gameDirectory),
                       otherDir == canonicalGameDir.path || otherDir.hasPrefix(canonicalGameDir.path + "/") {
                        return true
                    }
                    if let otherExe = LaunchGame.canonicalPath(other.exePath),
                       otherExe.hasPrefix(canonicalGameDir.path + "/") {
                        return true
                    }
                    return false
                }

                if livesInsideDedicatedBottle {
                    // Dedicated bottle deletion below will remove the bottle and everything inside drive_c cleanly.
                } else if isProtectedSystemOrRootDirectory(canonicalGameDir.path, additionalProtectedRoots: additionalProtected)
                    || isBottlesDirectChild
                    || isProtectedDriveCSubdirectory(canonicalGameDir, bottlesRoot: canonicalBottlesRoot) {
                    skippedProtectedPaths.append(canonicalGameDir.path)
                    warnings.append("安全护栏已拦截受保护目录: \(canonicalGameDir.path)")
                } else if sharesOrContainsOtherGame {
                    skippedProtectedPaths.append(canonicalGameDir.path)
                    warnings.append("目录仍包含启动库中的其他游戏，已跳过删除: \(canonicalGameDir.lastPathComponent)")
                } else {
                    externalGameDirURL = canonicalGameDir
                }
            }
        }

        // 3. Find safe ~/Applications/CrossOver/<游戏>.app helper shortcut(s)
        let helperAppURLs = findMatchingHelperAppsToTrash(
            for: game,
            dedicatedBottleName: dedicatedBottle?.name,
            crossOverAppsDirectory: expandedCXAppsRoot
        )

        // 4. Terminate Wine processes of dedicated bottle BEFORE trashing files
        if let dedicatedBottle {
            let terminator = wineTerminator ?? { bottlePath in
                terminateBottleWineProcessesIfResident(bottlePath: bottlePath)
            }
            terminator(dedicatedBottle.path)
            terminatedBottleName = dedicatedBottle.name
        }

        // 5. Move approved targets to Trash via FileManager.trashItem
        var seenCanonicalTargets = Set<String>()
        func trashTarget(_ url: URL, label: String) {
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard !canonical.isEmpty,
                  seenCanonicalTargets.insert(canonical).inserted,
                  fm.fileExists(atPath: url.path) else {
                return
            }
            do {
                _ = try trashHandler(url)
                trashedPaths.append(canonical)
            } catch {
                warnings.append("无法将\(label) [\(url.lastPathComponent)] 移入废纸篓: \(error.localizedDescription)")
            }
        }

        if let externalGameDirURL {
            trashTarget(externalGameDirURL, label: "游戏目录")
        }
        if let dedicatedBottle {
            trashTarget(URL(fileURLWithPath: dedicatedBottle.path, isDirectory: true), label: "专属容器")
        }
        for appURL in helperAppURLs {
            trashTarget(appURL, label: "快捷方式")
        }

        return LaunchGameUninstallOutcome(
            trashedPaths: trashedPaths,
            skippedProtectedPaths: skippedProtectedPaths,
            terminatedBottleName: terminatedBottleName,
            warnings: warnings
        )
    }

    package static func defaultTrashItem(_ url: URL) throws -> URL? {
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
        return trashedURL as URL?
    }

    // MARK: - Safety Classifiers

    package static func isProtectedSystemOrRootDirectory(
        _ directoryPath: String,
        additionalProtectedRoots: [String] = []
    ) -> Bool {
        let trimmed = directoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let canonical = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path

        let fm = FileManager.default
        var rawProtected: [String] = [
            "/", "/Applications", "/System", "/Library", "/Users", "/Volumes",
            "/private", "/tmp", "/var", "/bin", "/sbin", "/usr",
            NSHomeDirectory(),
            "~/Downloads", "~/Desktop", "~/Documents", "~/Applications",
            "~/Library", "~/Movies", "~/Music", "~/Pictures", "~/Public"
        ]
        let userSearchDirs: [FileManager.SearchPathDirectory] = [
            .downloadsDirectory, .desktopDirectory, .documentDirectory,
            .applicationDirectory, .libraryDirectory, .cachesDirectory, .applicationSupportDirectory
        ]
        for searchDir in userSearchDirs {
            for url in fm.urls(for: searchDir, in: .userDomainMask) {
                rawProtected.append(url.path)
            }
        }
        rawProtected.append(contentsOf: additionalProtectedRoots)

        var protectedCanonical = Set<String>()
        for entry in rawProtected where !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let exp = (entry as NSString).expandingTildeInPath
            protectedCanonical.insert(URL(fileURLWithPath: exp).standardizedFileURL.path)
            protectedCanonical.insert(URL(fileURLWithPath: exp).resolvingSymlinksInPath().standardizedFileURL.path)
        }

        for candidate in [standardized, canonical] {
            if protectedCanonical.contains(candidate) {
                return true
            }
            for protectedPath in protectedCanonical where protectedPath != "/" {
                let prefix = candidate.hasSuffix("/") ? candidate : candidate + "/"
                if protectedPath.hasPrefix(prefix) {
                    return true
                }
            }
            if candidate.hasPrefix("/Volumes/") {
                let comps = candidate.split(separator: "/")
                if comps.count <= 2 { // "/Volumes" or "/Volumes/<Mount>"
                    return true
                }
            }
        }
        return false
    }

    package static func classifyBottleSafety(
        bottleName: String,
        bottlePath: String,
        for game: LaunchGame,
        knownGames: [LaunchGame],
        crossOverAppsDirectory: String
    ) -> BottleSafetyClassification {
        let lowerBottle = bottleName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if reservedSharedBottleNames.contains(lowerBottle)
            || lowerBottle.hasPrefix("steam ")
            || lowerBottle.hasSuffix(" steam")
            || lowerBottle == "crossover" {
            return .shared(name: bottleName, path: bottlePath, reason: "名称属于保留共享容器")
        }

        let fm = FileManager.default
        let canonicalBottlePath = URL(fileURLWithPath: bottlePath).resolvingSymlinksInPath().standardizedFileURL.path
        let bottlePrefix = canonicalBottlePath.hasSuffix("/") ? canonicalBottlePath : canonicalBottlePath + "/"

        // 1. Check whether any other known game references this bottle
        for other in knownGames where other.id != game.id {
            if let otherBottle = other.bottleName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !otherBottle.isEmpty,
               otherBottle.caseInsensitiveCompare(bottleName) == .orderedSame {
                return .shared(name: bottleName, path: bottlePath, reason: "已被其他游戏「\(other.title)」共用")
            }
            for otherPath in [other.gameDirectory, other.exePath].compactMap({ LaunchGame.canonicalPath($0) }) {
                if otherPath == canonicalBottlePath || otherPath.hasPrefix(bottlePrefix) {
                    return .shared(name: bottleName, path: bottlePath, reason: "容器内包含其他游戏「\(other.title)」")
                }
            }
        }

        let currentIdentifiers = normalizedGameIdentifiers(game: game, bottleName: bottleName)

        // 2. Check ~/Applications/CrossOver/*.app shortcuts targeting this bottle
        let expandedCXApps = (crossOverAppsDirectory as NSString).expandingTildeInPath
        if let appBundles = try? fm.contentsOfDirectory(atPath: expandedCXApps) {
            for bundleName in appBundles where bundleName.lowercased().hasSuffix(".app") {
                let appPath = (expandedCXApps as NSString).appendingPathComponent(bundleName)
                let plistPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
                guard let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any],
                      let targetBottle = dict["CXHelperAppBottleName"] as? String,
                      targetBottle.caseInsensitiveCompare(bottleName) == .orderedSame else {
                    continue
                }
                let bundleStem = (bundleName as NSString).deletingPathExtension
                let cfName = dict["CFBundleName"] as? String
                if !matchesAnyIdentifier(bundleStem, identifiers: currentIdentifiers)
                    && (cfName == nil || !matchesAnyIdentifier(cfName!, identifiers: currentIdentifiers)) {
                    return .shared(name: bottleName, path: bottlePath, reason: "存在其他快捷方式「\(bundleName)」共用该容器")
                }
            }
        }

        // 3. Inspect drive_c contents for non-current game directories or shortcuts
        let driveCURL = URL(fileURLWithPath: canonicalBottlePath, isDirectory: true)
            .appendingPathComponent("drive_c", isDirectory: true)
        let canonicalGameDir = LaunchGame.canonicalPath(game.gameDirectory)
        let canonicalExePath = LaunchGame.canonicalPath(game.exePath)

        func pathBelongsToCurrentGame(_ resolvedPath: String) -> Bool {
            if let canonicalGameDir {
                if resolvedPath == canonicalGameDir
                    || resolvedPath.hasPrefix(canonicalGameDir + "/")
                    || canonicalGameDir.hasPrefix(resolvedPath + "/") {
                    return true
                }
            }
            if let canonicalExePath {
                if resolvedPath == canonicalExePath || canonicalExePath.hasPrefix(resolvedPath + "/") {
                    return true
                }
            }
            return false
        }

        if fm.fileExists(atPath: driveCURL.path),
           let topEntries = try? fm.contentsOfDirectory(atPath: driveCURL.path) {
            for entry in topEntries where !entry.hasPrefix(".") && !windowsSystemTopLevelDirs.contains(entry.lowercased()) {
                let entryURL = driveCURL.appendingPathComponent(entry)
                let resolvedTarget: String = {
                    if let dest = try? fm.destinationOfSymbolicLink(atPath: entryURL.path) {
                        let destURL = dest.hasPrefix("/")
                            ? URL(fileURLWithPath: dest)
                            : URL(fileURLWithPath: dest, relativeTo: driveCURL)
                        return destURL.resolvingSymlinksInPath().standardizedFileURL.path
                    }
                    return entryURL.resolvingSymlinksInPath().standardizedFileURL.path
                }()
                var isSubDir: ObjCBool = false
                let targetExistsAsDir = fm.fileExists(atPath: resolvedTarget, isDirectory: &isSubDir) && isSubDir.boolValue
                let belongs = pathBelongsToCurrentGame(resolvedTarget)
                    || (!targetExistsAsDir && matchesAnyIdentifier(entry, identifiers: currentIdentifiers))
                if !belongs {
                    return .shared(name: bottleName, path: bottlePath, reason: "drive_c 包含其他游戏目录或链接: \(entry)")
                }
            }

            // 3b. Check Steam libraries & Program Files / Games folders inside drive_c
            let steamCommonCandidates = [
                driveCURL.appendingPathComponent("Program Files (x86)/Steam/steamapps/common", isDirectory: true),
                driveCURL.appendingPathComponent("Program Files/Steam/steamapps/common", isDirectory: true)
            ]
            for commonDir in steamCommonCandidates {
                if let items = try? fm.contentsOfDirectory(atPath: commonDir.path) {
                    for item in items where !item.hasPrefix(".") && item.lowercased() != "steamworks shared" {
                        let resolved = commonDir.appendingPathComponent(item).resolvingSymlinksInPath().standardizedFileURL.path
                        if !pathBelongsToCurrentGame(resolved) && !matchesAnyIdentifier(item, identifiers: currentIdentifiers) {
                            return .shared(name: bottleName, path: bottlePath, reason: "容器包含 Steam 游戏库目录: \(item)")
                        }
                    }
                }
            }

            let installContainers = ["Program Files", "Program Files (x86)", "Games", "GOG Games"]
            for container in installContainers {
                let containerURL = driveCURL.appendingPathComponent(container, isDirectory: true)
                guard let subItems = try? fm.contentsOfDirectory(atPath: containerURL.path) else { continue }
                let isProgramFiles = container.lowercased().hasPrefix("program files")
                for sub in subItems where !sub.hasPrefix(".") {
                    let lowerSub = sub.lowercased()
                    if isProgramFiles && programFilesSystemDirs.contains(lowerSub) {
                        continue
                    }
                    let subURL = containerURL.appendingPathComponent(sub, isDirectory: true)
                    let resolvedSub = subURL.resolvingSymlinksInPath().standardizedFileURL.path
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: resolvedSub, isDirectory: &isDir), isDir.boolValue else { continue }
                    if !pathBelongsToCurrentGame(resolvedSub)
                        && !matchesAnyIdentifier(sub, identifiers: currentIdentifiers)
                        && directoryContainsNonIgnoredExecutable(at: subURL) {
                        return .shared(name: bottleName, path: bottlePath, reason: "drive_c/\(container) 包含其他程序: \(sub)")
                    }
                }
            }

            // 3c. Check Start Menu & Desktop .lnk shortcuts inside drive_c/users/*
            let usersURL = driveCURL.appendingPathComponent("users", isDirectory: true)
            if let userDirs = try? fm.contentsOfDirectory(atPath: usersURL.path) {
                for user in userDirs where !user.hasPrefix(".") && user.lowercased() != "public" {
                    let userURL = usersURL.appendingPathComponent(user, isDirectory: true)
                    let shortcutRoots = [
                        userURL.appendingPathComponent("AppData/Roaming/Microsoft/Windows/Start Menu", isDirectory: true),
                        userURL.appendingPathComponent("Start Menu", isDirectory: true),
                        userURL.appendingPathComponent("Desktop", isDirectory: true)
                    ]
                    for root in shortcutRoots where fm.fileExists(atPath: root.path) {
                        if let unrelatedLnk = findUnrelatedShortcutName(in: root, currentIdentifiers: currentIdentifiers) {
                            return .shared(name: bottleName, path: bottlePath, reason: "容器菜单包含其他快捷方式: \(unrelatedLnk)")
                        }
                    }
                }
            }
        }

        return .dedicated(name: bottleName, path: canonicalBottlePath)
    }

    // MARK: - Process Termination

    package static func terminateBottleWineProcessesIfResident(
        bottlePath: String,
        timeoutSeconds: TimeInterval = 3.0
    ) {
        guard let canonicalBottle = try? PathSafety.existingCanonicalDirectory(bottlePath),
              CrossOverRegistryHelper.isBottleWineserverResident(bottlePath: canonicalBottle.path),
              let wineserver = ToolchainLocator.locateCrossOverBin("wineserver") else {
            return
        }

        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = canonicalBottle.path
        env["CX_BOTTLE_PATH"] = canonicalBottle.deletingLastPathComponent().path

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: wineserver)
        proc.arguments = ["-k"]
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
        }
        while CrossOverRegistryHelper.isBottleWineserverResident(bottlePath: canonicalBottle.path)
            && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // MARK: - Helpers

    private static func isProtectedDriveCSubdirectory(_ dir: URL, bottlesRoot: URL?) -> Bool {
        let lower = dir.lastPathComponent.lowercased()
        guard driveCSpecialDirectoryNames.contains(lower) else { return false }
        if let bottlesRoot {
            let prefix = bottlesRoot.path.hasSuffix("/") ? bottlesRoot.path : bottlesRoot.path + "/"
            if dir.path.hasPrefix(prefix) {
                return true
            }
        }
        return dir.path.lowercased().contains("/drive_c")
    }

    private static func findMatchingHelperAppsToTrash(
        for game: LaunchGame,
        dedicatedBottleName: String?,
        crossOverAppsDirectory: String
    ) -> [URL] {
        let fm = FileManager.default
        guard let canonicalCXApps = try? PathSafety.existingCanonicalDirectory(crossOverAppsDirectory),
              let entries = try? fm.contentsOfDirectory(atPath: canonicalCXApps.path) else {
            return []
        }

        let protectedBundleLowerNames: Set<String> = ["steam.app", "crossover.app"]
        var titleStems = Set<String>()
        titleStems.insert(game.title.lowercased())
        if let safe = PathSafety.safeFilename(game.title) {
            titleStems.insert(safe.lowercased())
        }
        if let dedicatedBottleName, !dedicatedBottleName.isEmpty {
            titleStems.insert(dedicatedBottleName.lowercased())
        }
        let normGameTitle = LaunchGame.normalizedIdentityTitle(game.title)

        var matches: [URL] = []
        for entry in entries where entry.lowercased().hasSuffix(".app") {
            let lowerEntry = entry.lowercased()
            if protectedBundleLowerNames.contains(lowerEntry) {
                continue
            }
            let appURL = canonicalCXApps.appendingPathComponent(entry, isDirectory: true).standardizedFileURL
            guard let safeAppURL = PathSafety.containedURL(appURL, in: canonicalCXApps),
                  safeAppURL.path != canonicalCXApps.path,
                  safeAppURL.deletingLastPathComponent().path == canonicalCXApps.path else {
                continue
            }

            let bundleStem = (entry as NSString).deletingPathExtension
            let plistPath = safeAppURL.appendingPathComponent("Contents/Info.plist").path
            let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any]
            let cfName = dict?["CFBundleName"] as? String
            let bottleInPlist = (dict?["CXHelperAppBottleName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let bottleInPlist, !bottleInPlist.isEmpty {
                let bottleMatches = (dedicatedBottleName?.caseInsensitiveCompare(bottleInPlist) == .orderedSame)
                    || (game.bottleName?.caseInsensitiveCompare(bottleInPlist) == .orderedSame)
                    || (bottleInPlist.caseInsensitiveCompare(game.title) == .orderedSame)
                // If Info.plist ties this .app explicitly to an unrelated bottle, do not touch it unless bundle name matches directly & plist matches game.
                let nameMatchesTitle = titleStems.contains(bundleStem.lowercased())
                    || (!normGameTitle.isEmpty && LaunchGame.normalizedIdentityTitle(bundleStem) == normGameTitle)
                    || (cfName.map { titleStems.contains($0.lowercased()) } ?? false)
                if dedicatedBottleName != nil && bottleInPlist.caseInsensitiveCompare(dedicatedBottleName!) == .orderedSame {
                    matches.append(safeAppURL)
                } else if nameMatchesTitle && bottleMatches {
                    matches.append(safeAppURL)
                }
            } else {
                let nameMatchesTitle = titleStems.contains(bundleStem.lowercased())
                    || (!normGameTitle.isEmpty && LaunchGame.normalizedIdentityTitle(bundleStem) == normGameTitle)
                if nameMatchesTitle {
                    matches.append(safeAppURL)
                }
            }
        }
        return matches
    }

    private static func normalizedGameIdentifiers(game: LaunchGame, bottleName: String) -> [String] {
        var candidates: [String] = []
        for raw in [
            game.title,
            bottleName,
            game.gameDirectory.map { ($0 as NSString).lastPathComponent },
            game.exePath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        ].compactMap({ $0 }) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                candidates.append(trimmed.lowercased())
                let norm = LaunchGame.normalizedIdentityTitle(trimmed)
                if !norm.isEmpty {
                    candidates.append(norm)
                }
            }
        }
        return Array(Set(candidates))
    }

    private static func matchesAnyIdentifier(_ value: String, identifiers: [String]) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        let norm = LaunchGame.normalizedIdentityTitle(trimmed)
        for ident in identifiers where !ident.isEmpty {
            if lower == ident || (!norm.isEmpty && norm == ident) {
                return true
            }
            if ident.count >= 4 && (lower.contains(ident) || ident.contains(lower)) {
                return true
            }
            if !norm.isEmpty && norm.count >= 4 && (norm.contains(ident) || ident.contains(norm)) {
                return true
            }
        }
        return false
    }

    private static func directoryContainsNonIgnoredExecutable(at url: URL) -> Bool {
        guard let canonical = try? PathSafety.existingCanonicalDirectory(url.path) else {
            return false
        }
        var found = false
        try? PathSafety.walkDirectory(
            at: canonical,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants],
            includeSymlinks: false
        ) { _, relativePath, vals in
            guard !found, vals.isRegularFile == true else { return }
            let lower = (relativePath as NSString).lastPathComponent.lowercased()
            if lower.hasSuffix(".exe") && !LaunchGame.isIgnoredHelperExecutable(relativePath) {
                found = true
            }
        }
        return found
    }

    private static func findUnrelatedShortcutName(
        in rootURL: URL,
        currentIdentifiers: [String]
    ) -> String? {
        guard let canonical = try? PathSafety.existingCanonicalDirectory(rootURL.path) else {
            return nil
        }
        var unrelated: String? = nil
        try? PathSafety.walkDirectory(
            at: canonical,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants],
            includeSymlinks: false
        ) { itemURL, relativePath, vals in
            guard unrelated == nil, vals.isRegularFile == true else { return }
            let fileName = itemURL.lastPathComponent
            let lower = fileName.lowercased()
            guard lower.hasSuffix(".lnk") else { return }
            let stem = (fileName as NSString).deletingPathExtension
            let lowerStem = stem.lowercased()
            if utilityShortcutKeywords.contains(where: { lowerStem.contains($0) }) {
                return
            }
            if !matchesAnyIdentifier(stem, identifiers: currentIdentifiers) {
                unrelated = relativePath
            }
        }
        return unrelated
    }
}
