import Foundation
import Testing
import ChrysaCore
import ChrysaApplication

struct PipelineCoordinatorTests {
    @MainActor
    @Test
    func testDownloadEntryRelaysActualPublishedArtifactsThroughRegisteredStages() async throws {
        let trace = WorkflowTrace()
        let services = StubWorkflowServices(trace: trace)
        let store = MemoryRepository()
        let coordinator = PipelineCoordinator(services: services, jobStore: store)
        coordinator.startDownload(urlString: "https://example.test/game.7z", settings: .default)
        try await waitUntil {
            await store.all().contains { $0.kind == .patch && $0.status == .succeeded }
        }

        let calls = await trace.calls
        #expect(calls.map(\.0) == ["download", "unpack", "patch"])
        try #require(calls.count == 3)
        #expect(calls[1].1 == ArtifactRef(kind: .file, value: "/published/game (2).7z"))
        #expect(calls[2].1 == ArtifactRef(kind: .directory, value: "/published/game"))
        #expect(calls.map(\.2) == [calls[0].2, calls[0].2, calls[0].2])
        let jobs = await store.all()
        #expect(jobs.count == 1)
        #expect(jobs[0].id == calls[0].2)
        #expect(jobs[0].kind == .patch && jobs[0].status == .succeeded && jobs[0].progress == 1)
        #expect(jobs[0].source == ArtifactRef(kind: .remoteURL, value: "https://example.test/game.7z"))
        #expect(jobs[0].input == ArtifactRef(kind: .directory, value: "/published/game"))
        #expect(jobs[0].sourceURL == "https://example.test/game.7z")
    }

    @MainActor
    @Test
    func testFolderDownloadRelaysPrimaryArchiveJobIntoUnpackAndPatch() async throws {
        let trace = WorkflowTrace()
        let services = StubWorkflowServices(trace: trace)
        let store = MemoryRepository()
        let coordinator = PipelineCoordinator(services: services, jobStore: store)
        let primaryJob = Job(kind: .download, title: "game.7z", status: .running)
        await coordinator.addJob(primaryJob)

        await coordinator.runFolderDownloadPipeline(
            firstTaskID: primaryJob.id,
            guessedName: "game.7z",
            items: [
                ResolvedDownload(finalURL: "https://example.test/game.7z", headers: [], suggestedFilename: "game.7z"),
                ResolvedDownload(finalURL: "https://example.test/readme.txt", headers: [], suggestedFilename: "readme.txt")
            ],
            settings: .default
        )

        let calls = await trace.calls
        let downstreamCalls = calls.filter { $0.0 == "unpack" || $0.0 == "patch" }
        #expect(downstreamCalls.map(\.0) == ["unpack", "patch"])
        #expect(downstreamCalls.allSatisfy { $0.2 == primaryJob.id })
        let jobs = await store.all()
        #expect(jobs.count == 2)
        #expect(jobs.contains { $0.id == primaryJob.id && $0.kind == .patch && $0.status == .succeeded })
        #expect(jobs.filter { $0.id != primaryJob.id }.allSatisfy { $0.kind == .download && $0.status == .succeeded })
    }

    @MainActor
    @Test
    func testFolderDownloadWaitsForAllMultipartVolumesBeforeUnpack() async throws {
        let trace = WorkflowTrace()
        let services = StubWorkflowServices(trace: trace)
        let store = MemoryRepository()
        let coordinator = PipelineCoordinator(services: services, jobStore: store)
        let primaryJob = Job(kind: .download, title: "game.part1.rar", status: .running)
        await coordinator.addJob(primaryJob)

        await coordinator.runFolderDownloadPipeline(
            firstTaskID: primaryJob.id,
            guessedName: "game.part1.rar",
            items: [
                ResolvedDownload(finalURL: "https://example.test/game.part1.rar", headers: [], suggestedFilename: "game.part1.rar"),
                ResolvedDownload(finalURL: "https://example.test/game.part2.rar", headers: [], suggestedFilename: "game.part2.rar")
            ],
            settings: .default
        )

        let calls = await trace.calls
        #expect(calls.map(\.0) == ["download", "download", "unpack", "patch"])
    }
    @MainActor
    @Test
    func testStoppingFolderPrimaryDoesNotStopRemainingFiles() async throws {
        let gate = StageGate()
        let trace = WorkflowTrace()
        let folderURL = "https://example.test/share"
        let services = StubWorkflowServices(
            trace: trace,
            gate: gate,
            resolvedDownloads: [
                ResolvedDownload(originalURL: folderURL, finalURL: "https://cdn.example.test/game.7z", headers: [], suggestedFilename: "game.7z"),
                ResolvedDownload(originalURL: "https://cdn.example.test/readme.txt", finalURL: "https://cdn.example.test/readme.txt", headers: [], suggestedFilename: "readme.txt")
            ]
        )
        let store = MemoryRepository()
        let coordinator = PipelineCoordinator(services: services, jobStore: store)
        coordinator.startDownload(urlString: folderURL, settings: .default)
        try await waitUntil { await gate.started }

        let jobs = await store.all()
        try #require(jobs.count == 2)
        let primary = try #require(jobs.first(where: { $0.sourceURL == folderURL }))
        let remaining = try #require(jobs.first(where: { $0.title == "readme.txt" }))
        await coordinator.cancelTask(primary.id)
        await gate.release()
        try await waitUntil { await store.job(for: remaining.id)?.status == .succeeded }

        #expect(await store.job(for: primary.id)?.status == .cancelled)
        #expect(await store.job(for: remaining.id)?.status == .succeeded)
        let calls = await trace.calls
        #expect(calls.map(\.0) == ["download", "download"])
        #expect(calls.last?.2 == remaining.id)
    }

    @MainActor
    @Test
    func testFailedAndCancelledDownloadBlockDownstreamStages() async {
        for result in [StageResult.failure(StageFailure(stage: StageID("download"), message: "network failed")), .cancelled] {
            let trace = WorkflowTrace()
            let services = StubWorkflowServices(trace: trace, downloadResult: result)
            let store = MemoryRepository()
            let coordinator = PipelineCoordinator(services: services, jobStore: store)
            let job = Job(kind: .download, title: "game.7z", status: .running)
            await coordinator.addJob(job)
            await coordinator.runDownloadTask(taskID: job.id, resolved: services.resolved, settings: .default)

            let saved = await store.job(for: job.id)
            let expectedStatus: JobStatus = result == .cancelled ? .cancelled : .failed
            #expect(saved?.status == expectedStatus)
            let calls = await trace.calls
            #expect(calls.map(\.0) == ["download"])
            let jobs = await store.all()
            #expect(jobs.count == 1)
        }
    }

    @MainActor
    @Test
    func testCancellationRejectsLateProgressAndSuccess() async throws {
        let gate = StageGate()
        let services = StubWorkflowServices(trace: WorkflowTrace(), gate: gate)
        let store = MemoryRepository()
        let coordinator = PipelineCoordinator(services: services, jobStore: store)
        let job = Job(kind: .download, title: "original", status: .running)
        await coordinator.addJob(job)
        let execution = Task {
            await coordinator.runDownloadTask(taskID: job.id, resolved: services.resolved, settings: .default)
        }
        defer {
            execution.cancel()
            Task { await gate.release() }
        }
        try await waitUntil { await gate.started }
        await coordinator.cancelTask(job.id)
        await gate.release()
        await execution.value

        let saved = await store.job(for: job.id)
        #expect(saved?.status == .cancelled)
        #expect(saved?.title == "original")
        #expect(saved?.output == nil)
        #expect(saved?.message == "已停止")
        let jobs = await store.all()
        #expect(jobs.count == 1)
    }

    @MainActor
    @Test
    func testRemovingRunningJobPreventsLateRecreation() async throws {
        let gate = StageGate()
        let services = StubWorkflowServices(trace: WorkflowTrace(), gate: gate)
        let store = MemoryRepository()
        let coordinator = PipelineCoordinator(services: services, jobStore: store)
        let job = Job(kind: .download, title: "removed", status: .running)
        await coordinator.addJob(job)
        let execution = Task {
            await coordinator.runDownloadTask(taskID: job.id, resolved: services.resolved, settings: .default)
        }
        defer {
            execution.cancel()
            Task { await gate.release() }
        }
        try await waitUntil { await gate.started }
        await coordinator.removeJob(job.id)
        await gate.release()
        await execution.value
        let jobs = await store.all()
        #expect(jobs.isEmpty)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await condition(), "Timed out waiting for workflow")
    }
}

private actor WorkflowTrace {
    var calls: [(String, ArtifactRef?, UUID)] = []
    func record(_ id: String, input: ArtifactRef?, jobID: UUID) { calls.append((id, input, jobID)) }
}

private actor StageGate {
    private(set) var started = false
    private var released = false
    private var completion: CheckedContinuation<Void, Never>?

    func pause() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            completion = continuation
            started = true
        }
    }

    func release() {
        released = true
        completion?.resume()
        completion = nil
    }
}

private struct StubStage: Stage {
    let id: StageID
    let trace: WorkflowTrace
    let result: StageResult
    var gate: StageGate?

    func execute(context: StageContext) async -> StageResult {
        await trace.record(id.rawValue, input: context.input, jobID: context.jobID)
        await gate?.pause()
        await context.reportProgress(StageProgress(fraction: 0.8, message: "progress"))
        await context.log(StageLog("stage completed"))
        return result
    }
}

private struct StubWorkflowServices: WorkflowServices {
    let trace: WorkflowTrace
    var downloadResult: StageResult = .success(StageOutput(artifact: ArtifactRef(kind: .file, value: "/published/game (2).7z")))
    var gate: StageGate?
    var resolvedDownloads: [ResolvedDownload]? = nil
    let resolved = ResolvedDownload(finalURL: "https://example.test/game.7z", headers: [], suggestedFilename: "game.7z")

    func downloadStage(title: String, resolved: ResolvedDownload, settings: AppSettings) -> any Stage {
        StubStage(id: StageID("download"), trace: trace, result: downloadResult, gate: gate)
    }
    func unpackStage(passwords: [String], deleteArchive: Bool) -> any Stage {
        StubStage(id: StageID("unpack"), trace: trace, result: .success(StageOutput(artifact: ArtifactRef(kind: .directory, value: "/published/game"))))
    }
    func patchStage(title: String, settings: AppSettings) -> any Stage {
        StubStage(id: StageID("patch"), trace: trace, result: .success(StageOutput(artifact: ArtifactRef(kind: .file, value: "/published/game/game.exe"))))
    }
    func launchStage(request: GameLaunchRequest) -> any Stage {
        StubStage(id: StageID("launch"), trace: trace, result: .success(StageOutput()))
    }

    func allStages(for kind: JobKind, job: Job, settings: AppSettings) -> [any Stage] {
        switch kind {
        case .download: return [downloadStage(title: job.title, resolved: resolved, settings: settings)]
        case .unpack: return [unpackStage(passwords: [], deleteArchive: false)]
        case .patch: return [patchStage(title: job.title, settings: settings)]
        }
    }
    func normalizeDownloadInput(_ input: String) -> String? { input }
    func initialDownloadMessage(for input: String) -> String? { nil }
    func suggestedDownloadName(_ input: String) -> String? { "game.7z" }
    func resolveDownloads(_ input: String, passwords: [String]) async -> [ResolvedDownload] { resolvedDownloads ?? [resolved] }
    func refreshDownload(_ item: ResolvedDownload) async -> ResolvedDownload { item }
    func isArchiveFile(_ path: String) -> Bool { path.hasSuffix(".7z") || path.hasSuffix(".rar") }
    func normalizeArchivePath(_ path: String) -> String { path }
    func fileSize(_ path: String) -> Int64? { nil }
    func fileExists(_ path: String) -> Bool { true }
    func resolveDroppedFile(_ url: URL) async -> (kind: JobKind, path: String) { (.unpack, url.path) }
    func scanBottles(directory: String) async -> [LaunchGame] { [] }
    func inspectGameForImport(at url: URL, bottlesDirectory: String) async -> LaunchGame? { nil }
    func resolveLaunchGameIcon(_ game: LaunchGame) async -> Data? { nil }
    func mergeDLC(installer: String, directory: String, taskID: UUID) async -> Bool { true }
    func cancel(taskID: UUID) async {}
    func clearCancellation(taskID: UUID) async {}
    func deleteDownloadedFile(_ path: String, downloadDirectory: String) throws -> Bool { false }
}

/// Deliberately accepts all updates so coordinator cancellation is tested independently of store guards.
private actor MemoryRepository: JobRepository {
    private var jobs: [UUID: Job] = [:]
    func load(migratingLegacyStore: any LegacyTaskLoading) async -> JobStoreLoadResult { .loaded(all()) }
    func upsert(_ job: Job) -> Job {
        jobs[job.id] = job
        return job
    }
    func job(for id: UUID) -> Job? { jobs[id] }
    func all() -> [Job] { Array(jobs.values) }
    func appendLog(_ entry: LogEntry, to id: UUID) -> Job? {
        guard var job = jobs[id] else { return nil }
        job.appendBoundedLog(entry)
        jobs[id] = job
        return job
    }
    func remove(id: UUID) { jobs[id] = nil }
    func update(
        id: UUID, kind: JobKind?, status: JobStatus?, progress: Double?, title: String?, source: ArtifactRef?, input: ArtifactRef?, output: ArtifactRef?,
        message: String?, clearMessage: Bool, rightText: String?, appID: String?, checklist: [CheckItem]?,
        isArchived: Bool?, expanded: Bool?, listPosition: Int?
    ) -> Job? {
        guard var job = jobs[id] else { return nil }
        if let kind { job.kind = kind }
        if let status { job.status = status }
        if let progress { job.progress = progress }
        if let title { job.title = title }
        if let source { job.source = source }
        if let input { job.input = input }
        if let output { job.output = output }
        if clearMessage { job.message = nil } else if let message { job.message = message }
        if let rightText { job.rightText = rightText }
        if let appID { job.appID = appID }
        if let checklist { job.checklist = checklist }
        if let isArchived { job.isArchived = isArchived }
        if let expanded { job.expanded = expanded }
        if let listPosition { job.listPosition = listPosition }
        jobs[id] = job
        return job
    }
}
