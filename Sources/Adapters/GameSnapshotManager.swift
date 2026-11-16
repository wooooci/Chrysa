import ChrysaCore
import ChrysaApplication
import Darwin
import Foundation

package struct BaselineSnapshotManifest: Codable, Sendable {
    package enum Mode: String, Codable, Sendable {
        case apfsClone
        case incrementalDiff
    }

    package let gameID: UUID
    package let gameDirectory: String
    package let bottleName: String?
    package let mode: Mode
    package let createdAt: Date
    package let baselineExePath: String?
    package let baselineLaunchArguments: String?
    package let baselineProxyOverrides: [String]
    package var backedUpRelativePaths: Set<String>
    package var addedRelativePaths: Set<String>

    package init(
        gameID: UUID,
        gameDirectory: String,
        bottleName: String?,
        mode: Mode,
        createdAt: Date = Date(),
        baselineExePath: String? = nil,
        baselineLaunchArguments: String? = nil,
        baselineProxyOverrides: [String] = [],
        backedUpRelativePaths: Set<String> = [],
        addedRelativePaths: Set<String> = []
    ) {
        self.gameID = gameID
        self.gameDirectory = gameDirectory
        self.bottleName = bottleName
        self.mode = mode
        self.createdAt = createdAt
        self.baselineExePath = baselineExePath
        self.baselineLaunchArguments = baselineLaunchArguments
        self.baselineProxyOverrides = baselineProxyOverrides
        self.backedUpRelativePaths = backedUpRelativePaths
        self.addedRelativePaths = addedRelativePaths
    }
}

package struct OpaqueMutationToken: Sendable {
    package struct FileStamp: Sendable, Equatable {
        package let size: Int64
        package let modifiedAt: Date?
    }

    package let gameID: UUID
    package let gameDirectory: String
    package let snapshotDir: URL
    package let stagingDir: URL
    package let initialFiles: [String: FileStamp]
    package let stagedRelativePaths: Set<String>
}

/// Manages zero-space APFS `clonefile` baseline snapshots (and on-demand diff fallback on non-APFS volumes)
/// so external patches / mods / installers can always be reverted to the clean pre-patch state.
package actor GameSnapshotManager {
    private let explicitStorageRoot: URL?
    private let preferAPFSClone: Bool

    package init(
        storageRoot: URL? = nil,
        forceIncrementalFallback: Bool = false,
        preferAPFSClone: Bool? = nil
    ) {
        self.explicitStorageRoot = storageRoot
        self.preferAPFSClone = preferAPFSClone ?? !forceIncrementalFallback
    }

    // MARK: - Location Resolution

    /// Returns the controlled snapshot directory on the same volume as `gameDirectory` whenever possible.
    package nonisolated func snapshotDirectory(forGameID gameID: UUID, gameDirectory: String?) -> URL? {
        guard let gameDirectory,
              let canonicalGame = try? PathSafety.existingCanonicalDirectory(gameDirectory) else {
            if let root = explicitStorageRoot {
                return root.appendingPathComponent(gameID.uuidString, isDirectory: true)
            }
            return defaultAppSupportSnapshotsRoot().appendingPathComponent(gameID.uuidString, isDirectory: true)
        }

        if let root = explicitStorageRoot {
            return root.appendingPathComponent(gameID.uuidString, isDirectory: true)
        }

        let appSupportRoot = defaultAppSupportSnapshotsRoot()
        let gameVol = volumeMountPoint(for: canonicalGame.path)
        let homeVol = volumeMountPoint(for: FileManager.default.homeDirectoryForCurrentUser.path)

        if let gameVol, let homeVol, gameVol == homeVol {
            return appSupportRoot.appendingPathComponent(gameID.uuidString, isDirectory: true)
        }

        // Different volume (e.g. external SSD): place controlled hidden dir beside the game directory so CoW / rename stays on the same volume.
        let parentDir = canonicalGame.deletingLastPathComponent()
        let siblingSnapshotsRoot = parentDir.appendingPathComponent(".chrysa-snapshots", isDirectory: true)
        return siblingSnapshotsRoot.appendingPathComponent(gameID.uuidString, isDirectory: true)
    }

    private nonisolated func volumeMountPoint(for path: String) -> String? {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return nil }
        return withUnsafePointer(to: st.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    package nonisolated func hasSnapshot(for game: LaunchGame) -> Bool {
        guard let dir = locateExistingSnapshotDirectory(forGameID: game.id, gameDirectory: game.gameDirectory) else {
            return false
        }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path)
    }

    package nonisolated func locateExistingSnapshotDirectory(forGameID gameID: UUID, gameDirectory: String?) -> URL? {
        let fm = FileManager.default
        if let preferred = snapshotDirectory(forGameID: gameID, gameDirectory: gameDirectory),
           fm.fileExists(atPath: preferred.appendingPathComponent("manifest.json").path) {
            return preferred
        }
        let appSupportCandidate = defaultAppSupportSnapshotsRoot().appendingPathComponent(gameID.uuidString, isDirectory: true)
        if fm.fileExists(atPath: appSupportCandidate.appendingPathComponent("manifest.json").path) {
            return appSupportCandidate
        }
        return nil
    }

    package nonisolated func cleanupSnapshot(forGameID gameID: UUID, gameDirectory: String?) {
        let fm = FileManager.default
        if let preferred = snapshotDirectory(forGameID: gameID, gameDirectory: gameDirectory),
           fm.fileExists(atPath: preferred.path) {
            try? fm.removeItem(at: preferred)
        }
        let appSupportCandidate = defaultAppSupportSnapshotsRoot().appendingPathComponent(gameID.uuidString, isDirectory: true)
        if fm.fileExists(atPath: appSupportCandidate.path) {
            try? fm.removeItem(at: appSupportCandidate)
        }
    }

    private nonisolated func defaultAppSupportSnapshotsRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Chrysa", isDirectory: true)
            .appendingPathComponent("Snapshots", isDirectory: true)
    }

    // MARK: - Baseline Snapshot Creation

    /// Creates a baseline snapshot if one does not already exist for `game`, returning the active manifest.
    package func ensureBaselineSnapshot(
        for game: LaunchGame,
        bottlePath: String?,
        onLog: @escaping @Sendable (String, Bool) async -> Void
    ) async throws -> BaselineSnapshotManifest {
        guard let gameDirPath = game.gameDirectory else {
            throw NSError(domain: "Chrysa.Snapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "游戏目录无效"])
        }
        let canonicalGame = try PathSafety.existingCanonicalDirectory(gameDirPath)
        guard let snapDir = snapshotDirectory(forGameID: game.id, gameDirectory: canonicalGame.path) else {
            throw NSError(domain: "Chrysa.Snapshot", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法定位快照目录"])
        }

        let manifestURL = snapDir.appendingPathComponent("manifest.json")
        if let existingData = try? Data(contentsOf: manifestURL),
           let existing = try? JSONDecoder().decode(BaselineSnapshotManifest.self, from: existingData) {
            return existing
        }

        let fm = FileManager.default
        try fm.createDirectory(at: snapDir, withIntermediateDirectories: true)
        let payloadDir = snapDir.appendingPathComponent("payload", isDirectory: true)
        try? fm.removeItem(at: payloadDir)
        try fm.createDirectory(at: payloadDir, withIntermediateDirectories: true)

        let baselineOverrides: [String] = {
            var stems = Set<String>()
            if let bottlePath {
                stems.formUnion(CrossOverRegistryHelper.activeWhitelistOverrides(inBottlePath: bottlePath))
            }
            stems.formUnion(PEBinaryInspector.detectProxyHookDLLs(nearExecutable: game.exePath, gameDirectory: canonicalGame.path))
            return stems.sorted()
        }()

        var mode: BaselineSnapshotManifest.Mode = .apfsClone
        if !preferAPFSClone {
            mode = .incrementalDiff
        } else {
            let clonedOK = Self.cloneDirectoryTreeUsingAPFSClonefile(from: canonicalGame, to: payloadDir)
            if !clonedOK {
                // Volume (e.g. ExFAT / SMB) does not support clonefile CoW; fall back cleanly to on-demand diff backup.
                try? fm.removeItem(at: payloadDir)
                try fm.createDirectory(at: payloadDir, withIntermediateDirectories: true)
                mode = .incrementalDiff
            }
        }

        let manifest = BaselineSnapshotManifest(
            gameID: game.id,
            gameDirectory: canonicalGame.path,
            bottleName: game.bottleName,
            mode: mode,
            createdAt: Date(),
            baselineExePath: game.exePath,
            baselineLaunchArguments: game.launchArguments,
            baselineProxyOverrides: baselineOverrides
        )
        try writeManifest(manifest, to: manifestURL)

        let modeDesc = (mode == .apfsClone)
            ? "APFS 零空间写时复制基准快照"
            : "增量备份基准快照 (非 APFS 卷退化模式)"
        await onLog("snapshot ▸ 已为 [\(game.title)] 建立\(modeDesc)", false)
        return manifest
    }

    // MARK: - Incremental Diff Recording (for non-clonefile volumes)

    /// Before modifying or creating `relativePath` inside `gameDirectory` during an incremental merge,
    /// backs up the existing original file (once) or records the newly added relative path so restore can remove it.
    package func recordIncomingChange(
        relativePath: String,
        gameID: UUID,
        gameDirectory: String
    ) throws {
        guard let snapDir = locateExistingSnapshotDirectory(forGameID: gameID, gameDirectory: gameDirectory) else {
            return
        }
        let manifestURL = snapDir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONDecoder().decode(BaselineSnapshotManifest.self, from: data),
              manifest.mode == .incrementalDiff else {
            return
        }

        let cleanRel = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanRel.isEmpty else { return }

        if manifest.addedRelativePaths.contains(cleanRel) || manifest.backedUpRelativePaths.contains(cleanRel) {
            return
        }

        let canonicalGame = try PathSafety.existingCanonicalDirectory(gameDirectory)
        let gameFileURL = canonicalGame.appendingPathComponent(cleanRel, isDirectory: false).standardizedFileURL
        guard let safeSource = PathSafety.containedURL(gameFileURL, in: canonicalGame) else {
            return
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: safeSource.path) {
            let payloadDir = snapDir.appendingPathComponent("payload", isDirectory: true)
            let destBackup = payloadDir.appendingPathComponent(cleanRel, isDirectory: false).standardizedFileURL
            guard let safeBackup = PathSafety.containedURL(destBackup, in: payloadDir) else { return }
            try fm.createDirectory(at: safeBackup.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: safeBackup.path) {
                try fm.copyItem(at: safeSource, to: safeBackup)
            }
            manifest.backedUpRelativePaths.insert(cleanRel)
        } else {
            manifest.addedRelativePaths.insert(cleanRel)
        }
        try writeManifest(manifest, to: manifestURL)
    }

    /// Captures pre-execution file stamps (and bounded pre-copies <= 32MB / 256MB total) under `incrementalDiff` mode
    /// before launching opaque `.exe` installers or `.bat` scripts.
    package func prepareForOpaqueProcessMutation(for game: LaunchGame) -> OpaqueMutationToken? {
        guard let rawDir = game.gameDirectory,
              let canonicalGame = try? PathSafety.existingCanonicalDirectory(rawDir),
              let snapDir = locateExistingSnapshotDirectory(forGameID: game.id, gameDirectory: canonicalGame.path) else {
            return nil
        }
        let manifestURL = snapDir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BaselineSnapshotManifest.self, from: data),
              manifest.mode == .incrementalDiff else {
            return nil
        }

        let fm = FileManager.default
        let stagingDir = snapDir.appendingPathComponent(".opaque_staging_\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)) != nil else {
            return nil
        }

        let maxSingleFileBytes: Int64 = 32 * 1024 * 1024
        let maxTotalStageBytes: Int64 = 256 * 1024 * 1024
        var stagedTotalBytes: Int64 = 0
        var initialFiles: [String: OpaqueMutationToken.FileStamp] = [:]
        var stagedRelativePaths = Set<String>()

        try? PathSafety.walkDirectory(
            at: canonicalGame,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsPackageDescendants],
            includeSymlinks: false
        ) { itemURL, relativePath, vals in
            guard vals.isRegularFile == true else { return }
            let cleanRel = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !cleanRel.isEmpty else { return }
            let fileSize = Int64(vals.fileSize ?? 0)
            initialFiles[cleanRel] = OpaqueMutationToken.FileStamp(
                size: fileSize,
                modifiedAt: vals.contentModificationDate
            )
            if manifest.backedUpRelativePaths.contains(cleanRel) || manifest.addedRelativePaths.contains(cleanRel) {
                return
            }
            if fileSize <= maxSingleFileBytes, stagedTotalBytes + fileSize <= maxTotalStageBytes {
                let stageDest = stagingDir.appendingPathComponent(cleanRel, isDirectory: false).standardizedFileURL
                if let safeStage = PathSafety.containedURL(stageDest, in: stagingDir) {
                    try? fm.createDirectory(at: safeStage.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if (try? fm.copyItem(at: itemURL, to: safeStage)) != nil {
                        stagedRelativePaths.insert(cleanRel)
                        stagedTotalBytes += fileSize
                    }
                }
            }
        }

        return OpaqueMutationToken(
            gameID: game.id,
            gameDirectory: canonicalGame.path,
            snapshotDir: snapDir,
            stagingDir: stagingDir,
            initialFiles: initialFiles,
            stagedRelativePaths: stagedRelativePaths
        )
    }

    /// Reconciles post-execution directory state with `token` under `incrementalDiff` mode and removes temporary staging.
    package func finalizeOpaqueProcessMutation(_ token: OpaqueMutationToken?) {
        guard let token else { return }
        let fm = FileManager.default
        defer { try? fm.removeItem(at: token.stagingDir) }

        guard let canonicalGame = try? PathSafety.existingCanonicalDirectory(token.gameDirectory) else {
            return
        }
        let manifestURL = token.snapshotDir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONDecoder().decode(BaselineSnapshotManifest.self, from: data),
              manifest.mode == .incrementalDiff else {
            return
        }

        var currentFiles: [String: OpaqueMutationToken.FileStamp] = [:]
        try? PathSafety.walkDirectory(
            at: canonicalGame,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsPackageDescendants],
            includeSymlinks: false
        ) { _, relativePath, vals in
            guard vals.isRegularFile == true else { return }
            let cleanRel = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !cleanRel.isEmpty else { return }
            currentFiles[cleanRel] = OpaqueMutationToken.FileStamp(
                size: Int64(vals.fileSize ?? 0),
                modifiedAt: vals.contentModificationDate
            )
        }

        let payloadDir = token.snapshotDir.appendingPathComponent("payload", isDirectory: true)
        var dirtyManifest = false

        func promoteStagedPreCopy(_ rel: String) {
            guard !manifest.addedRelativePaths.contains(rel),
                  !manifest.backedUpRelativePaths.contains(rel),
                  token.stagedRelativePaths.contains(rel) else {
                return
            }
            let srcStage = token.stagingDir.appendingPathComponent(rel, isDirectory: false).standardizedFileURL
            let dstBackup = payloadDir.appendingPathComponent(rel, isDirectory: false).standardizedFileURL
            guard let safeSrc = PathSafety.containedURL(srcStage, in: token.stagingDir),
                  let safeDst = PathSafety.containedURL(dstBackup, in: payloadDir),
                  fm.fileExists(atPath: safeSrc.path) else {
                return
            }
            if !fm.fileExists(atPath: safeDst.path) {
                try? fm.createDirectory(at: safeDst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.moveItem(at: safeSrc, to: safeDst)
            }
            if fm.fileExists(atPath: safeDst.path) {
                manifest.backedUpRelativePaths.insert(rel)
                dirtyManifest = true
            }
        }

        for (rel, currentStamp) in currentFiles {
            if manifest.addedRelativePaths.contains(rel) || manifest.backedUpRelativePaths.contains(rel) {
                continue
            }
            if let priorStamp = token.initialFiles[rel] {
                if priorStamp != currentStamp {
                    promoteStagedPreCopy(rel)
                }
            } else {
                manifest.addedRelativePaths.insert(rel)
                dirtyManifest = true
            }
        }

        for rel in token.initialFiles.keys where currentFiles[rel] == nil {
            promoteStagedPreCopy(rel)
        }

        if dirtyManifest {
            try? writeManifest(manifest, to: manifestURL)
        }
    }

    // MARK: - Atomic Restore Clean Baseline

    package func restoreBaseline(
        for game: LaunchGame,
        bottlesDirectory: String,
        onLog: @escaping @Sendable (String, Bool) async -> Void
    ) async throws -> (restoredExePath: String?, restoredLaunchArguments: String?, summary: String) {
        guard let gameDirPath = game.gameDirectory else {
            throw NSError(domain: "Chrysa.Snapshot", code: 3, userInfo: [NSLocalizedDescriptionKey: "游戏目录缺失"])
        }
        let canonicalGame = try PathSafety.existingCanonicalDirectory(gameDirPath)
        guard let snapDir = locateExistingSnapshotDirectory(forGameID: game.id, gameDirectory: canonicalGame.path) else {
            throw NSError(domain: "Chrysa.Snapshot", code: 4, userInfo: [NSLocalizedDescriptionKey: "未找到该游戏的原版基准快照"])
        }

        let manifestURL = snapDir.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(BaselineSnapshotManifest.self, from: manifestData)
        let payloadDir = snapDir.appendingPathComponent("payload", isDirectory: true)
        let fm = FileManager.default

        switch manifest.mode {
        case .apfsClone:
            let parentURL = canonicalGame.deletingLastPathComponent()
            let stagingRestore = parentURL.appendingPathComponent(".chrysa-restore-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
            let swappedDirty = parentURL.appendingPathComponent(".chrysa-dirty-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
            var stagingCleaned = false
            defer {
                if !stagingCleaned {
                    try? fm.removeItem(at: stagingRestore)
                }
            }
            try fm.createDirectory(at: stagingRestore, withIntermediateDirectories: true)

            let clonedOK = Self.cloneDirectoryTreeUsingAPFSClonefile(from: payloadDir, to: stagingRestore)
            if !clonedOK {
                // Fallback to regular copy if somehow moving snapshot across dirs failed clonefile.
                try fm.removeItem(at: stagingRestore)
                try fm.copyItem(at: payloadDir, to: stagingRestore)
            }

            try fm.moveItem(at: canonicalGame, to: swappedDirty)
            do {
                try fm.moveItem(at: stagingRestore, to: canonicalGame)
                stagingCleaned = true
            } catch {
                // Roll back original dir immediately if swap move failed.
                try? fm.moveItem(at: swappedDirty, to: canonicalGame)
                throw error
            }
            try? fm.removeItem(at: swappedDirty)

        case .incrementalDiff:
            // 1. Remove files added after baseline.
            for rel in manifest.addedRelativePaths.sorted(by: { $0.count > $1.count }) {
                let target = canonicalGame.appendingPathComponent(rel, isDirectory: false).standardizedFileURL
                if let safeTarget = PathSafety.containedURL(target, in: canonicalGame),
                   safeTarget.path != canonicalGame.path,
                   fm.fileExists(atPath: safeTarget.path) {
                    try? fm.removeItem(at: safeTarget)
                    pruneEmptyParentDirectories(startingAt: safeTarget.deletingLastPathComponent(), stopAt: canonicalGame)
                }
            }
            // 2. Restore original files backed up before modification.
            for rel in manifest.backedUpRelativePaths.sorted() {
                let srcBackup = payloadDir.appendingPathComponent(rel, isDirectory: false).standardizedFileURL
                let destTarget = canonicalGame.appendingPathComponent(rel, isDirectory: false).standardizedFileURL
                guard let safeSrc = PathSafety.containedURL(srcBackup, in: payloadDir),
                      let safeDest = PathSafety.containedURL(destTarget, in: canonicalGame),
                      fm.fileExists(atPath: safeSrc.path) else {
                    continue
                }
                try fm.createDirectory(at: safeDest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: safeDest.path) {
                    try? fm.removeItem(at: safeDest)
                }
                try fm.copyItem(at: safeSrc, to: safeDest)
            }
        }

        // Remove any extra post-installed proxy DLL overrides from the game's CrossOver bottle.
        var removedOverrideCount = 0
        let targetExeForCheck = manifest.baselineExePath ?? game.exePath
        if let resolved = CrossOverRegistryHelper.resolveExistingBottle(
            explicitBottleName: game.bottleName ?? manifest.bottleName,
            gameTitle: game.title,
            exePath: targetExeForCheck,
            bottlesDirectory: bottlesDirectory
        ) {
            let resolvedBottle = resolved.name
            let bottlePath = resolved.path
            let baselineKeep = Set(manifest.baselineProxyOverrides.map { $0.lowercased() })
                .union(PEBinaryInspector.detectProxyHookDLLs(nearExecutable: targetExeForCheck, gameDirectory: canonicalGame.path).map { $0.lowercased() })
            let active = CrossOverRegistryHelper.activeWhitelistOverrides(inBottlePath: bottlePath)
            let staleToRemove = active.filter { !baselineKeep.contains($0.lowercased()) }
            if !staleToRemove.isEmpty {
                try? CrossOverRegistryHelper.syncProxyDLLOverrides(
                    inBottlePath: bottlePath,
                    ensuring: [],
                    removing: staleToRemove
                )
                removedOverrideCount = staleToRemove.count
                await onLog("hook ▸ 已从容器 [\(resolvedBottle)] 清理后装代理 DLL 重写: \(staleToRemove.joined(separator: ", "))", false)
            }
        }

        try? fm.removeItem(at: snapDir)

        let summary = removedOverrideCount > 0
            ? "已恢复至纯净原版并清理 \(removedOverrideCount) 项代理 DLL 重写"
            : "已原子恢复至纯净原版状态"
        await onLog("restore ▸ [\(game.title)] \(summary)", true)
        return (manifest.baselineExePath, manifest.baselineLaunchArguments, summary)
    }

    // MARK: - APFS Copy-on-Write Recursive Clone

    private enum CloneAbort: Error {
        case cloneFailed
    }

    /// Recursively clones `sourceDir` into an already-created empty `destDir` using POSIX `Darwin.clonefile`.
    /// Returns `false` immediately if any regular file fails with `ENOTSUP` or `EXDEV` (never falls back to full byte copy).
    package static func cloneDirectoryTreeUsingAPFSClonefile(from sourceDir: URL, to destDir: URL) -> Bool {
        let fm = FileManager.default
        guard let canonicalSrc = try? PathSafety.existingCanonicalDirectory(sourceDir.path),
              let canonicalDst = try? PathSafety.existingCanonicalDirectory(destDir.path) else {
            return false
        }

        var sawRegularFile = false
        do {
            try PathSafety.walkDirectory(
                at: canonicalSrc,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants],
                includeSymlinks: true
            ) { item, rel, vals in
                let dstURL = canonicalDst.appendingPathComponent(rel, isDirectory: vals.isDirectory == true).standardizedFileURL
                guard let safeDst = PathSafety.containedURL(dstURL, in: canonicalDst) else {
                    return
                }

                if vals.isSymbolicLink == true {
                    if let linkTarget = try? fm.destinationOfSymbolicLink(atPath: item.path) {
                        try? fm.createDirectory(at: safeDst.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? fm.createSymbolicLink(atPath: safeDst.path, withDestinationPath: linkTarget)
                    }
                    return
                }

                if vals.isDirectory == true {
                    do {
                        try fm.createDirectory(at: safeDst, withIntermediateDirectories: true)
                    } catch {
                        throw CloneAbort.cloneFailed
                    }
                } else if vals.isRegularFile == true {
                    sawRegularFile = true
                    do {
                        try fm.createDirectory(at: safeDst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    } catch {
                        throw CloneAbort.cloneFailed
                    }
                    if clonefile(item.path, safeDst.path, 0) != 0 {
                        throw CloneAbort.cloneFailed
                    }
                }
            }
        } catch {
            return false
        }

        if !sawRegularFile {
            let probeSrc = canonicalSrc.appendingPathComponent(".chrysa_clone_probe_\(UUID().uuidString)")
            let probeDst = canonicalDst.appendingPathComponent(".chrysa_clone_probe_\(UUID().uuidString)")
            defer {
                try? fm.removeItem(at: probeSrc)
                try? fm.removeItem(at: probeDst)
            }
            if fm.createFile(atPath: probeSrc.path, contents: Data([0])) {
                let rc = clonefile(probeSrc.path, probeDst.path, 0)
                return rc == 0
            }
        }
        return true
    }

    private func writeManifest(_ manifest: BaselineSnapshotManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private nonisolated func pruneEmptyParentDirectories(startingAt dir: URL, stopAt root: URL) {
        let fm = FileManager.default
        var cursor = dir.standardizedFileURL
        let rootStd = root.standardizedFileURL
        while cursor.path != rootStd.path, cursor.path.hasPrefix(rootStd.path + "/") {
            let contents = (try? fm.contentsOfDirectory(atPath: cursor.path)) ?? []
            if contents.isEmpty {
                try? fm.removeItem(at: cursor)
                cursor = cursor.deletingLastPathComponent()
            } else {
                break
            }
        }
    }
}
