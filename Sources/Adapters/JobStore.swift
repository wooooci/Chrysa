import ChrysaCore
import ChrysaApplication
import Foundation

private struct JobStoreEnvelope: Codable {
    package let schemaVersion: Int
    package let jobs: [Job]
}

/// The authoritative task repository after the Job/Stage migration.
package actor JobStore: JobRepository {
    private static let schemaVersion = 1
    private let inMemoryOnly: Bool
    private let fileURL: URL
    private var preserveUnsupportedFile = false
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

        if let data, let decoded = Self.decodeJobs(data) {
            preserveUnsupportedFile = false
            jobs = Self.normalizeInterruptedJobs(decoded)
            if jobs.values.sorted(by: Self.jobOrder) != decoded.sorted(by: Self.jobOrder) {
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
        if let backup, let restored = Self.decodeJobs(backup) {
            jobs = Self.normalizeInterruptedJobs(restored)
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
        guard result.canMigrateLegacyData else { return result }

        switch await legacyStore.loadResult() {
        case .loaded(let snapshot), .recovered(let snapshot):
            jobs = Self.indexed(Self.jobs(from: snapshot))
            return persist() ? .migrated(all()) : .migrationPending(all())
        case .unsupported:
            // Keep migration pending until a version that can read the legacy file runs.
            preserveUnsupportedFile = true
            return .unsupported
        case .missing:
            return result
        case .corrupt:
            return .corrupt
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
            let data = try encoder.encode(JobStoreEnvelope(schemaVersion: Self.schemaVersion, jobs: all()))
            let backupURL = fileURL.appendingPathExtension("bak")
            if let existingData = try? Data(contentsOf: fileURL), Self.decodeJobs(existingData) != nil {
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

    private static func decodeJobs(_ data: Data) -> [Job]? {
        let decoder = JSONDecoder()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schemaVersion"] != nil,
              let envelope = try? decoder.decode(JobStoreEnvelope.self, from: data),
              envelope.schemaVersion > 0,
              envelope.schemaVersion <= schemaVersion else { return nil }
        return envelope.jobs
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
                job.updatedAt = Date()
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
        case .queued, .running: return false
        }
    }
}
