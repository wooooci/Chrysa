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
    func testFolderDownloadAggregatesIntoSingleJobWithoutZombieRows() async throws {
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
        #expect(jobs.count == 1)
        #expect(jobs[0].id == primaryJob.id)
        #expect(jobs[0].kind == .patch && jobs[0].status == .succeeded)
        #expect(jobs[0].downloadParts?.count == 2)
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
        let jobs = await store.all()
        #expect(jobs.count == 1)
        #expect(jobs[0].kind == .patch && jobs[0].status == .succeeded)
    }

    @MainActor
    @Test
    func testPauseAndResumePreservesJobIdentityAndCompletes() async throws {
        let gate = StageGate()
        let trace = WorkflowTrace()
        let services = StubWorkflowServices(trace: trace, gate: gate)
        let store = MemoryRepository()
        let coordinator = PipelineCoordinator(services: services, jobStore: store)
        let job = Job(
            kind: .download,
            title: "game.7z",
            status: .running,
            source: ArtifactRef(kind: .remoteURL, value: "https://example.test/game.7z")
        )
        await coordinator.addJob(job)

        let runTask = Task {
            await coordinator.runDownloadTask(taskID: job.id, resolved: services.resolved, settings: .default)
        }
        try await waitUntil { await gate.started }
        await coordinator.pauseTask(job.id)
        await gate.release()
        await runTask.value

        let paused = await store.job(for: job.id)
        #expect(paused?.status == .paused)
        #expect(paused?.message == "已暂停")

        // Resume on the same job ID
        let unGatedServices = StubWorkflowServices(trace: trace)
        let resumedCoordinator = PipelineCoordinator(services: unGatedServices, jobStore: store)
        resumedCoordinator.resumeDownloadJob(job.id, settings: .default)
        try await waitUntil {
            let current = await store.job(for: job.id)
            return current?.kind == .patch && current?.status == .succeeded
        }
        let finalJobs = await store.all()
        #expect(finalJobs[0].id == job.id)
    }

    @MainActor
    @Test
    func testMultilineInputBindsExtractedPasswordFirst() async throws {
        let trace = WorkflowTrace()
        let services = StubWorkflowServices(trace: trace)
        let store = MemoryRepository()
        let coordinator = PipelineCoordinator(services: services, jobStore: store)
        coordinator.startDownloads(
            rawInput: """
            解压密码：top_secret_pw
            https://example.test/game.7z
            """,
            settings: .default
        )
        try await waitUntil {
            await store.all().contains { $0.kind == .patch && $0.status == .succeeded }
        }
        let capturedPasswords = await trace.unpackPasswords
        #expect(capturedPasswords.first == "top_secret_pw")
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

    @MainActor
    @Test
    func testDiskSpacePreflightBlocksLowSpaceWithAndWithoutAutoRelay() async throws {
        let trace = WorkflowTrace()
        var settings = AppSettings.default
        settings.downloadDirectory = "/tmp/chrysa-disk-test"
        settings.autoRelay = true

        // 1. Single download: 8 KB file fits on 10 KB disk alone, but needs ~16 KB + margin with autoRelay
        let singleResolved = ResolvedDownload(
            originalURL: "https://example.test/game.7z",
            finalURL: "https://example.test/game.7z",
            headers: [],
            suggestedFilename: "game.7z",
            totalSize: 8_000
        )
        let services = StubWorkflowServices(trace: trace, availableDiskBytes: 10_000)
        let store = MemoryRepository()
        let coordinator = PipelineCoordinator(services: services, jobStore: store)

        let blockedJob = Job(kind: .download, title: "game.7z", status: .running, progress: 0.0)
        await coordinator.addJob(blockedJob)
        await coordinator.runDownloadTask(taskID: blockedJob.id, resolved: singleResolved, settings: settings)

        let savedBlocked = await store.job(for: blockedJob.id)
        #expect(savedBlocked?.status == .failed)
        #expect(savedBlocked?.message == "空间不足")
        #expect(savedBlocked?.logs.contains(where: { $0.level == .error && $0.message.contains("磁盘空间不足") && !$0.message.contains("▸") }) == true)
        #expect(await trace.calls.isEmpty)

        // 2. Disabling autoRelay lets the 8 KB download proceed on 10 KB disk
        settings.autoRelay = false
        let allowedJob = Job(kind: .download, title: "game.7z", status: .running, progress: 0.0)
        await coordinator.addJob(allowedJob)
        await coordinator.runDownloadTask(taskID: allowedJob.id, resolved: singleResolved, settings: settings)
        let savedAllowed = await store.job(for: allowedJob.id)
        #expect(savedAllowed?.status == .succeeded)
        #expect(await trace.calls.count == 1)

        // 3. Aggregated multipart download checks combined total before downloading any part
        let multipartJob = Job(
            kind: .download,
            title: "Multipart Game",
            status: .running,
            downloadParts: [
                DownloadPart(filename: "part1.rar", originalURL: "https://a/1", resolvedURL: "https://a/1", totalBytes: 4_000),
                DownloadPart(filename: "part2.rar", originalURL: "https://a/2", resolvedURL: "https://a/2", totalBytes: 4_000),
                DownloadPart(filename: "part3.rar", originalURL: "https://a/3", resolvedURL: "https://a/3", totalBytes: 4_000)
            ]
        )
        let partCoordinator = PipelineCoordinator(
            services: StubWorkflowServices(trace: WorkflowTrace(), availableDiskBytes: 10_000),
            jobStore: store
        )
        await partCoordinator.addJob(multipartJob)
        await partCoordinator.runFolderDownloadPipeline(
            firstTaskID: multipartJob.id,
            guessedName: "Multipart Game",
            items: [
                ResolvedDownload(finalURL: "https://a/1", headers: [], suggestedFilename: "part1.rar", totalSize: 4_000),
                ResolvedDownload(finalURL: "https://a/2", headers: [], suggestedFilename: "part2.rar", totalSize: 4_000),
                ResolvedDownload(finalURL: "https://a/3", headers: [], suggestedFilename: "part3.rar", totalSize: 4_000)
            ],
            settings: settings
        )
        let savedMultipart = await store.job(for: multipartJob.id)
        #expect(savedMultipart?.status == .failed)
        #expect(savedMultipart?.message == "空间不足")
        #expect(savedMultipart?.downloadParts?.allSatisfy { $0.status == .failed && $0.message == "空间不足" } == true)
    }

    @MainActor
    @Test
    func testIdleSleepAssertionAcquiresAndReleasesOnPauseAndRelayToPatch() async throws {
        let sleepRecorder = SleepStateRecorder()
        let gate = StageGate()
        let trace = WorkflowTrace()
        let services = StubWorkflowServices(
            trace: trace,
            gate: gate,
            sleepRecorder: sleepRecorder
        )
        let store = MemoryRepository()
        let coordinator = PipelineCoordinator(services: services, jobStore: store)

        // 1. Download acquires sleep lock and pauseTask releases immediately
        let job = Job(kind: .download, title: "sleep-dl.7z", status: .running)
        await coordinator.addJob(job)
        let task = Task {
            await coordinator.runDownloadTask(taskID: job.id, resolved: services.resolved, settings: .default)
        }
        try await waitUntil { await gate.started }
        #expect(sleepRecorder.snapshot() == [true])

        await coordinator.pauseTask(job.id)
        await gate.release()
        await task.value
        #expect(sleepRecorder.snapshot() == [true, false])
        #expect(sleepRecorder.current == false)

        // 2. Unpack task relays into patch -> sleep lock releases when entering patch stage
        var relaySettings = AppSettings.default
        relaySettings.autoRelay = true
        let unpackJob = Job(
            kind: .unpack,
            title: "sleep-unpack.7z",
            status: .running,
            source: ArtifactRef(kind: .file, value: "/tmp/sleep-unpack.7z"),
            input: ArtifactRef(kind: .file, value: "/tmp/sleep-unpack.7z")
        )
        await coordinator.addJob(unpackJob)
        await coordinator.runUnpackTask(
            taskID: unpackJob.id,
            archivePath: "/tmp/sleep-unpack.7z",
            candidatePasswords: [""],
            settings: relaySettings
        )
        #expect(sleepRecorder.snapshot() == [true, false, true, false])
        #expect(sleepRecorder.current == false)
    }

    @MainActor
    @Test
    func testSameFilenameMultiHostCoalescesMirrorsPreferringUnthrottledPrimary() async throws {
        let trace = WorkflowTrace()
        let services = StubWorkflowServices(
            trace: trace,
            detailResolver: { input in
                if input.contains("pixeldrain.com") {
                    return HostResolutionResult(downloads: [
                        ResolvedDownload(
                            originalURL: input,
                            finalURL: "https://pixeldrain.com/api/file/slow1?download",
                            headers: [],
                            suggestedFilename: "CoolGame_v1.0.7z",
                            totalSize: 500_000,
                            resolverID: "pixeldrain",
                            rateLimitNote: "限速 1MB/s"
                        )
                    ])
                }
                return HostResolutionResult(downloads: [
                    ResolvedDownload(
                        originalURL: input,
                        finalURL: "https://spyderrock.com/fast2.7z",
                        headers: [],
                        suggestedFilename: "CoolGame_v1.0.7z",
                        totalSize: 500_000,
                        resolverID: "qiwi"
                    )
                ])
            }
        )
        let store = MemoryRepository()
        let coordinator = PipelineCoordinator(services: services, jobStore: store)
        var settings = AppSettings.default
        settings.autoRelay = false

        coordinator.startDownloads(
            rawInput: "https://pixeldrain.com/u/slow1\nhttps://qiwi.gg/file/fast2",
            settings: settings
        )

        try await waitUntil {
            let jobs = await store.all()
            return jobs.count == 1 && jobs.first?.status == .succeeded
        }

        let jobs = await store.all()
        let finalJob = try #require(jobs.first)
        #expect(finalJob.sourceURL == "https://qiwi.gg/file/fast2")
        #expect(finalJob.mirrorURLs == ["https://pixeldrain.com/u/slow1"])
        #expect(finalJob.title == "CoolGame_v1.0.7z")
        #expect(finalJob.logs.contains(where: { $0.message.contains("备选镜像") && !$0.message.contains("▸") }))
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await condition(), "Timed out waiting for workflow")
    }
}

private final class SleepStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var transitions: [Bool] = []
    private var _current: Bool = false

    var current: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _current
    }

    func snapshot() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return transitions
    }

    func record(_ active: Bool) {
        lock.lock()
        _current = active
        transitions.append(active)
        lock.unlock()
    }
}

private actor WorkflowTrace {
    var calls: [(String, ArtifactRef?, UUID)] = []
    var unpackPasswords: [String] = []
    func record(_ id: String, input: ArtifactRef?, jobID: UUID, passwords: [String]? = nil) {
        calls.append((id, input, jobID))
        if let passwords {
            unpackPasswords = passwords
        }
    }
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
    var passwords: [String]? = nil

    func execute(context: StageContext) async -> StageResult {
        await trace.record(id.rawValue, input: context.input, jobID: context.jobID, passwords: passwords)
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
    var availableDiskBytes: Int64? = nil
    var sleepRecorder: SleepStateRecorder? = nil
    var detailResolver: (@Sendable (String) -> HostResolutionResult)? = nil
    let resolved = ResolvedDownload(finalURL: "https://example.test/game.7z", headers: [], suggestedFilename: "game.7z")

    func downloadStage(title: String, resolved: ResolvedDownload, settings: AppSettings) -> any Stage {
        StubStage(id: StageID("download"), trace: trace, result: downloadResult, gate: gate)
    }
    func unpackStage(passwords: [String], deleteArchive: Bool) -> any Stage {
        StubStage(
            id: StageID("unpack"),
            trace: trace,
            result: .success(StageOutput(artifact: ArtifactRef(kind: .directory, value: "/published/game"))),
            passwords: passwords
        )
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
    func resolveDownloadsDetailed(_ input: String, passwords: [String], settings: AppSettings) async -> HostResolutionResult {
        if let detailResolver {
            return detailResolver(input)
        }
        return HostResolutionResult(downloads: resolvedDownloads ?? [resolved])
    }
    func refreshDownload(_ item: ResolvedDownload) async -> ResolvedDownload { item }
    func availableDiskSpace(atDirectory path: String) -> Int64? { availableDiskBytes }
    func setPreventIdleSleep(_ active: Bool) {
        sleepRecorder?.record(active)
    }
    func isArchiveFile(_ path: String) -> Bool { path.hasSuffix(".7z") || path.hasSuffix(".rar") }
    func normalizeArchivePath(_ path: String) -> String { path }
    func fileSize(_ path: String) -> Int64? { nil }
    func fileExists(_ path: String) -> Bool { true }
    func resolveDroppedFile(_ url: URL) async -> (kind: JobKind, path: String) { (.unpack, url.path) }
    func scanBottles(directory: String) async -> [LaunchGame] { [] }
    func inspectGameForImport(at url: URL, bottlesDirectory: String) async -> LaunchGame? { nil }
    func resolveLaunchGameIcon(_ game: LaunchGame) async -> Data? { nil }
    func saveCustomLaunchGameIcon(from sourceURL: URL, for gameID: UUID) async -> String? { nil }
    func removeCustomLaunchGameIcon(at path: String?) async {}
    func invalidateLaunchGameIconCache(for game: LaunchGame) async {}
    func lookupSteamAppID(for title: String) async -> String? { nil }
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
    func updateDownloadMetadata(id: UUID, passwordHint: String?, downloadParts: [DownloadPart]?) -> Job? {
        updateDownloadMetadata(id: id, passwordHint: passwordHint, downloadParts: downloadParts, mirrorURLs: nil)
    }
    func updateDownloadMetadata(
        id: UUID,
        passwordHint: String?,
        downloadParts: [DownloadPart]?,
        mirrorURLs: [String]?
    ) -> Job? {
        guard var job = jobs[id] else { return nil }
        if let passwordHint { job.passwordHint = passwordHint }
        if let downloadParts { job.downloadParts = downloadParts }
        if let mirrorURLs { job.mirrorURLs = mirrorURLs }
        jobs[id] = job
        return job
    }
    func reopenForResume(id: UUID, status: JobStatus, message: String?, rightText: String?) -> Job? {
        guard var job = jobs[id] else { return nil }
        job.status = status
        job.message = message
        if let rightText { job.rightText = rightText }
        jobs[id] = job
        return job
    }
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
