import Foundation
import ChrysaCore
import ChrysaApplication

/// The compile-time registration and platform implementation for the application ports.
package struct DefaultWorkflowServices: WorkflowServices {
    private let download: DownloadService
    private let unpack: UnpackService
    private let patch: PatchService
    private let launcher: GameLauncher
    private let iconResolver: GameIconResolver
    private let supervisor: ProcessSupervisor

    package init(
        download: DownloadService = DownloadService(),
        unpack: UnpackService = UnpackService(),
        patch: PatchService = PatchService(),
        launcher: GameLauncher = GameLauncher(),
        iconResolver: GameIconResolver = .shared,
        supervisor: ProcessSupervisor = .shared
    ) {
        self.download = download
        self.unpack = unpack
        self.patch = patch
        self.launcher = launcher
        self.iconResolver = iconResolver
        self.supervisor = supervisor
    }

    package func downloadStage(title: String, resolved: ResolvedDownload, settings: AppSettings) -> any Stage {
        DownloadStage(service: download, currentTitle: title, resolved: resolved, settings: settings)
    }

    package func downloadStage(
        title: String,
        resolved: ResolvedDownload,
        stagingJobID: UUID,
        stagingSubkey: String?,
        settings: AppSettings
    ) -> any Stage {
        DownloadStage(
            service: download,
            currentTitle: title,
            resolved: resolved,
            stagingJobID: stagingJobID,
            stagingSubkey: stagingSubkey,
            settings: settings
        )
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

    package func knownBareHostDomains() -> [String] {
        HostResolverRegistry.knownBareDomains
    }

    package func initialDownloadMessage(for input: String) -> String? {
        HostResolverRegistry.initialDownloadMessage(for: input)
    }

    package func suggestedDownloadName(_ input: String) -> String? {
        if let inferred = DownloadInputParser.inferFilenameFromURL(input) {
            return HostResolverRegistry.decodeBase64FilenameIfPossible(inferred) ?? inferred
        }
        let last = URL(string: input)?.lastPathComponent ?? ""
        return HostResolverRegistry.decodeBase64FilenameIfPossible(last) ?? (last.isEmpty ? nil : last)
    }

    package func resolveDownloads(_ input: String, passwords: [String]) async -> [ResolvedDownload] {
        await HostResolverRegistry.resolveLinks(input, passwords: passwords)
    }

    package func resolveDownloads(_ input: String, passwords: [String], settings: AppSettings) async -> [ResolvedDownload] {
        await HostResolverRegistry.resolveLinks(input, passwords: passwords, settings: settings.download)
    }

    package func resolveDownloadsDetailed(_ input: String, passwords: [String]) async -> HostResolutionResult {
        await HostResolverRegistry.resolveLinksDetailed(input, passwords: passwords)
    }

    package func resolveDownloadsDetailed(_ input: String, passwords: [String], settings: AppSettings) async -> HostResolutionResult {
        await HostResolverRegistry.resolveLinksDetailed(input, passwords: passwords, settings: settings.download)
    }

    package func refreshDownload(_ item: ResolvedDownload) async -> ResolvedDownload {
        await HostResolverRegistry.refreshDownload(item)
    }

    package func refreshDownload(_ item: ResolvedDownload, passwords: [String]) async -> ResolvedDownload {
        await HostResolverRegistry.refreshDownload(item, passwords: passwords)
    }

    package func refreshDownload(_ item: ResolvedDownload, passwords: [String], settings: AppSettings) async -> ResolvedDownload {
        await HostResolverRegistry.refreshDownload(item, passwords: passwords, settings: settings.download)
    }

    package func availableDiskSpace(atDirectory path: String) -> Int64? {
        DiskSpaceHelper.availableBytes(atDirectory: path)
    }

    package func setPreventIdleSleep(_ active: Bool) {
        IdleSleepAssertionManager.shared.setActive(active)
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
        let stopRootPaths: Set<String> = [
            "/",
            NSHomeDirectory(),
            (NSHomeDirectory() as NSString).appendingPathComponent("Downloads"),
            (NSHomeDirectory() as NSString).appendingPathComponent("Desktop"),
            (NSHomeDirectory() as NSString).appendingPathComponent("Documents"),
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
            "/Applications",
            bottlesRoot
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
            var rawTitleSource: String? = nil
            var cleanAppID: String? = nil
            var cursor = parentDir
            for _ in 0..<4 {
                let cursorPath = cursor.path
                if stopRootPaths.contains(cursorPath) { break }
                if cleanAppID == nil,
                   let directAppID = GameDirectoryInspector.findDirectAppID(inDirectory: cursorPath) {
                    cleanAppID = directAppID
                }
                let name = cursor.lastPathComponent
                if rawTitleSource == nil, !name.isEmpty, !GameDirectoryInspector.genericFolderNames.contains(name.lowercased()) {
                    rawTitleSource = name
                }
                let next = cursor.deletingLastPathComponent()
                if next.path == cursorPath { break }
                cursor = next
            }

            let fallbackEXEName = GameDirectoryInspector.stripExecutableVariantSuffixes(standardized.deletingPathExtension().lastPathComponent)
            let finalRawTitle = rawTitleSource ?? fallbackEXEName
            let cleaned = GameTitle.cleanGameTitle(from: finalRawTitle)
            let title = cleaned.isEmpty ? finalRawTitle : cleaned
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

        // 2. .app bundle import (CrossOver helper .app or macOS / standalone wrapper .app)
        if standardized.pathExtension.lowercased() == "app" {
            let infoPlistPath = standardized.appendingPathComponent("Contents/Info.plist").path
            let plistDict = NSDictionary(contentsOfFile: infoPlistPath) as? [String: Any]
            if let bottleName = plistDict?["CXHelperAppBottleName"] as? String {
                let title = (plistDict?["CFBundleName"] as? String) ?? standardized.deletingPathExtension().lastPathComponent
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

            let rawBundleTitle = (plistDict?["CFBundleDisplayName"] as? String)
                ?? (plistDict?["CFBundleName"] as? String)
                ?? standardized.deletingPathExtension().lastPathComponent
            let cleanedTitle = GameTitle.cleanGameTitle(from: rawBundleTitle)
            let title = cleanedTitle.isEmpty ? rawBundleTitle : cleanedTitle

            var foundAppID: String? = nil
            if let enumerator = fm.enumerator(atPath: standardized.path) {
                while let rel = enumerator.nextObject() as? String {
                    if (rel as NSString).lastPathComponent.lowercased() == "steam_appid.txt" {
                        let full = (standardized.path as NSString).appendingPathComponent(rel)
                        if let txt = (try? String(contentsOfFile: full, encoding: .utf8))?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           !txt.isEmpty {
                            foundAppID = txt
                            break
                        }
                    }
                }
            }
            let mainEXE = CrossOverBottleScanner.findMainExecutable(in: standardized.path)
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
        // 3. Game directory import
        let inspection = GameDirectoryInspector.inspect(directory: standardized.path)
        let mainEXE = inspection?.mainExecutable
        let rawTitle = inspection?.resolvedTitle ?? standardized.lastPathComponent
        let cleanedTitle = GameTitle.cleanGameTitle(from: rawTitle)
        let title = cleanedTitle.isEmpty ? rawTitle : cleanedTitle
        let bottle = detectBottleName(exeOrDirPath: mainEXE ?? standardized.path, title: title)

        return LaunchGame(
            title: title,
            exePath: mainEXE,
            gameDirectory: standardized.path,
            bottleName: bottle,
            appID: inspection?.existingAppID,
            source: .manualImport
        )
    }

    package func resolveLaunchGameIcon(_ game: LaunchGame) async -> Data? {
        await iconResolver.resolveIconPNG(for: game)
    }

    package func saveCustomLaunchGameIcon(from sourceURL: URL, for gameID: UUID) async -> String? {
        await iconResolver.saveCustomIcon(from: sourceURL, for: gameID)
    }

    package func removeCustomLaunchGameIcon(at path: String?) async {
        await iconResolver.removeCustomIcon(at: path)
    }

    package func invalidateLaunchGameIconCache(for game: LaunchGame) async {
        await iconResolver.invalidateCache(for: game)
    }

    package func lookupSteamAppID(for title: String) async -> String? {
        await SteamAppIDLookup.fetch(for: title)
    }
    package func mergeDLC(installer: String, directory: String, taskID: UUID) async -> Bool {
        await unpack.mergeGOGDLCInstaller(dlcExePath: installer, intoDir: directory, taskID: taskID)
    }

    package func cancel(taskID: UUID) async { await supervisor.cancel(taskID: taskID) }
    package func clearCancellation(taskID: UUID) async { await supervisor.clearCancellation(for: taskID) }
    package func cleanupStaging(for jobID: UUID, downloadDirectory: String) {
        DownloadService.cleanupStaging(for: jobID, downloadDirectory: downloadDirectory)
    }
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
