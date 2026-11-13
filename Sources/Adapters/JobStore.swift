import ChrysaCore
import ChrysaApplication
import Foundation

private struct JobStoreEnvelope: Codable {
    private enum CodingKeys: String, CodingKey { case schemaVersion, jobs, legacyTaskMigrationCompleted }

    package let schemaVersion: Int
    package let jobs: [Job]
    package let legacyTaskMigrationCompleted: Bool

    package init(schemaVersion: Int, jobs: [Job], legacyTaskMigrationCompleted: Bool) {
        self.schemaVersion = schemaVersion
        self.jobs = jobs
        self.legacyTaskMigrationCompleted = legacyTaskMigrationCompleted
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        jobs = try container.decode([Job].self, forKey: .jobs)
        legacyTaskMigrationCompleted = try container.decodeIfPresent(Bool.self, forKey: .legacyTaskMigrationCompleted) ?? false
    }
}

private struct DecodedJobArchive {
    let jobs: [Job]
    let legacyTaskMigrationCompleted: Bool
}

/// The authoritative task repository after the Job/Stage migration.
package actor JobStore: JobRepository {
    private static let schemaVersion = 2
    private let inMemoryOnly: Bool
    private let fileURL: URL
    private var preserveUnsupportedFile = false
    private var legacyTaskMigrationCompleted = false
    private var jobs: [UUID: Job]

    package init(inMemoryOnly: Bool = false, customFileURL: URL? = nil, seed: [Job] = []) {
        self.inMemoryOnly = inMemoryOnly
        self.jobs = Self.indexed(seed)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: ("~/Library/Application Support" as NSString).expandingTildeInPath)
        let directory = appSupport.appendingPathComponent("Chrysa", isDirectory: true)
        self.fileURL = customFileURL ?? directory.appendingPathComponent("jobs.json")
    }

    package func load() -> JobStoreLoadResult {
        guard !inMemoryOnly else { return .loaded(all()) }
        let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        let data = try? Data(contentsOf: fileURL)
        if let data, Self.hasUnsupportedSchema(data) {
            preserveUnsupportedFile = true
            print("[persistence] jobs schema is newer than this app; file left untouched: \(fileURL.path)")
            return .unsupported
        }

        if let data, let decoded = Self.decodeArchive(data) {
            preserveUnsupportedFile = false
            legacyTaskMigrationCompleted = decoded.legacyTaskMigrationCompleted
            let deduped = Job.deduplicatePatchJobs(decoded.jobs.sorted(by: Self.jobOrder))
            jobs = Self.normalizeInterruptedJobs(deduped)
            if jobs.values.sorted(by: Self.jobOrder) != decoded.jobs.sorted(by: Self.jobOrder) {
                persist()
            }
            return .loaded(all())
        }

        if fileExists { Self.preserveCorruptFile(at: fileURL) }
        let backup = Self.readBackup(for: fileURL)
        if let backup, Self.hasUnsupportedSchema(backup) {
            preserveUnsupportedFile = true
            return .unsupported
        }
        if let backup, let restored = Self.decodeArchive(backup) {
            legacyTaskMigrationCompleted = restored.legacyTaskMigrationCompleted
            let deduped = Job.deduplicatePatchJobs(restored.jobs.sorted(by: Self.jobOrder))
            jobs = Self.normalizeInterruptedJobs(deduped)
            persist()
            print("[persistence] restored jobs from backup: \(fileURL.path).bak")
            return .recovered(all())
        }

        guard fileExists || backup != nil else { return .missing }
        print("[persistence] jobs file is corrupt; legacy migration may be attempted: \(fileURL.path)")
        return .corrupt
    }

    package func load(migratingLegacyStore legacyStore: any LegacyTaskLoading) async -> JobStoreLoadResult {
        let result = load()
        guard !inMemoryOnly, !preserveUnsupportedFile, !legacyTaskMigrationCompleted else { return result }

        switch await legacyStore.loadResult() {
        case .loaded(let snapshot), .recovered(let snapshot):
            // Merge by stable ID and collapse duplicate patch records created before migration completed.
            var merged = Self.indexed(Self.jobs(from: snapshot))
            for current in jobs.values {
                merged[current.id] = current
            }
            let deduped = Job.deduplicatePatchJobs(merged.values.sorted(by: Self.jobOrder))
            jobs = Self.indexed(deduped)
            legacyTaskMigrationCompleted = true
            return persist() ? .migrated(all()) : .migrationPending(all())
        case .missing:
            legacyTaskMigrationCompleted = true
            guard persist() else { return .migrationPending(all()) }
            if case .missing = result { return .loaded(all()) }
            return result
        case .unsupported:
            // Do not create a shadow archive when the only source is from a newer app.
            if jobs.isEmpty, case .missing = result {
                preserveUnsupportedFile = true
                return .unsupported
            }
            // Keep readable jobs visible; retain the migration marker for a future retry.
            return .migrationPending(all())
        case .corrupt:
            if jobs.isEmpty, case .missing = result { return .corrupt }
            return .migrationPending(all())
        }
    }

    @discardableResult
    package func upsert(_ job: Job) -> Job {
        if let existing = jobs[job.id], existing.status.isTerminal { return existing }
        jobs[job.id] = job
        persist()
        return job
    }

    package func synchronizePresentation(from snapshot: PersistedTaskSnapshot) {
        synchronizePresentation(from: Self.jobs(from: snapshot))
    }

    package func synchronizePresentation(from incoming: [Job]) {
        for presented in incoming {
            guard var current = jobs[presented.id] else {
                jobs[presented.id] = presented
                continue
            }
            guard current.kind == presented.kind else { continue }
            current.title = presented.title
            current.source = presented.source ?? current.source
            current.input = presented.input ?? current.input
            current.output = presented.output ?? current.output
            if current.status == presented.status { current.message = presented.message }
            current.rightText = presented.rightText
            current.appID = presented.appID
            current.isArchived = presented.isArchived
            current.expanded = presented.expanded
            current.checklist = presented.checklist
            current.listPosition = presented.listPosition
            current.updatedAt = Date()
            jobs[current.id] = current
        }
        persist()
    }

    package func job(for id: UUID) -> Job? {
        jobs[id]
    }

    package func all() -> [Job] {
        jobs.values.sorted(by: Self.jobOrder)
    }

    @discardableResult
    package func update(
        id: UUID,
        kind: JobKind? = nil,
        status: JobStatus? = nil,
        progress: Double? = nil,
        title: String? = nil,
        source: ArtifactRef? = nil,
        input: ArtifactRef? = nil,
        output: ArtifactRef? = nil,
        message: String? = nil,
        clearMessage: Bool = false,
        rightText: String? = nil,
        appID: String? = nil,
        checklist: [CheckItem]? = nil,
        isArchived: Bool? = nil,
        expanded: Bool? = nil,
        listPosition: Int? = nil
    ) -> Job? {
        guard var job = jobs[id] else { return nil }
        // Reject the whole workflow callback, including its labels and output, after completion.
        guard !job.status.isTerminal || (status == nil && progress == nil) else { return nil }
        if let kind { job.kind = kind }
        if let status { job.status = status }
        if let progress { job.progress = progress }
        if let title { job.title = title }
        if let source { job.source = source }
        if let input { job.input = input }
        if let output { job.output = output }
        if clearMessage {
            job.message = nil
        } else if let message {
            job.message = message
        }
        if let rightText { job.rightText = rightText }
        if let appID { job.appID = appID }
        if let checklist { job.checklist = checklist }
        if let isArchived { job.isArchived = isArchived }
        if let expanded { job.expanded = expanded }
        if let listPosition { job.listPosition = listPosition }
        job.updatedAt = Date()
        jobs[id] = job
        persist()
        return job
    }

    @discardableResult
    package func updateDownloadMetadata(
        id: UUID,
        passwordHint: String?,
        downloadParts: [DownloadPart]?
    ) -> Job? {
        guard var job = jobs[id] else { return nil }
        if let passwordHint { job.passwordHint = passwordHint }
        if let downloadParts { job.downloadParts = downloadParts }
        job.updatedAt = Date()
        jobs[id] = job
        persist()
        return job
    }

    @discardableResult
    package func reopenForResume(
        id: UUID,
        status: JobStatus,
        message: String?,
        rightText: String?
    ) -> Job? {
        guard var job = jobs[id] else { return nil }
        job.status = status
        job.message = message
        if let rightText { job.rightText = rightText }
        job.updatedAt = Date()
        jobs[id] = job
        persist()
        return job
    }

    @discardableResult
    package func appendLog(_ entry: LogEntry, to id: UUID) -> Job? {
        guard var job = jobs[id] else { return nil }
        job.appendBoundedLog(entry)
        job.updatedAt = Date()
        jobs[id] = job
        persist()
        return job
    }
    package func remove(id: UUID) {
        guard jobs.removeValue(forKey: id) != nil else { return }
        persist()
    }

    package func removeAll() {
        guard !jobs.isEmpty else { return }
        jobs.removeAll()
        persist()
    }

    @discardableResult
    private func persist() -> Bool {
        guard !inMemoryOnly else { return true }
        guard !preserveUnsupportedFile else {
            print("[persistence] skipped job save because the file belongs to a newer schema: \(fileURL.path)")
            return false
        }

        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(JobStoreEnvelope(
                schemaVersion: Self.schemaVersion,
                jobs: all(),
                legacyTaskMigrationCompleted: legacyTaskMigrationCompleted
            ))
            let backupURL = fileURL.appendingPathExtension("bak")
            if let existingData = try? Data(contentsOf: fileURL), Self.decodeArchive(existingData) != nil {
                try existingData.write(to: backupURL, options: [.atomic])
            }
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            print("[persistence] failed to save jobs: \(error.localizedDescription)")
            return false
        }
    }

    private static func jobOrder(_ lhs: Job, _ rhs: Job) -> Bool {
        if lhs.listPosition != rhs.listPosition { return lhs.listPosition < rhs.listPosition }
        if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
        return lhs.createdAt > rhs.createdAt
    }

    private static func indexed(_ jobs: [Job]) -> [UUID: Job] {
        jobs.reduce(into: [:]) { result, job in result[job.id] = job }
    }

    private static func jobs(from snapshot: PersistedTaskSnapshot) -> [Job] {
        let lists: [(JobKind, [StudioTask])] = [
            (.download, snapshot.downloadTasks), (.unpack, snapshot.unpackTasks), (.patch, snapshot.patchTasks)
        ]
        return lists.flatMap { kind, tasks in
            tasks.enumerated().map { position, task in
                var job = Job.fromLegacy(task, kind: kind)
                job.listPosition = position
                return job
            }
        }
    }

    private static func hasUnsupportedSchema(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? Int else { return false }
        return version > schemaVersion
    }

    private static func decodeArchive(_ data: Data) -> DecodedJobArchive? {
        let decoder = JSONDecoder()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schemaVersion"] != nil,
              let envelope = try? decoder.decode(JobStoreEnvelope.self, from: data),
              envelope.schemaVersion > 0,
              envelope.schemaVersion <= schemaVersion else { return nil }
        return DecodedJobArchive(
            jobs: envelope.jobs,
            legacyTaskMigrationCompleted: envelope.legacyTaskMigrationCompleted
        )
    }

    private static func readBackup(for url: URL) -> Data? {
        try? Data(contentsOf: url.appendingPathExtension("bak"))
    }

    private static func preserveCorruptFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var target = url.appendingPathExtension("corrupt")
        if FileManager.default.fileExists(atPath: target.path) {
            target = url.appendingPathExtension("corrupt-\(UUID().uuidString)")
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            print("[persistence] preserved corrupt jobs file: \(target.path)")
        } catch {
            print("[persistence] failed to preserve corrupt jobs file: \(error.localizedDescription)")
        }
    }

    private static func normalizeInterruptedJobs(_ source: [Job]) -> [UUID: Job] {
        var normalized: [UUID: Job] = [:]
        for original in source {
            var job = original
            switch job.status {
            case .queued, .running:
                job.status = .failed
                job.message = "已中断"
                if var parts = job.downloadParts {
                    for idx in parts.indices where parts[idx].status == .running || parts[idx].status == .queued {
                        parts[idx].status = .paused
                        parts[idx].speedBytesPerSec = 0
                        parts[idx].message = "已中断"
                    }
                    job.downloadParts = parts
                }
                job.updatedAt = Date()
            case .paused:
                if var parts = job.downloadParts {
                    for idx in parts.indices where parts[idx].status == .running || parts[idx].status == .queued {
                        parts[idx].status = .paused
                        parts[idx].speedBytesPerSec = 0
                        parts[idx].message = "已暂停"
                    }
                    job.downloadParts = parts
                }
            case .succeeded, .failed, .cancelled:
                break
            }
            normalized[job.id] = job
        }
        return normalized
    }
}

private extension JobStatus {
    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: return true
        case .queued, .running, .paused: return false
        }
    }
}
