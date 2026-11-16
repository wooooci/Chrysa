import ChrysaCore
import ChrysaApplication
import Foundation

/// Reads and updates CrossOver bottle configuration (`cxbottle.conf`), Wine registry hives (`user.reg` / `system.reg`),
/// macOS Chinese font symlinks, and `C:\<bottleName>\...` Windows launch path mapping.
package enum CrossOverRegistryHelper {
    private static let macChineseFontMappings: [(path: String, fileName: String, familyName: String, role: FontRole)] = [
        ("/System/Library/Fonts/PingFang.ttc", "PingFang.ttc", "PingFang SC", .sans),
        ("/System/Library/Fonts/Hiragino Sans GB.ttc", "Hiragino Sans GB.ttc", "Hiragino Sans GB", .sans),
        ("/System/Library/Fonts/STHeiti Medium.ttc", "STHeiti Medium.ttc", "Heiti SC", .hei),
        ("/System/Library/Fonts/STHeiti Light.ttc", "STHeiti Light.ttc", "Heiti SC", .hei),
        ("/System/Library/Fonts/Supplemental/Songti.ttc", "Songti.ttc", "Songti SC", .song),
        ("/System/Library/Fonts/Songti.ttc", "Songti.ttc", "Songti SC", .song)
    ]

    private enum FontRole {
        case sans, hei, song
    }

    private static let macDriverSection = "Software\\\\Wine\\\\Mac Driver"

    // MARK: - Bottle Path Resolution & Symlinks

    /// Resolves a valid local CrossOver bottle directory (with bottle artifacts present), excluding `"Default"` and paths escaping `bottlesDirectory`.
    package static func resolveValidLocalBottle(
        explicitBottleName: String?,
        gameTitle: String,
        exePath: String?,
        bottlesDirectory: String
    ) -> (name: String, path: String)? {
        guard let candidate = resolveExistingBottle(
            explicitBottleName: explicitBottleName,
            gameTitle: gameTitle,
            exePath: exePath,
            bottlesDirectory: bottlesDirectory
        ) else {
            return nil
        }
        guard candidate.name.caseInsensitiveCompare("Default") != .orderedSame else {
            return nil
        }
        let expandedRoot = (bottlesDirectory as NSString).expandingTildeInPath
        guard let canonicalRoot = try? PathSafety.existingCanonicalDirectory(expandedRoot),
              let canonicalBottle = try? PathSafety.existingCanonicalDirectory(candidate.path),
              let contained = PathSafety.containedURL(canonicalBottle, in: canonicalRoot),
              contained.path != canonicalRoot.path,
              contained.deletingLastPathComponent().path == canonicalRoot.path else {
            return nil
        }
        let fm = FileManager.default
        let hasConf = fm.fileExists(atPath: contained.appendingPathComponent("cxbottle.conf").path)
        let hasUserReg = fm.fileExists(atPath: contained.appendingPathComponent("user.reg").path)
        let hasDriveC = fm.fileExists(atPath: contained.appendingPathComponent("drive_c").path)
        guard hasConf || hasUserReg || hasDriveC else {
            return nil
        }
        return (contained.lastPathComponent, contained.path)
    }

    /// Resolves an existing CrossOver bottle (`name` and `path`), matching `explicitBottleName`, inside `bottlesRoot`, or condensed title.
    package static func resolveExistingBottle(
        explicitBottleName: String?,
        gameTitle: String,
        exePath: String?,
        bottlesDirectory: String
    ) -> (name: String, path: String)? {
        let fm = FileManager.default
        let bottlesRoot = (bottlesDirectory as NSString).expandingTildeInPath
        guard fm.fileExists(atPath: bottlesRoot) else { return nil }

        func validated(_ name: String) -> (name: String, path: String)? {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { return nil }
            let path = (bottlesRoot as NSString).appendingPathComponent(trimmedName)
            return fm.fileExists(atPath: path) ? (trimmedName, path) : nil
        }

        if let explicit = explicitBottleName, let match = validated(explicit) {
            return match
        }

        if let exe = exePath, exe.hasPrefix(bottlesRoot + "/") {
            let rel = String(exe.dropFirst((bottlesRoot + "/").count))
            if let candidate = rel.components(separatedBy: "/").first,
               let match = validated(candidate) {
                return match
            }
        }

        let trimmed = gameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = (trimmed == trimmed.lowercased()) ? trimmed.capitalized : trimmed
        let condensedTarget = normalizedTitle.replacingOccurrences(of: " ", with: "").lowercased()
        if let existing = try? fm.contentsOfDirectory(atPath: bottlesRoot) {
            if let match = existing.first(where: {
                $0.caseInsensitiveCompare(normalizedTitle) == .orderedSame
                    || $0.replacingOccurrences(of: " ", with: "").lowercased() == condensedTarget
            }) {
                return validated(match)
            }
        }
        return nil
    }

    package static func resolveExistingBottleName(
        explicitBottleName: String?,
        gameTitle: String,
        exePath: String?,
        bottlesDirectory: String
    ) -> String? {
        resolveExistingBottle(
            explicitBottleName: explicitBottleName,
            gameTitle: gameTitle,
            exePath: exePath,
            bottlesDirectory: bottlesDirectory
        )?.name
    }

    /// Selects the symlink root inside `drive_c/<bottleName>`: prefers `gameDirectory` if it contains `executablePath`.
    package static func preferredDriveCLinkTarget(executablePath: String, gameDirectory: String?) -> String {
        if let gameDir = gameDirectory,
           LaunchGame.relativeSubpath(of: executablePath, inside: gameDir) != nil {
            return gameDir
        }
        return (executablePath as NSString).deletingLastPathComponent
    }

    /// Ensures `drive_c/<bottleName>` points to `targetDirectory`, refreshing any stale or wrong symlink.
    @discardableResult
    package static func ensureBottleDriveCSymlink(
        bottlePath: String,
        bottleName: String,
        targetDirectory: String
    ) throws -> Bool {
        let fm = FileManager.default
        let driveCDir = (bottlePath as NSString).appendingPathComponent("drive_c")
        guard fm.fileExists(atPath: driveCDir) else { return false }

        let standardizedTarget = URL(fileURLWithPath: targetDirectory).standardizedFileURL.path
        let linkPath = (driveCDir as NSString).appendingPathComponent(bottleName)

        if let existingDest = try? fm.destinationOfSymbolicLink(atPath: linkPath) {
            if URL(fileURLWithPath: existingDest).standardizedFileURL.path == standardizedTarget {
                return true
            }
            try fm.removeItem(atPath: linkPath)
        } else if fm.fileExists(atPath: linkPath) {
            // Do not delete a real non-symlink directory containing user files inside drive_c.
            return false
        }

        try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: standardizedTarget)
        return true
    }

    /// Converts an external macOS `.exe` path into `C:\<bottleName>\...` when `drive_c/<bottleName>` covers it.
    package static func windowsLaunchTarget(
        exePath: String,
        gameDirectory: String?,
        bottlePath: String,
        bottleName: String
    ) -> String? {
        let fm = FileManager.default
        let linkPath = ((bottlePath as NSString).appendingPathComponent("drive_c") as NSString)
            .appendingPathComponent(bottleName)
        guard let linkDest = try? fm.destinationOfSymbolicLink(atPath: linkPath) else {
            return nil
        }
        guard let rel = LaunchGame.relativeSubpath(of: exePath, inside: linkDest) else {
            // Fallback check against explicit gameDirectory if symlink differs from canonical resolution.
            if let gameDir = gameDirectory,
               let canonicalGame = LaunchGame.canonicalPath(gameDir),
               let canonicalLink = LaunchGame.canonicalPath(linkDest),
               canonicalGame == canonicalLink,
               let relFromGame = LaunchGame.relativeSubpath(of: exePath, inside: gameDir) {
                let winRel = relFromGame.replacingOccurrences(of: "/", with: "\\")
                return "C:\\\(bottleName)\\\(winRel)"
            }
            return nil
        }
        let winRel = rel.replacingOccurrences(of: "/", with: "\\")
        return "C:\\\(bottleName)\\\(winRel)"
    }

    // MARK: - Chinese Fonts & FontSubstitutes

    /// Symlinks macOS built-in CJK fonts into `drive_c/windows/Fonts` and registers `FontSubstitutes`
    /// in `user.reg` (and `system.reg` when present) so Chinese text avoids missing-glyph tofu boxes.
    package static func ensureChineseFontsConfigured(bottlePath: String) throws {
        let fm = FileManager.default
        let fontsDir = ((bottlePath as NSString).appendingPathComponent("drive_c") as NSString)
            .appendingPathComponent("windows/Fonts")
        if !fm.fileExists(atPath: fontsDir) {
            try fm.createDirectory(atPath: fontsDir, withIntermediateDirectories: true)
        }

        var availableSans: String?
        var availableHei: String?
        var availableSong: String?

        for entry in macChineseFontMappings where fm.fileExists(atPath: entry.path) {
            let linkPath = (fontsDir as NSString).appendingPathComponent(entry.fileName)
            if let currentDest = try? fm.destinationOfSymbolicLink(atPath: linkPath) {
                if currentDest != entry.path {
                    try? fm.removeItem(atPath: linkPath)
                    try? fm.createSymbolicLink(atPath: linkPath, withDestinationPath: entry.path)
                }
            } else if !fm.fileExists(atPath: linkPath) {
                try? fm.createSymbolicLink(atPath: linkPath, withDestinationPath: entry.path)
            }

            switch entry.role {
            case .sans:
                if availableSans == nil { availableSans = entry.familyName }
            case .hei:
                if availableHei == nil { availableHei = entry.familyName }
            case .song:
                if availableSong == nil { availableSong = entry.familyName }
            }
        }

        let yaheiTarget = availableSans ?? availableHei ?? "Hiragino Sans GB"
        let simheiTarget = availableHei ?? yaheiTarget
        let simsunTarget = availableSong ?? yaheiTarget

        let fontSubstitutes: [(String, String)] = [
            ("Microsoft YaHei", yaheiTarget),
            ("Microsoft YaHei UI", yaheiTarget),
            ("SimSun", simsunTarget),
            ("NSimSun", simsunTarget),
            ("SimHei", simheiTarget)
        ]

        let userRegPath = (bottlePath as NSString).appendingPathComponent("user.reg")
        try upsertRegistryValues(
            inRegFile: userRegPath,
            sectionPath: "Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\FontSubstitutes",
            updates: fontSubstitutes,
            createIfMissing: true
        )

        let systemRegPath = (bottlePath as NSString).appendingPathComponent("system.reg")
        if fm.fileExists(atPath: systemRegPath) {
            try upsertRegistryValues(
                inRegFile: systemRegPath,
                sectionPath: "Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\FontSubstitutes",
                updates: fontSubstitutes,
                createIfMissing: false
            )
        }
    }

    // MARK: - DLL Overrides Sync (cxbottle.conf + user.reg)

    /// Ensures all whitelist proxy DLL overrides (`dll=n,b` in `cxbottle.conf` and `"dll"="native,builtin"` in `user.reg`)
    /// are synchronized, and optionally removes stale stems when restoring a pre-patch clean state.
    package static func syncProxyDLLOverrides(
        inBottlePath bottlePath: String,
        ensuring stemsToEnsure: [String],
        removing stemsToRemove: [String] = [],
        hasD3D12: Bool? = nil
    ) throws {
        let fm = FileManager.default
        let confPath = (bottlePath as NSString).appendingPathComponent("cxbottle.conf")
        if fm.fileExists(atPath: confPath),
           let existingConf = try? String(contentsOfFile: confPath, encoding: .utf8) {
            let updatedConf = mergeBottleConfEnvironment(
                confText: existingConf,
                ensuringDLLStems: stemsToEnsure,
                removingDLLStems: stemsToRemove,
                hasD3D12: hasD3D12
            )
            if updatedConf != existingConf {
                try updatedConf.write(toFile: confPath, atomically: true, encoding: .utf8)
            }
        }

        let userRegPath = (bottlePath as NSString).appendingPathComponent("user.reg")
        if !stemsToEnsure.isEmpty || !stemsToRemove.isEmpty {
            let regUpdates = stemsToEnsure.map { ($0.lowercased(), "native,builtin") }
            let cleanRemovals = stemsToRemove.map { $0.lowercased() }
            try upsertRegistryValues(
                inRegFile: userRegPath,
                sectionPath: "Software\\\\Wine\\\\DllOverrides",
                updates: regUpdates,
                removals: cleanRemovals,
                createIfMissing: !stemsToEnsure.isEmpty
            )
            syncLiveWineDllOverridesIfResident(
                bottlePath: bottlePath,
                ensuring: stemsToEnsure.map { $0.lowercased() },
                removing: cleanRemovals
            )
        }
    }

    /// Checks whether CrossOver's resident `wineserver` currently holds an active Unix domain socket for `bottlePath`.
    package static func isBottleWineserverResident(bottlePath: String) -> Bool {
        var bottleStat = stat()
        let resolvedPath = URL(fileURLWithPath: bottlePath).resolvingSymlinksInPath().path
        guard stat(resolvedPath, &bottleStat) == 0 else { return false }
        let devHex = String(UInt32(bitPattern: bottleStat.st_dev), radix: 16)
        let inoHex = String(bottleStat.st_ino, radix: 16)
        let socketPath = "/tmp/.wine-\(getuid())/server-\(devHex)-\(inoHex)/socket"
        var sockStat = stat()
        guard stat(socketPath, &sockStat) == 0 else { return false }
        return (sockStat.st_mode & S_IFMT) == S_IFSOCK
    }

    private static func syncLiveWineDllOverridesIfResident(
        bottlePath: String,
        ensuring stemsToEnsure: [String],
        removing stemsToRemove: [String]
    ) {
        guard (!stemsToEnsure.isEmpty || !stemsToRemove.isEmpty),
              isBottleWineserverResident(bottlePath: bottlePath),
              let cxWine = ToolchainLocator.locateCrossOverBin("wine") else {
            return
        }
        let bottleName = URL(fileURLWithPath: bottlePath).lastPathComponent
        let ensureSet = Set(stemsToEnsure)
        for stem in stemsToEnsure where !stem.isEmpty {
            runQuickRegCommand(
                cxWine: cxWine,
                arguments: [
                    "--bottle", bottleName, "--check",
                    "reg.exe", "add", #"HKCU\Software\Wine\DllOverrides"#,
                    "/v", stem, "/t", "REG_SZ", "/d", "native,builtin", "/f"
                ]
            )
        }
        for stem in stemsToRemove where !stem.isEmpty && !ensureSet.contains(stem) {
            runQuickRegCommand(
                cxWine: cxWine,
                arguments: [
                    "--bottle", bottleName, "--check",
                    "reg.exe", "delete", #"HKCU\Software\Wine\DllOverrides"#,
                    "/v", stem, "/f"
                ]
            )
        }
    }

    private static func runQuickRegCommand(cxWine: String, arguments: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cxWine)
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return }
        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
        }
    }

    /// Reads current whitelist proxy DLL stems configured in `cxbottle.conf` / `user.reg` (used to record clean baseline).
    package static func activeWhitelistOverrides(inBottlePath bottlePath: String) -> [String] {
        let whitelistStems = Set(PEBinaryInspector.proxyHookDLLWhitelist.map { String($0.dropLast(4)) })
        var found = Set<String>()

        let confPath = (bottlePath as NSString).appendingPathComponent("cxbottle.conf")
        if let confText = try? String(contentsOfFile: confPath, encoding: .utf8) {
            for entry in parseWineDLLOverrides(fromConf: confText) {
                let stem = entry.stem.lowercased()
                if whitelistStems.contains(stem) {
                    found.insert(stem)
                }
            }
        }

        let userRegPath = (bottlePath as NSString).appendingPathComponent("user.reg")
        if let regText = try? String(contentsOfFile: userRegPath, encoding: .utf8) {
            let keys = readRegistrySectionKeys(in: regText, sectionPath: "Software\\\\Wine\\\\DllOverrides")
            for key in keys {
                let stem = key.lowercased()
                if whitelistStems.contains(stem) {
                    found.insert(stem)
                }
            }
        }

        return found.sorted()
    }

    // MARK: - Runtime Options (CX_GRAPHICS_BACKEND & RetinaMode)

    package static func readBottleRuntimeOptions(inBottlePath bottlePath: String) -> CrossOverBottleRuntimeOptions {
        guard let canonicalBottle = try? PathSafety.existingCanonicalDirectory(bottlePath) else {
            return CrossOverBottleRuntimeOptions()
        }
        let confURL = canonicalBottle.appendingPathComponent("cxbottle.conf").standardizedFileURL
        let userRegURL = canonicalBottle.appendingPathComponent("user.reg").standardizedFileURL

        let backend: CrossOverGraphicsBackend = {
            guard let safeConf = PathSafety.containedURL(confURL, in: canonicalBottle),
                  let confText = try? String(contentsOfFile: safeConf.path, encoding: .utf8) else {
                return .automatic
            }
            return readGraphicsBackend(fromConf: confText)
        }()

        let retina: Bool = {
            guard let safeReg = PathSafety.containedURL(userRegURL, in: canonicalBottle),
                  let regText = try? String(contentsOfFile: safeReg.path, encoding: .utf8) else {
                return false
            }
            return readRetinaMode(fromReg: regText)
        }()

        return CrossOverBottleRuntimeOptions(graphicsBackend: backend, retinaMode: retina)
    }

    package static func writeBottleRuntimeOptions(
        _ options: CrossOverBottleRuntimeOptions,
        inBottlePath bottlePath: String
    ) throws {
        let canonicalBottle = try PathSafety.existingCanonicalDirectory(bottlePath)
        let fm = FileManager.default

        let confCandidate = canonicalBottle.appendingPathComponent("cxbottle.conf").standardizedFileURL
        guard let safeConf = PathSafety.containedURL(confCandidate, in: canonicalBottle) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let confExists = fm.fileExists(atPath: safeConf.path)
        if confExists || options.graphicsBackend != .automatic {
            let originalConf = (confExists ? (try? String(contentsOfFile: safeConf.path, encoding: .utf8)) : nil) ?? ""
            let updatedConf = setGraphicsBackend(options.graphicsBackend, inConf: originalConf)
            if updatedConf != originalConf || (!confExists && options.graphicsBackend != .automatic) {
                try updatedConf.write(to: safeConf, atomically: true, encoding: .utf8)
            }
        }

        let regCandidate = canonicalBottle.appendingPathComponent("user.reg").standardizedFileURL
        guard let safeReg = PathSafety.containedURL(regCandidate, in: canonicalBottle) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let retinaValue = options.retinaMode ? "y" : "n"
        try upsertRegistryValues(
            inRegFile: safeReg.path,
            sectionPath: macDriverSection,
            updates: [("RetinaMode", retinaValue)],
            createIfMissing: true
        )

        if isBottleWineserverResident(bottlePath: canonicalBottle.path),
           let cxWine = ToolchainLocator.locateCrossOverBin("wine") {
            let bottleName = canonicalBottle.lastPathComponent
            runQuickRegCommand(
                cxWine: cxWine,
                arguments: [
                    "--bottle", bottleName, "--check",
                    "reg.exe", "add", #"HKCU\Software\Wine\Mac Driver"#,
                    "/v", "RetinaMode", "/t", "REG_SZ", "/d", retinaValue, "/f"
                ]
            )
        }
    }

    package static func readGraphicsBackend(fromConf confText: String) -> CrossOverGraphicsBackend {
        let normalized = confText.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let range = PathSafety.findSectionRange(in: lines, header: "[EnvironmentVariables]") else {
            return .automatic
        }
        for rawLine in lines[(range.start + 1)..<range.end] {
            if let pair = parseConfAssignment(fromLine: rawLine),
               pair.key.caseInsensitiveCompare("CX_GRAPHICS_BACKEND") == .orderedSame {
                return CrossOverGraphicsBackend.fromConfigValue(pair.value)
            }
        }
        return .automatic
    }

    package static func setGraphicsBackend(
        _ backend: CrossOverGraphicsBackend,
        inConf confText: String
    ) -> String {
        let usesCRLF = confText.contains("\r\n")
        let lineBreak = usesCRLF ? "\r\n" : "\n"
        let normalized = usesCRLF ? confText.replacingOccurrences(of: "\r\n", with: "\n") : confText
        var lines = normalized.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        let targetLine: String? = backend.envValue.map { "\"CX_GRAPHICS_BACKEND\" = \"\($0)\"" }

        if let range = PathSafety.findSectionRange(in: lines, header: "[EnvironmentVariables]") {
            let bodyStart = range.start + 1
            var newBody: [String] = []
            var replacedExisting = false
            for idx in bodyStart..<range.end {
                let rawLine = lines[idx]
                if let pair = parseConfAssignment(fromLine: rawLine),
                   pair.key.caseInsensitiveCompare("CX_GRAPHICS_BACKEND") == .orderedSame {
                    if let targetLine, !replacedExisting {
                        newBody.append(targetLine)
                        replacedExisting = true
                    }
                    continue
                }
                newBody.append(rawLine)
            }
            lines.replaceSubrange(bodyStart..<range.end, with: newBody)
            if let targetLine, !replacedExisting {
                insertEnvKey(targetLine, into: &lines)
            }
        } else if let targetLine {
            insertEnvKey(targetLine, into: &lines)
        }

        if lines.isEmpty {
            return ""
        }
        return lines.joined(separator: lineBreak) + lineBreak
    }

    package static func readRetinaMode(fromReg regText: String) -> Bool {
        let normalized = regText.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let range = PathSafety.findSectionRange(in: lines, header: "[\(macDriverSection)]") else {
            return false
        }
        for rawLine in lines[(range.start + 1)..<range.end] {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix(";"), !trimmed.hasPrefix("#") else { continue }
            if let pair = parseConfAssignment(fromLine: trimmed),
               pair.key.caseInsensitiveCompare("RetinaMode") == .orderedSame {
                let v = pair.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return v == "y" || v == "1" || v == "true"
            }
        }
        return false
    }

    package static func setRetinaMode(_ enabled: Bool, inReg regText: String) -> String {
        upsertRegistrySection(
            regText: regText,
            sectionPath: macDriverSection,
            updates: [("RetinaMode", enabled ? "y" : "n")]
        )
    }

    private static func parseConfAssignment(fromLine rawLine: String) -> (key: String, value: String)? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(";"), !trimmed.hasPrefix("#"),
              let eqIdx = trimmed.firstIndex(of: "=") else {
            return nil
        }
        var lhs = String(trimmed[..<eqIdx]).trimmingCharacters(in: .whitespaces)
        var rhs = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
        if lhs.count >= 2, lhs.hasPrefix("\""), lhs.hasSuffix("\"") {
            lhs = String(lhs.dropFirst().dropLast())
        }
        if rhs.count >= 2, rhs.hasPrefix("\""), rhs.hasSuffix("\"") {
            rhs = String(rhs.dropFirst().dropLast())
        }
        return lhs.isEmpty ? nil : (lhs, rhs)
    }

    // MARK: - Steam App InstallLocation (for .exe updaters)

    package static func ensureSteamAppInstallLocation(
        inBottlePath bottlePath: String,
        appID: String,
        bottleName: String
    ) throws {
        let trimmed = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Int(trimmed) != nil else { return }
        let systemRegPath = (bottlePath as NSString).appendingPathComponent("system.reg")
        let winPath = "C:\\\(bottleName)"

        for section in [
            "Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall\\\\Steam App \(trimmed)",
            "Software\\\\Wow6432Node\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall\\\\Steam App \(trimmed)"
        ] {
            try upsertRegistryValues(
                inRegFile: systemRegPath,
                sectionPath: section,
                updates: [("InstallLocation", winPath)],
                createIfMissing: true
            )
        }
    }

    // MARK: - Pure Text Updaters (also unit-tested)

    package static func mergeBottleConfEnvironment(
        confText: String,
        ensuringDLLStems: [String],
        removingDLLStems: [String] = [],
        hasD3D12: Bool? = nil
    ) -> String {
        let usesCRLF = confText.contains("\r\n")
        let lineBreak = usesCRLF ? "\r\n" : "\n"
        let normalized = usesCRLF ? confText.replacingOccurrences(of: "\r\n", with: "\n") : confText

        let hasMSync = normalized.contains("\"WINEMSYNC\"")
        let hasGraphics = normalized.contains("CX_GRAPHICS_BACKEND")

        var entries = parseWineDLLOverrides(fromConf: normalized)
        let removeSet = Set(removingDLLStems.map { $0.lowercased() })
        entries.removeAll { removeSet.contains($0.stem.lowercased()) }
        for stem in ensuringDLLStems.map({ $0.lowercased() }) where !stem.isEmpty {
            if !entries.contains(where: { $0.stem.caseInsensitiveCompare(stem) == .orderedSame }) {
                entries.append((stem, "n,b"))
            }
        }

        var lines = normalized.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        let newOverrideLine: String? = entries.isEmpty
            ? nil
            : "\"WINEDLLOVERRIDES\" = \"\(entries.map { "\($0.stem)=\($0.mode)" }.joined(separator: ";"))\""

        if let existingIdx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("\"WINEDLLOVERRIDES\"")
        }) {
            if let replacement = newOverrideLine {
                lines[existingIdx] = replacement
            } else {
                lines.remove(at: existingIdx)
            }
        } else if let addition = newOverrideLine {
            insertEnvKey(addition, into: &lines)
        }

        if !hasMSync {
            insertEnvKey("\"WINEMSYNC\" = \"1\"", into: &lines)
        }
        if hasD3D12 == true, !hasGraphics {
            insertEnvKey("\"CX_GRAPHICS_BACKEND\" = \"d3dmetal\"", into: &lines)
        }
        return lines.joined(separator: lineBreak) + lineBreak
    }

    private static func insertEnvKey(_ keyLine: String, into lines: inout [String]) {
        if let range = PathSafety.findSectionRange(in: lines, header: "[EnvironmentVariables]") {
            lines.insert(keyLine, at: insertionIndex(in: lines, bodyStart: range.start + 1, end: range.end))
        } else {
            if !lines.isEmpty, !lines.last!.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("")
            }
            lines.append("[EnvironmentVariables]")
            lines.append(keyLine)
        }
    }

    package static func upsertRegistrySection(
        regText: String,
        sectionPath: String,
        updates: [(key: String, value: String)],
        removals: [String] = []
    ) -> String {
        let usesCRLF = regText.contains("\r\n")
        let lineBreak = usesCRLF ? "\r\n" : "\n"
        var normalized = usesCRLF ? regText.replacingOccurrences(of: "\r\n", with: "\n") : regText
        if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized = "WINE REGISTRY Version 2\n"
        }

        var lines = normalized.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        let removalSet = Set(removals.map { $0.lowercased() })
        func formatValue(_ value: String) -> String {
            value
                .replacingOccurrences(of: #"\"#, with: #"\\"#)
                .replacingOccurrences(of: "\"", with: "\\\"")
        }

        if let range = PathSafety.findSectionRange(in: lines, header: "[\(sectionPath)]") {
            let bodyStart = range.start + 1
            var remainingUpdates = updates
            var keptBody: [String] = []
            for idx in bodyStart..<range.end {
                let rawLine = lines[idx]
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix(";") || trimmed.hasPrefix("#") {
                    keptBody.append(rawLine)
                    continue
                }
                if let parsedKey = parseRegistryKey(fromLine: trimmed) {
                    if removalSet.contains(parsedKey.lowercased()) {
                        continue
                    }
                    if let matchIdx = remainingUpdates.firstIndex(where: { $0.key.caseInsensitiveCompare(parsedKey) == .orderedSame }) {
                        let pair = remainingUpdates.remove(at: matchIdx)
                        keptBody.append("\"\(pair.key)\"=\"\(formatValue(pair.value))\"")
                        continue
                    }
                }
                keptBody.append(rawLine)
            }
            while keptBody.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                keptBody.removeLast()
            }
            for pair in remainingUpdates where !removalSet.contains(pair.key.lowercased()) {
                keptBody.append("\"\(pair.key)\"=\"\(formatValue(pair.value))\"")
            }
            if range.end < lines.count {
                keptBody.append("")
            }
            lines.replaceSubrange(bodyStart..<range.end, with: keptBody)
        } else if !updates.isEmpty {
            let epoch = Int(Date().timeIntervalSince1970)
            if !lines.isEmpty, !lines.last!.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("")
            }
            lines.append("[\(sectionPath)] \(epoch)")
            for pair in updates where !removalSet.contains(pair.key.lowercased()) {
                lines.append("\"\(pair.key)\"=\"\(formatValue(pair.value))\"")
            }
        }

        return lines.joined(separator: lineBreak) + lineBreak
    }

    private static func upsertRegistryValues(
        inRegFile path: String,
        sectionPath: String,
        updates: [(key: String, value: String)] = [],
        removals: [String] = [],
        createIfMissing: Bool
    ) throws {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: path)
        if !exists && !createIfMissing {
            return
        }
        let original = (exists ? (try? String(contentsOfFile: path, encoding: .utf8)) : nil)
            ?? "WINE REGISTRY Version 2\n"
        var updated = original
        if !updates.isEmpty || !removals.isEmpty {
            updated = upsertRegistrySection(
                regText: updated,
                sectionPath: sectionPath,
                updates: updates,
                removals: removals
            )
        }
        if updated != original || !exists {
            try updated.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func parseWineDLLOverrides(fromConf confText: String) -> [(stem: String, mode: String)] {
        for rawLine in confText.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"WINEDLLOVERRIDES\""),
                  let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            var rhs = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
            if rhs.count >= 2 && rhs.hasPrefix("\"") && rhs.hasSuffix("\"") {
                rhs = String(rhs.dropFirst().dropLast())
            }
            return rhs
                .split(separator: ";")
                .compactMap { token in
                    let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { return nil }
                    let stem = parts[0].trimmingCharacters(in: .whitespaces)
                    let mode = parts[1].trimmingCharacters(in: .whitespaces)
                    return stem.isEmpty ? nil : (stem, mode)
                }
        }
        return []
    }

    private static func readRegistrySectionKeys(in regText: String, sectionPath: String) -> [String] {
        let lines = regText.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let range = PathSafety.findSectionRange(in: lines, header: "[\(sectionPath)]") else {
            return []
        }
        return lines[(range.start + 1)..<range.end].compactMap { rawLine in
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix(";"), !trimmed.hasPrefix("#") else { return nil }
            return parseRegistryKey(fromLine: trimmed)
        }
    }

    private static func parseRegistryKey(fromLine trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix("\"") else { return nil }
        guard let eqIdx = trimmedLine.firstIndex(of: "=") else { return nil }
        let lhs = String(trimmedLine[..<eqIdx]).trimmingCharacters(in: .whitespaces)
        guard lhs.count >= 2, lhs.hasPrefix("\""), lhs.hasSuffix("\"") else { return nil }
        return String(lhs.dropFirst().dropLast())
    }

    private static func insertionIndex(in lines: [String], bodyStart: Int, end: Int) -> Int {
        var lastNonEmpty = bodyStart
        for idx in bodyStart..<end {
            if !lines[idx].trimmingCharacters(in: .whitespaces).isEmpty {
                lastNonEmpty = idx + 1
            }
        }
        return lastNonEmpty
    }
}
