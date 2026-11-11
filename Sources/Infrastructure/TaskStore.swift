import Foundation

actor TaskStore {
    private let inMemoryOnly: Bool
    private let fileURL: URL

    init(inMemoryOnly: Bool = false, customFileURL: URL? = nil) {
        self.inMemoryOnly = inMemoryOnly
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: ("~/Library/Application Support" as NSString).expandingTildeInPath)
        let dir = appSupport.appendingPathComponent("Chrysa", isDirectory: true)
        self.fileURL = customFileURL ?? dir.appendingPathComponent("tasks.json")
    }

    func load() -> PersistedTaskSnapshot {
        guard !inMemoryOnly,
              let data = try? Data(contentsOf: fileURL),
              var decoded = try? JSONDecoder().decode(PersistedTaskSnapshot.self, from: data) else {
            return PersistedTaskSnapshot(downloadTasks: [], unpackTasks: [], patchTasks: [])
        }

        // Normalize any tasks that were still running when the app previously exited
        decoded.downloadTasks = decoded.downloadTasks.map(Self.normalizeInterruptedTask)
        decoded.unpackTasks = decoded.unpackTasks.map(Self.normalizeInterruptedTask)
        decoded.patchTasks = decoded.patchTasks.map(Self.normalizeInterruptedTask)
        return decoded
    }

    func save(_ snapshot: PersistedTaskSnapshot) {
        guard !inMemoryOnly else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func normalizeInterruptedTask(_ task: StudioTask) -> StudioTask {
        var copy = task
        switch copy.status {
        case .running, .locked, .queued:
            copy.status = .failed
            copy.pill = "已中断"
        case .done, .failed:
            break
        }
        return copy
    }
}
