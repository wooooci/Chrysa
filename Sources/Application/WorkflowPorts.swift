import Foundation
import ChrysaCore

package protocol LegacyTaskLoading: Sendable {
    func load() async -> PersistedTaskSnapshot
    func loadResult() async -> TaskStoreLoadResult
}

package protocol JobRepository: Sendable {
    func load(migratingLegacyStore: any LegacyTaskLoading) async -> JobStoreLoadResult
    @discardableResult func upsert(_ job: Job) async -> Job
    func job(for id: UUID) async -> Job?
    func all() async -> [Job]
    @discardableResult func update(
        id: UUID,
        kind: JobKind?,
        status: JobStatus?,
        progress: Double?,
        title: String?,
        source: ArtifactRef?,
        input: ArtifactRef?,
        output: ArtifactRef?,
        message: String?,
        clearMessage: Bool,
        rightText: String?,
        appID: String?,
        checklist: [CheckItem]?,
        isArchived: Bool?,
        expanded: Bool?,
        listPosition: Int?
    ) async -> Job?
    @discardableResult func appendLog(_ entry: LogEntry, to id: UUID) async -> Job?
    func remove(id: UUID) async
}

package protocol LaunchGameRepository: Sendable {
    func load() async -> LaunchGameStoreLoadResult
    func all() async -> [LaunchGame]
    func game(for id: UUID) async -> LaunchGame?
    @discardableResult func upsert(_ game: LaunchGame, preferIncomingMetadata: Bool) async -> LaunchGame
    @discardableResult func markPlayed(id: UUID, at date: Date) async -> LaunchGame?
    func remove(id: UUID, suppressRescan: Bool) async
    func isSuppressed(_ game: LaunchGame) async -> Bool
    func clearSuppression(for game: LaunchGame) async
    func clearAllSuppressions() async
    func isLegacyJobMigrationCompleted() async -> Bool
    func markLegacyJobMigrationCompleted() async
}

package actor InMemoryLaunchGameRepository: LaunchGameRepository {
    private var games: [LaunchGame] = []
    private var suppressedKeys: Set<String> = []
    private var migratedLegacy = false

    package init(seed: [LaunchGame] = []) {
        self.games = LaunchGame.deduplicate(seed)
    }

    package func load() async -> LaunchGameStoreLoadResult { .loaded(games) }
    package func all() async -> [LaunchGame] { games }
    package func game(for id: UUID) async -> LaunchGame? { games.first(where: { $0.id == id }) }

    @discardableResult
    package func upsert(_ game: LaunchGame, preferIncomingMetadata: Bool) async -> LaunchGame {
        if game.source != .crossoverScan {
            for key in game.allSuppressionKeys {
                suppressedKeys.remove(key)
            }
        }
        if let idx = games.firstIndex(where: { $0.matches(game) }) {
            let merged = games[idx].merged(with: game, preferIncomingMetadata: preferIncomingMetadata)
            games[idx] = merged
            return merged
        }
        games.append(game)
        return game
    }

    @discardableResult
    package func markPlayed(id: UUID, at date: Date) async -> LaunchGame? {
        guard let idx = games.firstIndex(where: { $0.id == id }) else { return nil }
        games[idx].lastPlayedAt = date
        games[idx].updatedAt = date
        return games[idx]
    }

    package func remove(id: UUID, suppressRescan: Bool) async {
        guard let idx = games.firstIndex(where: { $0.id == id }) else { return }
        let removed = games.remove(at: idx)
        if suppressRescan {
            for key in removed.allSuppressionKeys {
                suppressedKeys.insert(key)
            }
        }
    }

    package func isSuppressed(_ game: LaunchGame) async -> Bool {
        game.allSuppressionKeys.contains(where: { suppressedKeys.contains($0) })
    }

    package func clearSuppression(for game: LaunchGame) async {
        for key in game.allSuppressionKeys {
            suppressedKeys.remove(key)
        }
    }

    package func clearAllSuppressions() async {
        suppressedKeys.removeAll()
    }

    package func isLegacyJobMigrationCompleted() async -> Bool { migratedLegacy }
    package func markLegacyJobMigrationCompleted() async { migratedLegacy = true }
}
/// Creates the registered operations and provides the platform queries used by the workflow.
package protocol WorkflowServices: Sendable {
    func downloadStage(title: String, resolved: ResolvedDownload, settings: AppSettings) -> any Stage
    func unpackStage(passwords: [String], deleteArchive: Bool) -> any Stage
    func patchStage(title: String, settings: AppSettings) -> any Stage
    func launchStage(request: GameLaunchRequest) -> any Stage

    // New registry method
    func allStages(for kind: JobKind, job: Job, settings: AppSettings) -> [any Stage]

    func normalizeDownloadInput(_ input: String) -> String?
    func initialDownloadMessage(for input: String) -> String?
    func suggestedDownloadName(_ input: String) -> String?
    func resolveDownloads(_ input: String, passwords: [String]) async -> [ResolvedDownload]
    func refreshDownload(_ item: ResolvedDownload) async -> ResolvedDownload
    func isArchiveFile(_ path: String) -> Bool
    func normalizeArchivePath(_ path: String) -> String
    func fileSize(_ path: String) -> Int64?
    func fileExists(_ path: String) -> Bool
    func resolveDroppedFile(_ url: URL) async -> (kind: JobKind, path: String)
    func scanBottles(directory: String) async -> [LaunchGame]
    func inspectGameForImport(at url: URL, bottlesDirectory: String) async -> LaunchGame?
    func mergeDLC(installer: String, directory: String, taskID: UUID) async -> Bool
    func cancel(taskID: UUID) async
    func clearCancellation(taskID: UUID) async
    func deleteDownloadedFile(_ path: String, downloadDirectory: String) throws -> Bool
}
