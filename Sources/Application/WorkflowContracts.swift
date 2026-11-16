import Foundation
import ChrysaCore

package struct ResolvedDownload: Sendable, Equatable {
    package let originalURL: String
    package let finalURL: String
    package let mirrorURLs: [String]
    package let headers: [String]
    package let suggestedFilename: String?
    package let useChunkedRange: Bool
    package let totalSize: Int64?
    package let subDirectory: String?
    package let mailRuWeblink: String?
    package let maxThreads: Int?
    package let needsProxy: Bool?
    package let resolverID: String?
    package let rateLimitNote: String?

    package init(
        originalURL: String = "",
        finalURL: String,
        mirrorURLs: [String] = [],
        headers: [String],
        suggestedFilename: String?,
        useChunkedRange: Bool = false,
        totalSize: Int64? = nil,
        subDirectory: String? = nil,
        mailRuWeblink: String? = nil,
        maxThreads: Int? = nil,
        needsProxy: Bool? = nil,
        resolverID: String? = nil,
        rateLimitNote: String? = nil
    ) {
        self.originalURL = originalURL.isEmpty ? finalURL : originalURL
        self.finalURL = finalURL
        self.mirrorURLs = mirrorURLs
        self.headers = headers
        self.suggestedFilename = suggestedFilename
        self.useChunkedRange = useChunkedRange
        self.totalSize = totalSize
        self.subDirectory = subDirectory
        self.mailRuWeblink = mailRuWeblink
        self.maxThreads = maxThreads
        self.needsProxy = needsProxy
        self.resolverID = resolverID
        self.rateLimitNote = rateLimitNote
    }

    package func appendingMirrors(_ extra: [String]) -> ResolvedDownload {
        guard !extra.isEmpty else { return self }
        var combined = mirrorURLs
        for candidate in extra where candidate != originalURL && !combined.contains(candidate) {
            combined.append(candidate)
        }
        return ResolvedDownload(
            originalURL: originalURL,
            finalURL: finalURL,
            mirrorURLs: combined,
            headers: headers,
            suggestedFilename: suggestedFilename,
            useChunkedRange: useChunkedRange,
            totalSize: totalSize,
            subDirectory: subDirectory,
            mailRuWeblink: mailRuWeblink,
            maxThreads: maxThreads,
            needsProxy: needsProxy,
            resolverID: resolverID,
            rateLimitNote: rateLimitNote
        )
    }
}

package struct HostResolutionResult: Sendable, Equatable {
    package let downloads: [ResolvedDownload]
    package let failureReason: String?
    package let diagnostic: String?

    package init(
        downloads: [ResolvedDownload],
        failureReason: String? = nil,
        diagnostic: String? = nil
    ) {
        self.downloads = downloads
        self.failureReason = failureReason
        self.diagnostic = diagnostic
    }
}

package struct GameLaunchRequest: Sendable {
    package let jobID: UUID
    package let title: String
    package let executablePath: String?
    package let gameDirectory: String?
    package let bottleName: String?
    package let launchArguments: String?
    package let bottlesDirectory: String

    package init(job: Job, bottlesDirectory: String) {
        self.jobID = job.id
        self.title = job.title
        self.executablePath = job.exePath
        self.gameDirectory = job.input?.kind == .directory ? job.input?.value : job.localPath
        self.bottleName = nil
        self.launchArguments = nil
        self.bottlesDirectory = bottlesDirectory
    }

    package init(game: LaunchGame, bottlesDirectory: String) {
        self.jobID = game.id
        self.title = game.title
        self.executablePath = game.exePath
        self.gameDirectory = game.gameDirectory
        self.bottleName = game.bottleName
        self.launchArguments = game.launchArguments
        self.bottlesDirectory = bottlesDirectory
    }
}

package enum LaunchGamePatchOutcome: Sendable {
    case applied(updatedGame: LaunchGame, summary: String)
    case cancelled
    case failed(String)
}

package enum LaunchGameRestoreOutcome: Sendable {
    case restored(restoredExePath: String?, restoredLaunchArguments: String?, summary: String)
    case failed(String)
}

package enum GameLaunchOutcome: Sendable {
    case launched
    case openedDirectory
    case cancelled
    case failed(String)
}

package enum JobStoreLoadResult: Sendable {
    case missing
    case loaded([Job])
    case recovered([Job])
    case migrated([Job])
    case migrationPending([Job])
    case corrupt
    case unsupported

    package var jobs: [Job] {
        switch self {
        case .loaded(let jobs), .recovered(let jobs), .migrated(let jobs), .migrationPending(let jobs): return jobs
        case .missing, .corrupt, .unsupported: return []
        }
    }
}

package enum TaskStoreLoadResult: Sendable {
    case missing
    case loaded(PersistedTaskSnapshot)
    case recovered(PersistedTaskSnapshot)
    case corrupt
    case unsupported

    package var snapshot: PersistedTaskSnapshot {
        switch self {
        case .loaded(let snapshot), .recovered(let snapshot): return snapshot
        case .missing, .corrupt, .unsupported:
            return PersistedTaskSnapshot(downloadTasks: [], unpackTasks: [], patchTasks: [])
        }
    }
}


package enum DiskSpacePreflight {
    /// Computes required free disk bytes before starting a download (accounting for download + unpack headroom when autoRelay is enabled).
    package static func requiredBytes(
        totalBytes: Int64,
        existingStagedBytes: Int64 = 0,
        includeUnpackReserve: Bool
    ) -> Int64 {
        let clampedTotal = max(0, totalBytes)
        let remainingDownload = max(0, clampedTotal - max(0, existingStagedBytes))
        let unpackReserve = includeUnpackReserve ? clampedTotal : 0
        return remainingDownload + unpackReserve
    }
}

package enum LaunchGameStoreLoadResult: Sendable {
    case missing
    case loaded([LaunchGame])
    case recovered([LaunchGame])
    case corrupt
    case unsupported

    package var games: [LaunchGame] {
        switch self {
        case .loaded(let games), .recovered(let games): return games
        case .missing, .corrupt, .unsupported: return []
        }
    }
}

package enum CrossOverGraphicsBackend: String, CaseIterable, Codable, Sendable, Identifiable {
    case automatic
    case d3dmetal
    case dxmt
    case dxvk
    case wined3d

    package var id: String { rawValue }

    package var displayName: String {
        switch self {
        case .automatic: return "自动"
        case .d3dmetal: return "D3DMetal"
        case .dxmt: return "DXMT"
        case .dxvk: return "DXVK"
        case .wined3d: return "WineD3D"
        }
    }

    package var envValue: String? {
        switch self {
        case .automatic: return nil
        case .d3dmetal: return "d3dmetal"
        case .dxmt: return "dxmt"
        case .dxvk: return "dxvk"
        case .wined3d: return "wined3d"
        }
    }

    package static func fromConfigValue(_ raw: String?) -> CrossOverGraphicsBackend {
        guard let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return .automatic
        }
        switch normalized {
        case "d3dmetal": return .d3dmetal
        case "dxmt": return .dxmt
        case "dxvk": return .dxvk
        case "wined3d", "wine": return .wined3d
        default: return .automatic
        }
    }
}

package struct CrossOverBottleRuntimeOptions: Equatable, Sendable {
    package var graphicsBackend: CrossOverGraphicsBackend
    package var retinaMode: Bool

    package init(
        graphicsBackend: CrossOverGraphicsBackend = .automatic,
        retinaMode: Bool = false
    ) {
        self.graphicsBackend = graphicsBackend
        self.retinaMode = retinaMode
    }
}

package enum LaunchGameRemovalMode: Sendable, Equatable {
    case recordOnly
    case moveToTrash
}

package struct LaunchGameUninstallOutcome: Sendable, Equatable {
    package let trashedPaths: [String]
    package let skippedProtectedPaths: [String]
    package let terminatedBottleName: String?
    package let warnings: [String]

    package init(
        trashedPaths: [String] = [],
        skippedProtectedPaths: [String] = [],
        terminatedBottleName: String? = nil,
        warnings: [String] = []
    ) {
        self.trashedPaths = trashedPaths
        self.skippedProtectedPaths = skippedProtectedPaths
        self.terminatedBottleName = terminatedBottleName
        self.warnings = warnings
    }
}
