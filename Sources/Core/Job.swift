import Foundation

/// The kind of work represented by a unified job record.
package enum JobKind: String, Codable, Sendable {
    case download
    case unpack
    case patch
}

package enum JobStatus: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

package enum ArtifactKind: String, Codable, Sendable {
    case remoteURL
    case file
    case directory
}

package struct ArtifactRef: Codable, Equatable, Sendable {
    package let kind: ArtifactKind
    package let value: String

    package init(kind: ArtifactKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

/// A single source of truth for one download, unpack, or patch operation.
package struct Job: Identifiable, Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, title, status, progress, source, output, message
        case rightText, appID, isArchived, expanded, checklist, listPosition, createdAt, updatedAt
    }

    package let id: UUID
    package var kind: JobKind
    package var title: String
    package var status: JobStatus
    package var progress: Double {
        didSet { progress = Self.clampedProgress(progress) }
    }
    package var source: ArtifactRef?
    package var output: ArtifactRef?
    package var message: String?
    package var rightText: String
    package var appID: String?
    package var isArchived: Bool
    package var expanded: Bool
    package var checklist: [CheckItem]
    package var listPosition: Int
    package let createdAt: Date
    package var updatedAt: Date

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            kind: try container.decode(JobKind.self, forKey: .kind),
            title: try container.decode(String.self, forKey: .title),
            status: try container.decodeIfPresent(JobStatus.self, forKey: .status) ?? .queued,
            progress: try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0,
            source: try container.decodeIfPresent(ArtifactRef.self, forKey: .source),
            output: try container.decodeIfPresent(ArtifactRef.self, forKey: .output),
            message: try container.decodeIfPresent(String.self, forKey: .message),
            rightText: try container.decodeIfPresent(String.self, forKey: .rightText) ?? "",
            appID: try container.decodeIfPresent(String.self, forKey: .appID),
            isArchived: try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false,
            expanded: try container.decodeIfPresent(Bool.self, forKey: .expanded) ?? false,
            checklist: try container.decodeIfPresent([CheckItem].self, forKey: .checklist) ?? [],
            listPosition: try container.decodeIfPresent(Int.self, forKey: .listPosition) ?? 0,
            createdAt: createdAt,
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        )
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(status, forKey: .status)
        try container.encode(progress, forKey: .progress)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(output, forKey: .output)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encode(rightText, forKey: .rightText)
        try container.encodeIfPresent(appID, forKey: .appID)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encode(expanded, forKey: .expanded)
        try container.encode(checklist, forKey: .checklist)
        try container.encode(listPosition, forKey: .listPosition)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    package init(
        id: UUID = UUID(),
        kind: JobKind,
        title: String,
        status: JobStatus = .queued,
        progress: Double = 0,
        source: ArtifactRef? = nil,
        output: ArtifactRef? = nil,
        message: String? = nil,
        rightText: String = "",
        appID: String? = nil,
        isArchived: Bool = false,
        expanded: Bool = false,
        checklist: [CheckItem] = [],
        listPosition: Int = 0,
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
        self.rightText = rightText
        self.appID = appID
        self.isArchived = isArchived
        self.expanded = expanded
        self.checklist = checklist
        self.listPosition = listPosition
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    package static func fromLegacy(_ task: StudioTask, kind: JobKind) -> Job {
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
            message: task.pill,
            rightText: task.rightText,
            appID: task.appID,
            isArchived: task.isArchived,
            expanded: task.expanded,
            checklist: task.checklist
        )
    }

    package func legacyTask() -> StudioTask {
        let legacyStatus: TaskStatus
        switch status {
        case .queued:
            legacyStatus = .queued
        case .running:
            legacyStatus = kind == .unpack ? .locked(progress) : .running(progress)
        case .succeeded:
            legacyStatus = .done
        case .failed, .cancelled:
            legacyStatus = .failed
        }

        let sourceURL = kind == .download && source?.kind == .remoteURL ? source?.value : nil
        let localPath: String?
        let exePath: String?
        switch kind {
        case .download:
            localPath = output?.kind == .file ? output?.value : nil
            exePath = nil
        case .unpack:
            localPath = status == .succeeded ? output?.value : source?.value
            exePath = nil
        case .patch:
            localPath = source?.value
            exePath = output?.kind == .file ? output?.value : nil
        }

        return StudioTask(
            id: id,
            title: title,
            status: legacyStatus,
            pill: message,
            rightText: rightText,
            sourceURL: sourceURL,
            localPath: localPath,
            exePath: exePath,
            appID: appID,
            isArchived: isArchived,
            expanded: expanded,
            checklist: checklist
        )
    }

    package var taskStatus: TaskStatus {
        switch status {
        case .queued:
            return .queued
        case .running:
            return kind == .unpack ? .locked(progress) : .running(progress)
        case .succeeded:
            return .done
        case .failed, .cancelled:
            return .failed
        }
    }

    package var pill: String? { message }

    package var sourceURL: String? {
        kind == .download && source?.kind == .remoteURL ? source?.value : nil
    }

    package var localPath: String? {
        switch kind {
        case .download:
            return output?.kind == .file ? output?.value : nil
        case .unpack:
            return status == .succeeded ? output?.value : source?.value
        case .patch:
            return source?.value
        }
    }

    package var exePath: String? {
        kind == .patch && output?.kind == .file ? output?.value : nil
    }

    package static func clampedProgress(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }
}
