import ChrysaCore
import ChrysaApplication
import Foundation

private struct TaskStoreEnvelope: Codable {
    package let schemaVersion: Int
    package let payload: PersistedTaskSnapshot
}

package actor TaskStore: LegacyTaskLoading {
    private static let schemaVersion = 1
    private let inMemoryOnly: Bool
    private let fileURL: URL
    private var preserveUnsupportedFile = false

    package init(inMemoryOnly: Bool = false, customFileURL: URL? = nil) {
        self.inMemoryOnly = inMemoryOnly
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: ("~/Library/Application Support" as NSString).expandingTildeInPath)
        let dir = appSupport.appendingPathComponent("Chrysa", isDirectory: true)
        self.fileURL = customFileURL ?? dir.appendingPathComponent("tasks.json")
    }

    package func load() -> PersistedTaskSnapshot {
        loadResult().snapshot
    }

    package func loadResult() -> TaskStoreLoadResult {
        guard !inMemoryOnly else { return .loaded(Self.emptySnapshot) }
        let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        let data = try? Data(contentsOf: fileURL)
        if let data, Self.hasUnsupportedSchema(data) {
            preserveUnsupportedFile = true
            print("[persistence] tasks schema is newer than this app; file left untouched: \(fileURL.path)")
            return .unsupported
        }

        var decoded: PersistedTaskSnapshot
        let recovered: Bool
        if let data, let current = Self.decodeSnapshot(data) {
            preserveUnsupportedFile = false
            decoded = current
            recovered = false
        } else {
            if fileExists { Self.preserveCorruptFile(at: fileURL) }
            let backup = Self.readBackup(for: fileURL)
            if let backup, Self.hasUnsupportedSchema(backup) {
                preserveUnsupportedFile = true
                return .unsupported
            }
            if let backup, let restored = Self.decodeSnapshot(backup) {
                print("[persistence] restored tasks from backup: \(fileURL.path).bak")
                decoded = restored
                recovered = true
            } else {
                guard fileExists || backup != nil else { return .missing }
                print("[persistence] tasks file is corrupt; empty snapshot will be used: \(fileURL.path)")
                return .corrupt
            }
        }

        // Normalize any tasks that were still running when the app previously exited
        decoded.downloadTasks = decoded.downloadTasks.map(Self.normalizeInterruptedTask)
        decoded.unpackTasks = decoded.unpackTasks.map(Self.normalizeInterruptedTask)
        decoded.patchTasks = decoded.patchTasks.map(Self.normalizeInterruptedTask)
        return recovered ? .recovered(decoded) : .loaded(decoded)
    }

    package func save(_ snapshot: PersistedTaskSnapshot) {
        guard !inMemoryOnly else { return }
        guard !preserveUnsupportedFile else {
            print("[persistence] skipped task save because the file belongs to a newer schema: \(fileURL.path)")
            return
        }
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(TaskStoreEnvelope(schemaVersion: Self.schemaVersion, payload: snapshot))
            let backupURL = fileURL.appendingPathExtension("bak")
            if let existingData = try? Data(contentsOf: fileURL) {
                try existingData.write(to: backupURL, options: [.atomic])
            }
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            print("[persistence] failed to save tasks: \(error.localizedDescription)")
        }
    }

    private static let emptySnapshot = PersistedTaskSnapshot(downloadTasks: [], unpackTasks: [], patchTasks: [])

    private static func hasUnsupportedSchema(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? Int else { return false }
        return version > schemaVersion
    }

    private static func decodeSnapshot(_ data: Data) -> PersistedTaskSnapshot? {
        let decoder = JSONDecoder()
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["schemaVersion"] != nil {
            guard let envelope = try? decoder.decode(TaskStoreEnvelope.self, from: data),
                  envelope.schemaVersion > 0,
                  envelope.schemaVersion <= schemaVersion else { return nil }
            return envelope.payload
        }
        // Existing installations contain the unwrapped snapshot payload.
        return try? decoder.decode(PersistedTaskSnapshot.self, from: data)
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
            print("[persistence] preserved corrupt tasks file: \(target.path)")
        } catch {
            print("[persistence] failed to preserve corrupt tasks file: \(error.localizedDescription)")
        }
    }

    private static func normalizeInterruptedTask(_ task: StudioTask) -> StudioTask {
        var copy = task
        switch copy.status {
        case .running, .locked, .queued:
            copy.status = .failed
            copy.pill = "已中断"
        case .paused, .done, .failed:
            break
        }
        return copy
    }
}
