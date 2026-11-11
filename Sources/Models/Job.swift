import Foundation

/// The kind of work represented by a unified job record.
enum JobKind: String, Codable, Sendable {
    case download
    case unpack
    case patch
}

enum JobStatus: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

enum ArtifactKind: String, Codable, Sendable {
    case remoteURL
    case file
    case directory
}

struct ArtifactRef: Codable, Equatable, Sendable {
    let kind: ArtifactKind
    let value: String

    init(kind: ArtifactKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

/// A single source of truth for one download, unpack, or patch operation.
struct Job: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let kind: JobKind
    var title: String
    var status: JobStatus
    var progress: Double
    var source: ArtifactRef?
    var output: ArtifactRef?
    var message: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: JobKind,
        title: String,
        status: JobStatus = .queued,
        progress: Double = 0,
        source: ArtifactRef? = nil,
        output: ArtifactRef? = nil,
        message: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.status = status
        self.progress = Self.clampedProgress(progress)
        self.source = source
        self.output = output
        self.message = message
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    static func fromLegacy(_ task: StudioTask, kind: JobKind) -> Job {
        let status: JobStatus
        let progress: Double
        switch task.status {
        case .queued:
            status = .queued
            progress = 0
        case .running(let value), .locked(let value):
            status = .running
            progress = value
        case .done:
            status = .succeeded
            progress = 1
        case .failed:
            status = task.pill == "已停止" ? .cancelled : .failed
            progress = 0
        }

        let source: ArtifactRef?
        let output: ArtifactRef?
        switch kind {
        case .download:
            source = task.sourceURL.map { ArtifactRef(kind: .remoteURL, value: $0) }
            output = task.localPath.map { ArtifactRef(kind: .file, value: $0) }
        case .unpack:
            source = task.status == .done ? nil : task.localPath.map { ArtifactRef(kind: .file, value: $0) }
            output = task.status == .done ? task.localPath.map { ArtifactRef(kind: .directory, value: $0) } : nil
        case .patch:
            source = task.localPath.map { ArtifactRef(kind: .directory, value: $0) }
            output = task.exePath.map { ArtifactRef(kind: .file, value: $0) }
        }

        return Job(
            id: task.id,
            kind: kind,
            title: task.title,
            status: status,
            progress: progress,
            source: source,
            output: output,
            message: task.pill
        )
    }

    private static func clampedProgress(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
