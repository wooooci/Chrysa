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
    package static let maxPersistedLogs = 100

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, status, progress, source, input, output, message, pill
        case rightText, appID, isArchived, expanded, checklist, logs, listPosition, createdAt, updatedAt
    }
    package let id: UUID
    package var kind: JobKind
    package var title: String
    package var status: JobStatus
    package var progress: Double {
        didSet { progress = Self.clampedProgress(progress) }
    }
    /// Stable origin supplied by the user, such as the original share URL.
    package var source: ArtifactRef?
    /// Input consumed by the current stage.
    package var input: ArtifactRef?
    /// Most recent successful artifact produced by a stage.
    package var output: ArtifactRef?
    package var message: String?
    package var pill: String? {
        get { message }
        set { message = newValue }
    }
    package var rightText: String
    package var appID: String?
    package var isArchived: Bool
    package var expanded: Bool
    package var checklist: [CheckItem]
    package var logs: [LogEntry]
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
            input: try container.decodeIfPresent(ArtifactRef.self, forKey: .input),
            output: try container.decodeIfPresent(ArtifactRef.self, forKey: .output),
            message: try container.decodeIfPresent(String.self, forKey: .message)
                ?? container.decodeIfPresent(String.self, forKey: .pill),
            rightText: try container.decodeIfPresent(String.self, forKey: .rightText) ?? "",
            appID: try container.decodeIfPresent(String.self, forKey: .appID),
            isArchived: try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false,
            expanded: try container.decodeIfPresent(Bool.self, forKey: .expanded) ?? false,
            checklist: try container.decodeIfPresent([CheckItem].self, forKey: .checklist) ?? [],
            logs: try container.decodeIfPresent([LogEntry].self, forKey: .logs) ?? [],
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
        try container.encodeIfPresent(input, forKey: .input)
        try container.encodeIfPresent(output, forKey: .output)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encode(rightText, forKey: .rightText)
        try container.encodeIfPresent(appID, forKey: .appID)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encode(expanded, forKey: .expanded)
        try container.encode(checklist, forKey: .checklist)
        if !logs.isEmpty {
            try container.encode(Array(logs.suffix(Self.maxPersistedLogs)), forKey: .logs)
        }
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
        input: ArtifactRef? = nil,
        output: ArtifactRef? = nil,
        message: String? = nil,
        pill: String? = nil,
        rightText: String = "",
        appID: String? = nil,
        isArchived: Bool = false,
        expanded: Bool = false,
        checklist: [CheckItem] = [],
        logs: [LogEntry] = [],
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
        self.input = input
        self.output = output
        self.message = message ?? pill
        self.rightText = rightText
        self.appID = appID
        self.isArchived = isArchived
        self.expanded = expanded
        self.checklist = checklist
        self.logs = logs.count > Self.maxPersistedLogs ? Array(logs.suffix(Self.maxPersistedLogs)) : logs
        self.listPosition = listPosition
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    package mutating func appendBoundedLog(_ entry: LogEntry) {
        logs.append(entry)
        if logs.count > Self.maxPersistedLogs {
            logs.removeFirst(logs.count - Self.maxPersistedLogs)
        }
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
        let input: ArtifactRef?
        let output: ArtifactRef?
        switch kind {
        case .download:
            source = task.sourceURL.map { ArtifactRef(kind: .remoteURL, value: $0) }
            input = source
            output = task.localPath.map { ArtifactRef(kind: .file, value: $0) }
        case .unpack:
            source = task.status == .done ? nil : task.localPath.map { ArtifactRef(kind: .file, value: $0) }
            input = task.status == .done ? nil : source
            output = task.status == .done ? task.localPath.map { ArtifactRef(kind: .directory, value: $0) } : nil
        case .patch:
            source = task.localPath.map { ArtifactRef(kind: .directory, value: $0) }
            input = source
            output = task.exePath.map { ArtifactRef(kind: .file, value: $0) }
        }

        return Job(
            id: task.id,
            kind: kind,
            title: task.title,
            status: status,
            progress: progress,
            source: source,
            input: input,
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

        let sourceURL = source?.kind == .remoteURL ? source?.value : nil
        let localPath: String?
        let exePath: String?
        switch kind {
        case .download:
            localPath = output?.kind == .file ? output?.value : nil
            exePath = nil
        case .unpack:
            localPath = status == .succeeded ? output?.value : (input?.value ?? source?.value)
            exePath = nil
        case .patch:
            localPath = input?.kind == .directory ? input?.value : source?.value
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


    package var sourceURL: String? {
        source?.kind == .remoteURL ? source?.value : nil
    }

    package var localPath: String? {
        switch kind {
        case .download:
            return output?.kind == .file ? output?.value : nil
        case .unpack:
            return status == .succeeded ? output?.value : (input?.value ?? source?.value)
        case .patch:
            return input?.kind == .directory ? input?.value : source?.value
        }
    }

    package var exePath: String? {
        kind == .patch && output?.kind == .file ? output?.value : nil
    }

    /// True when this patch record was synthesized by `CrossOverBottleScanner` rather than a direct user pipeline run.
    package var isScannerDiscoveredPatch: Bool {
        kind == .patch && input == nil && checklist.contains { $0.title.hasPrefix("CrossOver 容器 [") }
    }

    package static func normalizedPatchIdentityTitle(_ raw: String) -> String {
        let folded = raw
            .lowercased()
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
        let allowed = CharacterSet.alphanumerics
        return String(folded.unicodeScalars.filter { allowed.contains($0) })
    }

    private static func standardizedPath(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }

    private var candidatePatchDirectories: [String] {
        var dirs: [String] = []
        if input?.kind == .directory, let p = Self.standardizedPath(input?.value) {
            dirs.append(p)
        }
        if source?.kind == .directory, let p = Self.standardizedPath(source?.value), !dirs.contains(p) {
            dirs.append(p)
        }
        return dirs
    }

    /// Determines whether a newly scanned bottle record refers to the same installed game as an existing patch job.
    package func matchesDiscoveredPatchBottle(_ discovered: Job) -> Bool {
        guard kind == .patch, discovered.kind == .patch else { return false }

        let lhsTitle = Self.normalizedPatchIdentityTitle(title)
        let rhsTitle = Self.normalizedPatchIdentityTitle(discovered.title)
        if !lhsTitle.isEmpty, lhsTitle == rhsTitle {
            return true
        }

        if let lhsExe = Self.standardizedPath(exePath),
           let rhsExe = Self.standardizedPath(discovered.exePath),
           lhsExe == rhsExe {
            return true
        }

        let lhsDirs = candidatePatchDirectories
        let rhsDirs = discovered.candidatePatchDirectories
        for d1 in lhsDirs {
            for d2 in rhsDirs {
                if d1 == d2 || d2.hasPrefix(d1 + "/") || d1.hasPrefix(d2 + "/") {
                    return true
                }
            }
        }

        if let a = appID, let b = discovered.appID, !a.isEmpty, a != "480", a == b {
            return true
        }

        return false
    }

    /// Collapses duplicate `.patch` records produced by legacy migration or bottle scanning while keeping distinct user pipeline runs intact.
    package static func deduplicatePatchJobs(_ jobs: [Job]) -> [Job] {
        var result: [Job] = []
        result.reserveCapacity(jobs.count)

        for candidate in jobs {
            guard candidate.kind == .patch else {
                result.append(candidate)
                continue
            }

            if let idx = result.firstIndex(where: { existing in
                guard existing.kind == .patch else { return false }
                if existing.id == candidate.id { return true }

                // Exact same game directory or exact same executable file on disk
                if let e1 = standardizedPath(existing.exePath),
                   let e2 = standardizedPath(candidate.exePath),
                   e1 == e2 {
                    return true
                }
                let dirs1 = existing.candidatePatchDirectories
                let dirs2 = candidate.candidatePatchDirectories
                if !dirs1.isEmpty, !dirs2.isEmpty, dirs1.contains(where: { dirs2.contains($0) }) {
                    return true
                }

                // If either entry is a scanner-synthesized bottle record, also match by normalized title / nested game folder / non-480 AppID
                if existing.isScannerDiscoveredPatch || candidate.isScannerDiscoveredPatch {
                    return existing.matchesDiscoveredPatchBottle(candidate)
                }
                return false
            }) {
                result[idx] = mergeDuplicatePatchPair(result[idx], candidate)
            } else {
                result.append(candidate)
            }
        }
        return result
    }

    private static func mergeDuplicatePatchPair(_ lhs: Job, _ rhs: Job) -> Job {
        // Prefer the direct/migrated user job (which has `input != nil` and detailed patch checklist) over a synthetic scanner job
        let primary: Job
        let secondary: Job
        if lhs.isScannerDiscoveredPatch && !rhs.isScannerDiscoveredPatch {
            primary = rhs
            secondary = lhs
        } else {
            primary = lhs
            secondary = rhs
        }

        var merged = primary
        if merged.source == nil { merged.source = secondary.source }
        if merged.input == nil { merged.input = secondary.input }
        if merged.output == nil { merged.output = secondary.output }
        if merged.appID == nil || merged.appID?.isEmpty == true { merged.appID = secondary.appID }
        if merged.checklist.isEmpty { merged.checklist = secondary.checklist }
        if merged.logs.isEmpty { merged.logs = secondary.logs }
        merged.isArchived = lhs.isArchived || rhs.isArchived
        merged.expanded = lhs.expanded || rhs.expanded
        merged.listPosition = min(lhs.listPosition, rhs.listPosition)
        return merged
    }

    package static func clampedProgress(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }
}
