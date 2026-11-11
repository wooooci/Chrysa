import Foundation

/// In-memory repository used by the first migration slice.
/// Persistence remains owned by TaskStore until the compatibility bridge is complete.
actor JobStore {
    private var jobs: [UUID: Job]

    init(seed: [Job] = []) {
        self.jobs = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) })
    }

    func upsert(_ job: Job) {
        jobs[job.id] = job
    }

    func job(for id: UUID) -> Job? {
        jobs[id]
    }

    func all() -> [Job] {
        jobs.values.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    func update(
        id: UUID,
        status: JobStatus? = nil,
        progress: Double? = nil,
        title: String? = nil,
        output: ArtifactRef? = nil,
        message: String? = nil
    ) {
        guard var job = jobs[id] else { return }
        if job.status.isTerminal { return }
        if let status { job.status = status }
        if let progress { job.progress = min(max(progress, 0), 1) }
        if let title { job.title = title }
        if let output { job.output = output }
        if let message { job.message = message }
        job.updatedAt = Date()
        jobs[id] = job
    }

    func remove(id: UUID) {
        jobs.removeValue(forKey: id)
    }

    func removeAll() {
        jobs.removeAll()
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
