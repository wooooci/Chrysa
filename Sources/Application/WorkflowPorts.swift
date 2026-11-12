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
    func remove(id: UUID) async
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
    func scanBottles(directory: String) async -> [Job]
    func mergeDLC(installer: String, directory: String, taskID: UUID) async -> Bool
    func cancel(taskID: UUID) async
    func clearCancellation(taskID: UUID) async
    func deleteDownloadedFile(_ path: String, downloadDirectory: String) throws -> Bool
}
