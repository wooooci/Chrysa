import ChrysaCore
import Foundation

package struct GameDirectoryInspection: @unchecked Sendable {
    package let folderPath: String
    package let mainExecutable: String?
    package let matchedUnityExecutable: String?
    package let candidateExecutables: [String]
    package let unityDataDirectories: [String]
    package let unrealSteamworksDirectories: [String]
    package let existingSteamDLLs: [(path: String, is64Bit: Bool)]
    package let hasWinHTTP: Bool
    package let hasD3D12: Bool
    package let existingAppID: String?
    package let resolvedTitle: String
    package let executableTitleHint: String?
}

package enum GameDirectoryInspector {
    package static let genericFolderNames: Set<String> = [
        "downloads", "desktop", "documents", "applications", "drive_c",
        "win64", "win32", "win_x64", "win_x86", "x64", "x86", "x86_64", "amd64",
        "bin", "bin64", "bin32", "binaries",
        "program files", "program files (x86)", "game", "release", "shipping", "retail", "windowsnoeditor"
    ]

    fileprivate static let ignoredSubdirectoryNames: Set<String> = [
        "steamapps", "redist", "_commonredist", "__redist", "commonredist",
        "redistributables", "directx", "support", "_support", "extras", "bonus",
        "soundtrack", "ost", "__macosx", "crack", "nodvd", "update", "updates",
        "engine", "plugins", "content", "resources", "windows", "macos"
    ]

    package static let genericExecutableStems: Set<String> = [
        "game", "launcher", "start", "play", "client", "main", "app", "bin", "run"
    ]

    package static let emulatorINIFileNames: [String] = [
        "steam_emu.ini",
        "codex.ini",
        "steam_api.ini",
        "ali213.ini",
        "flt.ini",
        "valve.ini",
        "tenoke.ini",
        "cream_api.ini",
        "rld.ini",
        "skidrow.ini"
    ]

    package static func stripExecutableVariantSuffixes(_ raw: String) -> String {
        var value = raw
        for suffix in ["-Win64-Shipping", "-Win32-Shipping", "-Mac-Shipping", "_Win64", "_x64"] {
            if value.lowercased().hasSuffix(suffix.lowercased()) {
                value = String(value.dropLast(suffix.count))
            }
        }
        return value
    }

    package static func inspect(
        directory: String,
        fallbackTitle: String? = nil,
        skipWindowsSubtrees: Bool = false,
        isCancelled: () -> Bool = { false }
    ) -> GameDirectoryInspection? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue,
              !isCancelled() else {
            return nil
        }

        var state = DirectoryScanState(folderPath: directory, fm: fm)
        state.scanImmediateMetadata()

        if let enumerator = fm.enumerator(atPath: directory) {
            while let rel = enumerator.nextObject() as? String {
                if isCancelled() { return nil }
                state.processEntry(rel: rel, enumerator: enumerator, skipWindowsSubtrees: skipWindowsSubtrees)
            }
        }

        return state.finalize(fallbackTitle: fallbackTitle)
    }

    package static func inspect(
        directory: String,
        fallbackTitle: String? = nil,
        skipWindowsSubtrees: Bool = false,
        cancellationRequested: @Sendable () async -> Bool
    ) async throws -> GameDirectoryInspection {
        func checkCancellation() async throws {
            if Task.isCancelled {
                throw CancellationError()
            }
            if await cancellationRequested() {
                throw CancellationError()
            }
        }

        let fm = FileManager.default
        try await checkCancellation()

        // Read the root explicitly so missing or inaccessible input cannot become an empty successful scan.
        _ = try fm.contentsOfDirectory(atPath: directory)

        var state = DirectoryScanState(folderPath: directory, fm: fm)
        state.scanImmediateMetadata()

        if let enumerator = fm.enumerator(atPath: directory) {
            while let rel = enumerator.nextObject() as? String {
                try await checkCancellation()
                state.processEntry(rel: rel, enumerator: enumerator, skipWindowsSubtrees: skipWindowsSubtrees)
            }
        }

        return state.finalize(fallbackTitle: fallbackTitle)
    }

    /// Reads a Steam AppID from `steam_appid.txt` or known emulator INIs located directly in `directory`.
    package static func findDirectAppID(inDirectory directory: String) -> String? {
        let fm = FileManager.default
        let txtPath = (directory as NSString).appendingPathComponent("steam_appid.txt")
        var sawSpacewar = false
        if fm.fileExists(atPath: txtPath), let parsed = parseSteamAppIDText(atPath: txtPath) {
            if parsed != "480" {
                return parsed
            }
            sawSpacewar = true
        }
        for iniName in emulatorINIFileNames {
            let iniPath = (directory as NSString).appendingPathComponent(iniName)
            if fm.fileExists(atPath: iniPath), let parsed = parseEmulatorINIAppID(atPath: iniPath), parsed != "480" {
                return parsed
            }
        }
        return sawSpacewar ? "480" : nil
    }

    package static func parseSteamAppIDText(atPath path: String) -> String? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let cleaned = raw
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstToken = cleaned.components(separatedBy: .whitespacesAndNewlines).first,
              isValidSteamAppID(firstToken) else {
            return nil
        }
        return firstToken
    }

    package static func parseEmulatorINIAppID(atPath path: String) -> String? {
        let content = (try? String(contentsOfFile: path, encoding: .utf8))
            ?? (try? String(contentsOfFile: path, encoding: .isoLatin1))
        guard let content else { return nil }

        for rawLine in content.components(separatedBy: .newlines) {
            let trimmed = rawLine
                .replacingOccurrences(of: "\u{FEFF}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix(";") || trimmed.hasPrefix("#") || trimmed.hasPrefix("[") || trimmed.hasPrefix("//") {
                continue
            }
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eqIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard key == "appid" || key == "app_id" else { continue }

            var value = String(trimmed[trimmed.index(after: eqIndex)...])
            if let commentIdx = value.firstIndex(where: { $0 == ";" || $0 == "#" }) {
                value = String(value[..<commentIdx])
            }
            value = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if isValidSteamAppID(value) {
                return value
            }
        }
        return nil
    }

    private static func isValidSteamAppID(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy(\.isNumber) && value != "0"
    }
}

private struct DirectoryScanState {
    struct AppIDCandidate {
        let appID: String
        let depth: Int
        let priority: Int
    }

    struct ManifestCandidate {
        let appID: String?
        let name: String?
    }

    let folderPath: String
    let fm: FileManager

    var existingSteamDLLs: [(path: String, is64Bit: Bool)] = []
    var candidateEXEs: [String] = []
    var unityDataDirectories: [String] = []
    var unrealSteamworksDirectories: [String] = []
    var hasD3D12 = false
    var hasWinHTTP = false

    var commonDirGameTitle: String? = nil
    var manifestCandidates: [ManifestCandidate] = []
    var nonSpacewarTextAppIDs: [AppIDCandidate] = []
    var sawSpacewarTextAppID = false
    var iniAppIDCandidates: [AppIDCandidate] = []

    mutating func scanImmediateMetadata() {
        let commonDir = (folderPath as NSString).appendingPathComponent("steamapps/common")
        if let items = try? fm.contentsOfDirectory(atPath: commonDir) {
            var nonSharedFirst: String? = nil
            var anyFirst: String? = nil
            for item in items.sorted() where !item.hasPrefix(".") {
                var isDir: ObjCBool = false
                let fullSub = (commonDir as NSString).appendingPathComponent(item)
                guard fm.fileExists(atPath: fullSub, isDirectory: &isDir), isDir.boolValue else { continue }
                if anyFirst == nil { anyFirst = item }
                if item.lowercased() != "steamworks shared" && nonSharedFirst == nil {
                    nonSharedFirst = item
                    break
                }
            }
            commonDirGameTitle = nonSharedFirst ?? anyFirst
        }
    }

    mutating func processEntry(
        rel: String,
        enumerator: FileManager.DirectoryEnumerator,
        skipWindowsSubtrees: Bool
    ) {
        let relLower = rel.lowercased()
        if skipWindowsSubtrees && (relLower == "drive_c/windows" || relLower.hasPrefix("drive_c/windows/") || relLower.hasPrefix("windows/")) {
            enumerator.skipDescendants()
            return
        }

        let lastComp = (rel as NSString).lastPathComponent
        let lower = lastComp.lowercased()
        let full = (folderPath as NSString).appendingPathComponent(rel)
        let depth = rel.split(separator: "/").count

        if lower == "steam_api64.dll" {
            existingSteamDLLs.append((full, true))
        } else if lower == "steam_api.dll" {
            existingSteamDLLs.append((full, false))
        } else if lower == "winhttp.dll" {
            hasWinHTTP = true
        } else if lower.hasSuffix("_data") {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                unityDataDirectories.append(full)
            }
        } else if relLower.contains("engine/binaries/thirdparty/steamworks") {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                unrealSteamworksDirectories.append(full)
            }
        } else if lower == "steam_appid.txt" {
            if let parsed = GameDirectoryInspector.parseSteamAppIDText(atPath: full) {
                if parsed == "480" {
                    sawSpacewarTextAppID = true
                } else {
                    nonSpacewarTextAppIDs.append(AppIDCandidate(appID: parsed, depth: depth, priority: 0))
                }
            }
        } else if let iniPriority = GameDirectoryInspector.emulatorINIFileNames.firstIndex(of: lower) {
            if let parsed = GameDirectoryInspector.parseEmulatorINIAppID(atPath: full), parsed != "480" {
                iniAppIDCandidates.append(AppIDCandidate(appID: parsed, depth: depth, priority: iniPriority))
            }
        } else if lower.hasPrefix("appmanifest_") && lower.hasSuffix(".acf") {
            var acfID: String? = nil
            var acfName: String? = nil
            if let m = Self.acfIDRegex?.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
               let r = Range(m.range(at: 1), in: lower) {
                acfID = String(lower[r])
            }
            if let acfText = try? String(contentsOfFile: full, encoding: .utf8),
               let nmMatch = Self.acfNameRegex?.firstMatch(in: acfText, range: NSRange(acfText.startIndex..., in: acfText)),
               let nr = Range(nmMatch.range(at: 1), in: acfText) {
                acfName = String(acfText[nr])
            }
            manifestCandidates.append(ManifestCandidate(appID: acfID, name: acfName))
        } else if lower == "d3d12" || lower == "d3d12core.dll" {
            hasD3D12 = true
        } else if lower.hasSuffix(".exe"), !LaunchGame.isIgnoredHelperExecutable(rel) {
            candidateEXEs.append(full)
        }
    }

    func finalize(fallbackTitle: String?) -> GameDirectoryInspection {
        let matchedUnityEXE = resolveMatchedUnityExecutable()
        let mainEXE = matchedUnityEXE ?? resolvePrimaryCandidateExecutable()

        let rawFallback = (fallbackTitle?.isEmpty == false)
            ? fallbackTitle!
            : (folderPath as NSString).lastPathComponent
        let cleanedFallback = GameTitle.cleanGameTitle(from: rawFallback)
        let effectiveFallback = cleanedFallback.isEmpty ? rawFallback : cleanedFallback

        let exeStemTitle = resolveExecutableStemTitle(
            matchedUnityEXE: matchedUnityEXE,
            mainEXE: mainEXE
        )
        let resolvedTitle = resolveInternalTitle(
            mainEXE: mainEXE,
            exeStemTitle: exeStemTitle,
            fallbackTitle: effectiveFallback
        )
        let existingAppID = resolveExistingAppID()

        return GameDirectoryInspection(
            folderPath: folderPath,
            mainExecutable: mainEXE,
            matchedUnityExecutable: matchedUnityEXE,
            candidateExecutables: candidateEXEs,
            unityDataDirectories: unityDataDirectories,
            unrealSteamworksDirectories: unrealSteamworksDirectories,
            existingSteamDLLs: existingSteamDLLs,
            hasWinHTTP: hasWinHTTP,
            hasD3D12: hasD3D12,
            existingAppID: existingAppID,
            resolvedTitle: resolvedTitle,
            executableTitleHint: exeStemTitle
        )
    }

    private func resolveMatchedUnityExecutable() -> String? {
        for dataDir in unityDataDirectories {
            let dirName = (dataDir as NSString).lastPathComponent
            if dirName.lowercased().hasSuffix("_data") {
                let prefix = String(dirName.dropLast("_data".count))
                let parent = (dataDir as NSString).deletingLastPathComponent
                let expectedEXE = (parent as NSString).appendingPathComponent("\(prefix).exe")
                if fm.fileExists(atPath: expectedEXE) {
                    return expectedEXE
                }
                if let ciMatch = candidateEXEs.first(where: {
                    (($0 as NSString).lastPathComponent as NSString).deletingPathExtension.caseInsensitiveCompare(prefix) == .orderedSame
                }) {
                    return ciMatch
                }
            }
        }
        return nil
    }

    private func resolvePrimaryCandidateExecutable() -> String? {
        candidateEXEs.max { a, b in
            let depthA = a.components(separatedBy: "/").count
            let depthB = b.components(separatedBy: "/").count
            if depthA != depthB {
                return depthA > depthB
            }
            let sa = (try? fm.attributesOfItem(atPath: a)[.size] as? Int64) ?? 0
            let sb = (try? fm.attributesOfItem(atPath: b)[.size] as? Int64) ?? 0
            return sa < sb
        }
    }

    private func resolveExistingAppID() -> String? {
        let nonRedistManifest = manifestCandidates.first { candidate in
            candidate.appID != "228980" && candidate.appID != nil && candidate.appID != "0" && candidate.appID != "480"
        } ?? manifestCandidates.first { $0.appID != nil && $0.appID != "0" && $0.appID != "480" }
        if let acfID = nonRedistManifest?.appID {
            return acfID
        }

        if let bestTxt = nonSpacewarTextAppIDs.min(by: { $0.depth < $1.depth }) {
            return bestTxt.appID
        }

        if let bestINI = iniAppIDCandidates.min(by: {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.depth < $1.depth
        }) {
            return bestINI.appID
        }

        if sawSpacewarTextAppID {
            return "480"
        }

        return manifestCandidates.first?.appID
    }

    private func resolveExecutableStemTitle(matchedUnityEXE: String?, mainEXE: String?) -> String? {
        if let unityEXE = matchedUnityEXE {
            let exeDir = (unityEXE as NSString).deletingLastPathComponent
            let exeStem = ((unityEXE as NSString).lastPathComponent as NSString).deletingPathExtension
            if let matchedData = unityDataDirectories.first(where: { dataDir in
                let dataName = (dataDir as NSString).lastPathComponent
                guard dataName.lowercased().hasSuffix("_data") else { return false }
                let prefix = String(dataName.dropLast("_data".count))
                return (dataDir as NSString).deletingLastPathComponent == exeDir
                    && prefix.caseInsensitiveCompare(exeStem) == .orderedSame
            }) {
                let dataName = (matchedData as NSString).lastPathComponent
                let prefix = String(dataName.dropLast("_data".count))
                let cleaned = GameTitle.cleanGameTitle(from: prefix)
                return cleaned.isEmpty ? prefix : cleaned
            }
        }

        guard let mainEXE else { return nil }
        let rawStem = ((mainEXE as NSString).lastPathComponent as NSString).deletingPathExtension
        let stripped = GameDirectoryInspector.stripExecutableVariantSuffixes(rawStem)
        let cleaned = GameTitle.cleanGameTitle(from: stripped)
        return cleaned.isEmpty ? stripped : cleaned
    }

    private func resolveInternalTitle(
        mainEXE: String?,
        exeStemTitle: String?,
        fallbackTitle: String
    ) -> String {
        // 1. Steam manifest or steamapps/common directory name
        let nonRedistManifestName = manifestCandidates.first { candidate in
            candidate.appID != "228980"
                && (candidate.name?.isEmpty == false)
                && candidate.name?.lowercased() != "steamworks common redistributables"
        }?.name ?? manifestCandidates.first(where: { $0.name?.isEmpty == false })?.name
        if let acfName = nonRedistManifestName {
            return acfName
        }
        if let commonTitle = commonDirGameTitle, !commonTitle.isEmpty {
            return commonTitle
        }

        // 2. Non-generic ancestor directory of mainEXE strictly below folderPath
        if let mainEXE, let ancestorTitle = resolveMainExecutableAncestorTitle(mainEXE: mainEXE) {
            return ancestorTitle
        }

        // 3. When mainEXE sits directly at folderPath root, trim trailing group/version tags matching exe/Unity stem
        if let exeStemTitle, let matched = extractTitleFromStemPrefix(exeStem: exeStemTitle, fallbackTitle: fallbackTitle) {
            return matched
        }

        return fallbackTitle
    }

    private func resolveMainExecutableAncestorTitle(mainEXE: String) -> String? {
        let rootURL = URL(fileURLWithPath: folderPath).standardizedFileURL
        let rootPath = rootURL.path
        var cursorURL = URL(fileURLWithPath: mainEXE).standardizedFileURL.deletingLastPathComponent()

        while cursorURL.path != rootPath && cursorURL.path.hasPrefix(rootPath + "/") {
            let dirName = cursorURL.lastPathComponent
            let lower = dirName.lowercased()
            if !dirName.isEmpty,
               !dirName.hasPrefix("."),
               !GameDirectoryInspector.genericFolderNames.contains(lower),
               !GameDirectoryInspector.ignoredSubdirectoryNames.contains(lower),
               !lower.hasSuffix("_data") {
                let cleaned = GameTitle.cleanGameTitle(from: dirName)
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
            let parent = cursorURL.deletingLastPathComponent()
            if parent.path == cursorURL.path { break }
            cursorURL = parent
        }
        return nil
    }

    private func extractTitleFromStemPrefix(exeStem: String, fallbackTitle: String) -> String? {
        let condensedStem = Self.condenseAlphanumerics(exeStem)
        guard condensedStem.count >= 3,
              !GameDirectoryInspector.genericExecutableStems.contains(condensedStem) else {
            return nil
        }

        let fallbackTrimmed = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackLower = fallbackTrimmed.lowercased()
        if fallbackTrimmed.isEmpty
            || fallbackTrimmed.allSatisfy(\.isNumber)
            || GameDirectoryInspector.genericFolderNames.contains(fallbackLower) {
            return exeStem
        }

        let condensedFallback = Self.condenseAlphanumerics(fallbackTrimmed)
        guard condensedFallback.count > condensedStem.count,
              condensedFallback.hasPrefix(condensedStem) else {
            return nil
        }

        // Map the matched condensed stem length back onto fallbackTrimmed to preserve spaces and casing.
        var matchedCount = 0
        var endIndex = fallbackTrimmed.startIndex
        for idx in fallbackTrimmed.indices {
            let ch = fallbackTrimmed[idx]
            if ch.isLetter || ch.isNumber {
                matchedCount += 1
            }
            if matchedCount == condensedStem.count {
                endIndex = fallbackTrimmed.index(after: idx)
                break
            }
        }
        guard matchedCount == condensedStem.count else { return nil }

        let remainder = fallbackTrimmed[endIndex...].trimmingCharacters(in: .whitespaces)
        guard remainder.isEmpty || remainder.first.map({ "-_[(|+".contains($0) }) == true else {
            return nil
        }

        let prefix = String(fallbackTrimmed[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? exeStem : prefix
    }

    private static func condenseAlphanumerics(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static let acfIDRegex = try? NSRegularExpression(pattern: #"appmanifest_([0-9]+)\.acf"#)
    private static let acfNameRegex = try? NSRegularExpression(pattern: #""name"\s+"([^"]+)""#)
}
