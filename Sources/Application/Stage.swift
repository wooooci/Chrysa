import ChrysaCore
import Foundation

package struct StageID: Hashable, Codable, Sendable, CustomStringConvertible {
    package let rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    package var description: String { rawValue }
}

package struct StageContext: Sendable {
    package let jobID: UUID
    package let input: ArtifactRef?
    package let metadata: [String: String]
    package let reportProgress: @Sendable (StageProgress) async -> Void
    package let log: @Sendable (StageLog) async -> Void
    /// Checked at service boundaries. Cancelling the executing Task also terminates its active process.
    package let isCancelled: @Sendable () async -> Bool

    package init(
        jobID: UUID,
        input: ArtifactRef? = nil,
        metadata: [String: String] = [:],
        reportProgress: @escaping @Sendable (StageProgress) async -> Void = { _ in },
        log: @escaping @Sendable (StageLog) async -> Void = { _ in },
        isCancelled: @escaping @Sendable () async -> Bool = { Task.isCancelled }
    ) {
        self.jobID = jobID
        self.input = input
        self.metadata = metadata
        self.reportProgress = reportProgress
        self.log = log
        self.isCancelled = isCancelled
    }

    package func cancellationRequested() async -> Bool {
        if Task.isCancelled { return true }
        return await isCancelled()
    }
}

package struct StageProgress: Sendable, Equatable {
    package let fraction: Double?
    package let message: String?
    package let detail: String?
    package let downloadedBytes: Int64?
    package let totalBytes: Int64?
    package let speedBytesPerSec: Double?
    package let resolvedTitle: String?

    package init(
        fraction: Double?,
        message: String? = nil,
        detail: String? = nil,
        downloadedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        speedBytesPerSec: Double? = nil,
        resolvedTitle: String? = nil
    ) {
        self.fraction = fraction.map(Job.clampedProgress)
        self.message = message
        self.detail = detail
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.speedBytesPerSec = speedBytesPerSec
        self.resolvedTitle = resolvedTitle
    }
}

package struct StageLog: Sendable, Equatable {
    package let message: String
    package let level: LogLevel
    package let rawOutput: String?

    package var highlight: Bool { level != .info }

    package init(_ message: String, level: LogLevel = .info, rawOutput: String? = nil) {
        self.message = message
        self.level = level
        self.rawOutput = rawOutput
    }

    package init(_ message: String, highlight: Bool) {
        let lower = message.lowercased()
        let inferred: LogLevel
        if lower.hasPrefix("error")
            || lower.contains("失败")
            || lower.contains("异常")
            || lower.contains("空间不足")
            || lower.contains("拦截假包")
            || lower.contains("无法")
            || lower.contains("无效")
            || lower.contains("越出")
            || lower.contains("未找到")
            || lower.contains("未生成")
            || lower.contains("已中止") {
            inferred = .error
        } else if lower.hasPrefix("warn")
                    || lower.hasPrefix("unar")
                    || lower.contains("限速")
                    || lower.contains("过期")
                    || lower.contains("切换备")
                    || lower.contains("回退代理") {
            inferred = .warning
        } else {
            inferred = .info
        }
        self.init(message, level: inferred, rawOutput: nil)
    }
}

package struct StageOutput: Sendable, Equatable {
    package let artifact: ArtifactRef?
    package let metadata: [String: String]
    package let checklist: [CheckItem]

    package init(artifact: ArtifactRef? = nil, metadata: [String: String] = [:], checklist: [CheckItem] = []) {
        self.artifact = artifact
        self.metadata = metadata
        self.checklist = checklist
    }
}

package struct StageFailure: Sendable, Equatable {
    package let stage: StageID
    package let message: String

    package init(stage: StageID, message: String) {
        self.stage = stage
        self.message = message
    }
}

package enum StageResult: Sendable, Equatable {
    case success(StageOutput)
    case cancelled
    case failure(StageFailure)
}

package enum StageError: LocalizedError, Equatable, Sendable {
    case missingInput(stage: StageID)
    case unavailable(stage: StageID)
    case cancelled

    package var errorDescription: String? {
        switch self {
        case .missingInput(let stage): return "Stage \(stage) requires an input artifact"
        case .unavailable(let stage): return "Stage \(stage) is not registered"
        case .cancelled: return "Stage execution was cancelled"
        }
    }
}

/// A unit of work that can be executed without knowing anything about SwiftUI.
package protocol Stage: Sendable {
    var id: StageID { get }
    func execute(context: StageContext) async -> StageResult
}

/// Compile-time registration point for the stages supported by the application.
package struct StageRegistry {
    private var stages: [StageID: any Stage] = [:]

    package init(stages: [any Stage] = []) {
        for stage in stages {
            self.stages[stage.id] = stage
        }
    }

    package mutating func register(_ stage: any Stage) {
        stages[stage.id] = stage
    }

    package func stage(for id: StageID) -> (any Stage)? {
        stages[id]
    }

    package func execute(_ id: StageID, context: StageContext) async -> StageResult {
        guard let stage = stages[id] else {
            return .failure(StageFailure(stage: id, message: StageError.unavailable(stage: id).localizedDescription))
        }
        if await context.cancellationRequested() { return .cancelled }
        let result = await stage.execute(context: context)
        if await context.cancellationRequested() { return .cancelled }
        return result
    }

    package var registeredIDs: [StageID] {
        stages.keys.sorted { $0.rawValue < $1.rawValue }
    }
}

/// Serializes synchronous service callbacks and lets the caller await their delivery before finalizing a stage.
package final class StageEventQueue<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (Event) async -> Void
    private var pending: Task<Void, Never>?

    package init(handler: @escaping @Sendable (Event) async -> Void) {
        self.handler = handler
    }

    package func submit(_ event: Event) {
        lock.lock()
        let previous = pending
        let handler = self.handler
        pending = Task {
            await previous?.value
            await handler(event)
        }
        lock.unlock()
    }

    package func drain() async {
        let lastEvent = latestPendingEvent()
        await lastEvent?.value
    }

    private func latestPendingEvent() -> Task<Void, Never>? {
        lock.lock()
        let lastEvent = pending
        lock.unlock()
        return lastEvent
    }
}
