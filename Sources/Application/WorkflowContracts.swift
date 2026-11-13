import Foundation
import ChrysaCore

package struct ResolvedDownload: Sendable, Equatable {
    package let originalURL: String
    package let finalURL: String
    package let headers: [String]
    package let suggestedFilename: String?
    package let useChunkedRange: Bool
    package let totalSize: Int64?
    package let subDirectory: String?
    package let mailRuWeblink: String?
    package let maxThreads: Int?
    package let needsProxy: Bool?
    package let resolverID: String?

    package init(
        originalURL: String = "",
        finalURL: String,
        headers: [String],
        suggestedFilename: String?,
        useChunkedRange: Bool = false,
        totalSize: Int64? = nil,
        subDirectory: String? = nil,
        mailRuWeblink: String? = nil,
        maxThreads: Int? = nil,
        needsProxy: Bool? = nil,
        resolverID: String? = nil
    ) {
        self.originalURL = originalURL.isEmpty ? finalURL : originalURL
        self.finalURL = finalURL
        self.headers = headers
        self.suggestedFilename = suggestedFilename
        self.useChunkedRange = useChunkedRange
        self.totalSize = totalSize
        self.subDirectory = subDirectory
        self.mailRuWeblink = mailRuWeblink
        self.maxThreads = maxThreads
        self.needsProxy = needsProxy
        self.resolverID = resolverID
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
    package let bottlesDirectory: String

    package init(job: Job, bottlesDirectory: String) {
        self.jobID = job.id
        self.title = job.title
        self.executablePath = job.exePath
        self.gameDirectory = job.input?.kind == .directory ? job.input?.value : job.localPath
        self.bottlesDirectory = bottlesDirectory
    }

    package init(game: LaunchGame, bottlesDirectory: String) {
        self.jobID = game.id
        self.title = game.title
        self.executablePath = game.exePath
        self.gameDirectory = game.gameDirectory
        self.bottlesDirectory = bottlesDirectory
    }
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
