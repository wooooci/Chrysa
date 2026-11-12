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

    package func scanBottles(directory: String) async -> [Job] {
        let scan = Task.detached(priority: .utility) {
            CrossOverBottleScanner.scanInstalledBottles(bottlesDirectory: directory)
        }
        return await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
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
