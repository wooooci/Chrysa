import Foundation
import ChrysaCore
import ChrysaApplication

/// The compile-time registration and platform implementation for the application ports.
package struct DefaultWorkflowServices: WorkflowServices {
    private let download: DownloadService
    private let unpack: UnpackService
    private let patch: PatchService
    private let launcher: GameLauncher
    private let supervisor: ProcessSupervisor

    package init(
        download: DownloadService = DownloadService(),
        unpack: UnpackService = UnpackService(),
        patch: PatchService = PatchService(),
        launcher: GameLauncher = GameLauncher(),
        supervisor: ProcessSupervisor = .shared
    ) {
        self.download = download
        self.unpack = unpack
        self.patch = patch
        self.launcher = launcher
        self.supervisor = supervisor
    }

    package func downloadStage(title: String, resolved: ResolvedDownload, settings: AppSettings) -> any Stage {
        DownloadStage(service: download, currentTitle: title, resolved: resolved, settings: settings)
    }

    package func unpackStage(passwords: [String], deleteArchive: Bool) -> any Stage {
        UnpackStage(service: unpack, candidatePasswords: passwords, deleteArchiveAfterUnpack: deleteArchive)
    }

    package func patchStage(title: String, settings: AppSettings) -> any Stage {
        PatchStage(service: patch, settings: settings, cleanTitle: title)
    }

    package func launchStage(request: GameLaunchRequest) -> any Stage {
        LaunchGameStage(service: launcher, request: request)
    }

    package func allStages(for kind: JobKind, job: Job, settings: AppSettings) -> [any Stage] {
        switch kind {
        case .download:
            let origin = job.source?.value ?? job.input?.value ?? ""
            let target = job.input?.value ?? origin
            let resolved = ResolvedDownload(originalURL: origin, finalURL: target, headers: [], suggestedFilename: job.title)
            return [downloadStage(title: job.title, resolved: resolved, settings: settings)]
        case .unpack:
            return [unpackStage(passwords: [""] + settings.unpack.passwords, deleteArchive: settings.unpack.deleteArchiveAfterUnpack)]
        case .patch:
            return [patchStage(title: job.title, settings: settings)]
        }
    }

    package func normalizeDownloadInput(_ input: String) -> String? {
        HostResolverRegistry.normalizeDownloadInput(input)
    }

    package func initialDownloadMessage(for input: String) -> String? {
        HostResolverRegistry.initialDownloadMessage(for: input)
    }

    package func suggestedDownloadName(_ input: String) -> String? {
        let last = URL(string: input)?.lastPathComponent ?? ""
        return HostResolverRegistry.decodeBase64FilenameIfPossible(last) ?? (last.isEmpty ? nil : last)
    }

    package func resolveDownloads(_ input: String, passwords: [String]) async -> [ResolvedDownload] {
        await HostResolverRegistry.resolveLinks(input, passwords: passwords)
    }

    package func refreshDownload(_ item: ResolvedDownload) async -> ResolvedDownload {
        await MailRuResolver.refreshURLIfNeeded(item)
    }

    package func isArchiveFile(_ path: String) -> Bool { UnpackService.isArchiveFile(path) }
    package func normalizeArchivePath(_ path: String) -> String { UnpackService.normalizeMultipartArchivePath(path) }
    package func fileSize(_ path: String) -> Int64? {
        try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64
    }
    package func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    package func resolveDroppedFile(_ url: URL) async -> (kind: JobKind, path: String) {
        await Task.detached(priority: .utility) {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                if let items = try? FileManager.default.contentsOfDirectory(atPath: url.path),
                   let archive = items.sorted().first(where: UnpackService.isArchiveFile) {
                    return (.unpack, url.appendingPathComponent(archive).path)
                }
                return (.patch, url.path)
            }
            if UnpackService.isArchiveFile(url.path) { return (.unpack, url.path) }
            if url.pathExtension.lowercased() == "exe" {
                return UnpackService.isInnoSetupInstaller(url.path)
                    ? (.unpack, url.path)
                    : (.patch, url.deletingLastPathComponent().path)
            }
            return (.download, url.path)
        }.value
    }

    package func scanBottles(directory: String) async -> [LaunchGame] {
        let scan = Task.detached(priority: .utility) {
            CrossOverBottleScanner.scanInstalledBottles(bottlesDirectory: directory)
        }
        return await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
    }

    package func inspectGameForImport(at url: URL, bottlesDirectory: String) async -> LaunchGame? {
        await Task.detached(priority: .utility) {
            Self.inspectGameImportSync(at: url, bottlesDirectory: bottlesDirectory)
        }.value
    }

    private static func inspectGameImportSync(at url: URL, bottlesDirectory: String) -> LaunchGame? {
        let fm = FileManager.default
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else {
            return nil
        }

        let bottlesRoot = (bottlesDirectory as NSString).expandingTildeInPath
        let genericFolderNames: Set<String> = [
            "downloads", "desktop", "documents", "applications", "drive_c",
            "win64", "win32", "x64", "x86", "bin", "binaries", "program files", "program files (x86)"
        ]

        func detectBottleName(exeOrDirPath: String, title: String) -> String? {
            let canonicalTarget = LaunchGame.canonicalPath(exeOrDirPath) ?? exeOrDirPath
            let canonicalBottlesRoot = LaunchGame.canonicalPath(bottlesRoot) ?? bottlesRoot
            if canonicalTarget.hasPrefix(canonicalBottlesRoot + "/") {
                let rel = String(canonicalTarget.dropFirst((canonicalBottlesRoot + "/").count))
                if let bottle = rel.components(separatedBy: "/").first, !bottle.isEmpty {
                    return bottle
                }
            }
            if let bottles = try? fm.contentsOfDirectory(atPath: bottlesRoot) {
                let normTitle = LaunchGame.normalizedIdentityTitle(title)
                if !normTitle.isEmpty,
                   let match = bottles.first(where: { LaunchGame.normalizedIdentityTitle($0) == normTitle }) {
                    return match
                }
            }
            return nil
        }

        // 1. Direct .exe file import
        if !isDirectory.boolValue {
            guard standardized.pathExtension.lowercased() == "exe" else { return nil }
            let parentDir = standardized.deletingLastPathComponent()
            let parentName = parentDir.lastPathComponent
            let rawTitleSource = genericFolderNames.contains(parentName.lowercased())
                ? standardized.deletingPathExtension().lastPathComponent
                : parentName
            let cleaned = GameTitle.cleanGameTitle(from: rawTitleSource)
            let title = cleaned.isEmpty ? rawTitleSource : cleaned

            let appIDPath = parentDir.appendingPathComponent("steam_appid.txt").path
            let appID = (try? String(contentsOfFile: appIDPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanAppID = (appID?.isEmpty == false) ? appID : nil
            let bottle = detectBottleName(exeOrDirPath: standardized.path, title: title)

            return LaunchGame(
                title: title,
                exePath: standardized.path,
                gameDirectory: parentDir.path,
                bottleName: bottle,
                appID: cleanAppID,
                source: .manualImport
            )
        }

        // 2. CrossOver helper .app bundle import
        if standardized.pathExtension.lowercased() == "app" {
            let infoPlistPath = standardized.appendingPathComponent("Contents/Info.plist").path
            if let dict = NSDictionary(contentsOfFile: infoPlistPath) as? [String: Any],
               let bottleName = dict["CXHelperAppBottleName"] as? String {
                let title = (dict["CFBundleName"] as? String) ?? standardized.deletingPathExtension().lastPathComponent
                let bottlePath = (bottlesRoot as NSString).appendingPathComponent(bottleName)
                let scanned = CrossOverBottleScanner.scanInstalledBottles(bottlesDirectory: bottlesRoot)
                    .first(where: { $0.bottleName == bottleName })
                return LaunchGame(
                    title: title,
                    exePath: scanned?.exePath,
                    gameDirectory: scanned?.gameDirectory ?? bottlePath,
                    bottleName: bottleName,
                    appID: scanned?.appID,
                    source: .manualImport
                )
            }
        }

        // 3. Game directory import
        var candidateEXEs: [String] = []
        var unityDataDirs: [String] = []
        var foundAppID: String? = nil
        var discoveredTitle: String? = nil

        let commonDir = standardized.appendingPathComponent("steamapps/common").path
        if let items = try? fm.contentsOfDirectory(atPath: commonDir) {
            for item in items where !item.hasPrefix(".") {
                var subDir: ObjCBool = false
                let fullSub = (commonDir as NSString).appendingPathComponent(item)
                if fm.fileExists(atPath: fullSub, isDirectory: &subDir), subDir.boolValue {
                    discoveredTitle = item
                    break
                }
            }
        }

        if let enumerator = fm.enumerator(atPath: standardized.path) {
            while let rel = enumerator.nextObject() as? String {
                let relLower = rel.lowercased()
                let lower = (rel as NSString).lastPathComponent.lowercased()
                let full = (standardized.path as NSString).appendingPathComponent(rel)

                if lower == "steam_appid.txt", foundAppID == nil {
                    let txt = (try? String(contentsOfFile: full, encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let t = txt, !t.isEmpty { foundAppID = t }
                } else if lower.hasPrefix("appmanifest_") && lower.hasSuffix(".acf") {
                    if foundAppID == nil,
                       let m = try? NSRegularExpression(pattern: #"appmanifest_([0-9]+)\.acf"#).firstMatch(
                        in: lower, range: NSRange(lower.startIndex..., in: lower)
                       ), let r = Range(m.range(at: 1), in: lower) {
                        foundAppID = String(lower[r])
                    }
                    if let acfText = try? String(contentsOfFile: full, encoding: .utf8),
                       let nmMatch = try? NSRegularExpression(pattern: #""name"\s+"([^"]+)""#).firstMatch(
                        in: acfText, range: NSRange(acfText.startIndex..., in: acfText)
                       ), let nr = Range(nmMatch.range(at: 1), in: acfText) {
                        discoveredTitle = String(acfText[nr])
                    }
                } else if lower.hasSuffix("_data") {
                    var subIsDir: ObjCBool = false
                    if fm.fileExists(atPath: full, isDirectory: &subIsDir), subIsDir.boolValue {
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

        let mainEXE = matchedUnityEXE ?? candidateEXEs.max { a, b in
            let depthA = a.components(separatedBy: "/").count
            let depthB = b.components(separatedBy: "/").count
            if depthA != depthB {
                return depthA > depthB
            }
            let sa = (try? fm.attributesOfItem(atPath: a)[.size] as? Int64) ?? 0
            let sb = (try? fm.attributesOfItem(atPath: b)[.size] as? Int64) ?? 0
            return sa < sb
        }

        let rawFolderTitle = discoveredTitle ?? standardized.lastPathComponent
        let cleanedTitle = GameTitle.cleanGameTitle(from: rawFolderTitle)
        let title = cleanedTitle.isEmpty ? rawFolderTitle : cleanedTitle
        let bottle = detectBottleName(exeOrDirPath: mainEXE ?? standardized.path, title: title)

        return LaunchGame(
            title: title,
            exePath: mainEXE,
            gameDirectory: standardized.path,
            bottleName: bottle,
            appID: foundAppID,
            source: .manualImport
        )
    }

    package func mergeDLC(installer: String, directory: String, taskID: UUID) async -> Bool {
        await unpack.mergeGOGDLCInstaller(dlcExePath: installer, intoDir: directory, taskID: taskID)
    }

    package func cancel(taskID: UUID) async { await supervisor.cancel(taskID: taskID) }
    package func clearCancellation(taskID: UUID) async { await supervisor.clearCancellation(for: taskID) }

    package func deleteDownloadedFile(_ path: String, downloadDirectory: String) throws -> Bool {
        guard let target = safeDownloadedFile(path, directory: downloadDirectory) else { return false }
        try FileManager.default.removeItem(at: target)
        if let sidecar = safeDownloadedFile(target.path + ".aria2", directory: downloadDirectory) {
            try? FileManager.default.removeItem(at: sidecar)
        }
        return true
    }

    private func safeDownloadedFile(_ path: String, directory: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty,
              let root = try? PathSafety.canonicalDirectory(directory),
              let contained = PathSafety.containedURL(URL(fileURLWithPath: expanded).standardizedFileURL, in: root),
              contained.path != root.path,
              let values = try? contained.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return contained
    }
}
