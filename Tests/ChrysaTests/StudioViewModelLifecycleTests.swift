import Foundation
import Testing
import ChrysaCore
import ChrysaApplication
import ChrysaAdapters
import ChrysaPresentation

struct StudioViewModelLifecycleTests {
    @MainActor
    @Test
    func flushCompletesWhileStartupBottleScanIsSuspended() async {
        let scanGate = BottleScanGate()
        let services = GatedBottleScanServices(gate: scanGate)
        let coordinator = PipelineCoordinator(
            services: services,
            jobStore: JobStore(inMemoryOnly: true)
        )
        let viewModel = StudioViewModel(
            inMemoryOnly: false,
            settingsStore: AppSettingsStore(inMemoryOnly: true),
            taskStore: TaskStore(inMemoryOnly: true),
            coordinator: coordinator
        )

        let scanStarted = await waitUntil { await scanGate.started }
        #expect(scanStarted)

        let flushSignal = FlushSignal()
        let flushTask = Task {
            await viewModel.flushTasksImmediately()
            await flushSignal.complete()
        }
        let flushCompletedBeforeScan = await waitUntil { await flushSignal.completed }

        await scanGate.release()
        await flushTask.value
        #expect(flushCompletedBeforeScan)
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

private actor BottleScanGate {
    private(set) var started = false
    private var completion: CheckedContinuation<[LaunchGame], Never>?

    func scan() async -> [LaunchGame] {
        await withCheckedContinuation { continuation in
            completion = continuation
            started = true
        }
    }

    func release() {
        completion?.resume(returning: [])
        completion = nil
    }
}

private actor FlushSignal {
    private(set) var completed = false

    func complete() {
        completed = true
    }
}

private struct GatedBottleScanServices: WorkflowServices {
    let gate: BottleScanGate
    private let base = DefaultWorkflowServices()

    func downloadStage(title: String, resolved: ResolvedDownload, settings: AppSettings) -> any Stage {
        base.downloadStage(title: title, resolved: resolved, settings: settings)
    }

    func unpackStage(passwords: [String], deleteArchive: Bool) -> any Stage {
        base.unpackStage(passwords: passwords, deleteArchive: deleteArchive)
    }

    func patchStage(title: String, settings: AppSettings) -> any Stage {
        base.patchStage(title: title, settings: settings)
    }

    func launchStage(request: GameLaunchRequest) -> any Stage {
        base.launchStage(request: request)
    }

    func normalizeDownloadInput(_ input: String) -> String? { base.normalizeDownloadInput(input) }
    func initialDownloadMessage(for input: String) -> String? { base.initialDownloadMessage(for: input) }
    func suggestedDownloadName(_ input: String) -> String? { base.suggestedDownloadName(input) }
    func resolveDownloads(_ input: String, passwords: [String]) async -> [ResolvedDownload] {
        await base.resolveDownloads(input, passwords: passwords)
    }
    func refreshDownload(_ item: ResolvedDownload) async -> ResolvedDownload {
        await base.refreshDownload(item)
    }
    func isArchiveFile(_ path: String) -> Bool { base.isArchiveFile(path) }
    func normalizeArchivePath(_ path: String) -> String { base.normalizeArchivePath(path) }
    func fileSize(_ path: String) -> Int64? { base.fileSize(path) }
    func fileExists(_ path: String) -> Bool { base.fileExists(path) }
    func resolveDroppedFile(_ url: URL) async -> (kind: JobKind, path: String) {
        await base.resolveDroppedFile(url)
    }
    func scanBottles(directory: String) async -> [LaunchGame] { await gate.scan() }
    func inspectGameForImport(at url: URL, bottlesDirectory: String) async -> LaunchGame? {
        await base.inspectGameForImport(at: url, bottlesDirectory: bottlesDirectory)
    }
    func resolveLaunchGameIcon(_ game: LaunchGame) async -> Data? { nil }
    func mergeDLC(installer: String, directory: String, taskID: UUID) async -> Bool {
        await base.mergeDLC(installer: installer, directory: directory, taskID: taskID)
    }
    func cancel(taskID: UUID) async { await base.cancel(taskID: taskID) }
    func clearCancellation(taskID: UUID) async { await base.clearCancellation(taskID: taskID) }
    func deleteDownloadedFile(_ path: String, downloadDirectory: String) throws -> Bool {
        try base.deleteDownloadedFile(path, downloadDirectory: downloadDirectory)
    }

    func allStages(for kind: JobKind, job: Job, settings: AppSettings) -> [any Stage] {
        base.allStages(for: kind, job: job, settings: settings)
    }
}
