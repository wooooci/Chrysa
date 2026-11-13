import ChrysaCore
import ChrysaApplication
import Foundation

package struct DownloadStage: Stage {
    package static let stageID = StageID("download")

    package let id = stageID
    private let service: DownloadService
    private let currentTitle: String
    private let resolved: ResolvedDownload
    private let stagingJobID: UUID?
    private let stagingSubkey: String?
    private let settings: AppSettings

    package init(
        service: DownloadService,
        currentTitle: String,
        resolved: ResolvedDownload,
        stagingJobID: UUID? = nil,
        stagingSubkey: String? = nil,
        settings: AppSettings
    ) {
        self.service = service
        self.currentTitle = currentTitle
        self.resolved = resolved
        self.stagingJobID = stagingJobID
        self.stagingSubkey = stagingSubkey
        self.settings = settings
    }

    package func execute(context: StageContext) async -> StageResult {
        guard context.input?.kind == .remoteURL else {
            return .failure(StageFailure(stage: id, message: StageError.missingInput(stage: id).localizedDescription))
        }
        guard !(await context.cancellationRequested()) else { return .cancelled }

        let outcome = await service.executeDownload(
            taskID: context.jobID,
            currentTitle: currentTitle,
            resolved: resolved,
            settings: settings,
            stagingJobID: stagingJobID ?? context.jobID,
            stagingSubkey: stagingSubkey,
            isCancelled: context.isCancelled,
            onProgress: { update in
                await context.reportProgress(StageProgress(
                    fraction: update.progress,
                    message: update.pill,
                    detail: update.rightText,
                    downloadedBytes: update.downloadedBytes,
                    totalBytes: update.totalBytes,
                    speedBytesPerSec: update.speedBytesPerSec,
                    resolvedTitle: update.resolvedTitle
                ))
            },
            onLog: { message, highlight in
                await context.log(StageLog(message, highlight: highlight))
            },
            onDiagnostic: { stageLog in
                await context.log(stageLog)
            }
        )
        guard !(await context.cancellationRequested()) else { return .cancelled }
        switch outcome {
        case .completed(let localPath, let finalTitle, let rightText):
            return .success(StageOutput(
                artifact: ArtifactRef(kind: .file, value: localPath),
                metadata: ["title": finalTitle, "rightText": rightText ?? ""]
            ))
        case .cancelled:
            return .cancelled
        case .failed(let pill):
            return .failure(StageFailure(stage: id, message: pill))
        }
    }
}

package struct UnpackStage: Stage {
    package static let stageID = StageID("unpack")

    package let id = stageID
    private let service: UnpackService
    private let candidatePasswords: [String]
    private let deleteArchiveAfterUnpack: Bool

    package init(
        service: UnpackService,
        candidatePasswords: [String],
        deleteArchiveAfterUnpack: Bool
    ) {
        self.service = service
        self.candidatePasswords = candidatePasswords
        self.deleteArchiveAfterUnpack = deleteArchiveAfterUnpack
    }

    package func execute(context: StageContext) async -> StageResult {
        guard let input = context.input, input.kind == .file else {
            return .failure(StageFailure(stage: id, message: StageError.missingInput(stage: id).localizedDescription))
        }
        guard !(await context.cancellationRequested()) else { return .cancelled }

        let outcome = await service.executeUnpack(
            taskID: context.jobID,
            archivePath: input.value,
            candidatePasswords: candidatePasswords,
            deleteArchiveAfterUnpack: deleteArchiveAfterUnpack,
            isCancelled: context.isCancelled,
            onProgress: { fraction, message in
                await context.reportProgress(StageProgress(fraction: fraction, message: message))
            },
            onLog: { message, highlight in
                await context.log(StageLog(message, highlight: highlight))
            },
            onDiagnostic: { stageLog in
                await context.log(stageLog)
            }
        )
        guard !(await context.cancellationRequested()) else { return .cancelled }
        switch outcome {
        case .completed(let outputPath, let baseName, let pill):
            return .success(StageOutput(
                artifact: ArtifactRef(kind: .directory, value: outputPath),
                metadata: ["title": baseName, "message": pill]
            ))
        case .cancelled:
            return .cancelled
        case .failed(let pill):
            return .failure(StageFailure(stage: id, message: pill))
        }
    }
}

package struct PatchStage: Stage {
    package static let stageID = StageID("patch")

    package let id = stageID
    private let service: PatchService
    private let settings: AppSettings
    private let cleanTitle: String

    package init(service: PatchService, settings: AppSettings, cleanTitle: String) {
        self.service = service
        self.settings = settings
        self.cleanTitle = cleanTitle
    }

    package func execute(context: StageContext) async -> StageResult {
        guard let input = context.input, input.kind == .directory else {
            return .failure(StageFailure(stage: id, message: StageError.missingInput(stage: id).localizedDescription))
        }
        guard !(await context.cancellationRequested()) else { return .cancelled }

        let logQueue = StageEventQueue<StageLog> { entry in
            await context.log(entry)
        }
        do {
            let payload = try await service.executePatch(
                taskID: context.jobID,
                folderPath: input.value,
                cleanTitle: cleanTitle,
                settings: settings,
                isCancelled: context.isCancelled,
                onLog: { message, highlight in
                    logQueue.submit(StageLog(message, highlight: highlight))
                }
            )
            await logQueue.drain()
            guard !(await context.cancellationRequested()) else { return .cancelled }

            return .success(StageOutput(
                artifact: payload.exePath.map { ArtifactRef(kind: .file, value: $0) } ?? input,
                metadata: [
                    "title": payload.displayTitle,
                    "message": payload.pill,
                    "rightText": payload.rightText,
                    "appID": payload.appID,
                    "bottleName": payload.bottleName ?? ""
                ],
                checklist: payload.checklist
            ))
        } catch is CancellationError {
            await logQueue.drain()
            return .cancelled
        } catch {
            await logQueue.drain()
            if await context.cancellationRequested() { return .cancelled }
            let message = "补丁处理失败，\(error.localizedDescription)"
            let rawDiag = (error as? PatchError)?.rawDiagnostic
            await context.log(StageLog("error ▸ \(message)", level: .error, rawOutput: rawDiag))
            return .failure(StageFailure(stage: id, message: message))
        }
    }
}

package struct LaunchGameStage: Stage {
    package static let stageID = StageID("launch-game")

    package let id = stageID
    private let service: GameLauncher
    private let request: GameLaunchRequest

    package init(service: GameLauncher, request: GameLaunchRequest) {
        self.service = service
        self.request = request
    }

    package func execute(context: StageContext) async -> StageResult {
        guard !(await context.cancellationRequested()) else { return .cancelled }
        let logQueue = StageEventQueue<StageLog> { entry in
            await context.log(entry)
        }
        let outcome = await service.launchGame(
            request,
            isCancelled: context.isCancelled,
            onLog: { message, highlight in
                logQueue.submit(StageLog(message, highlight: highlight))
            },
            onDiagnostic: { stageLog in
                logQueue.submit(stageLog)
            }
        )
        await logQueue.drain()
        guard !(await context.cancellationRequested()) else { return .cancelled }
        switch outcome {
        case .launched, .openedDirectory:
            return .success(StageOutput(artifact: context.input))
        case .cancelled:
            return .cancelled
        case .failed(let message):
            return .failure(StageFailure(stage: id, message: message))
        }
    }
}
