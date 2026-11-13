import ChrysaCore
import ChrysaApplication
import Foundation

private struct LaunchGameStoreEnvelope: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, games, dismissedScanKeys, legacyPatchMigrationCompleted
    }

    let schemaVersion: Int
    let games: [LaunchGame]
    let dismissedScanKeys: [String]
    let legacyPatchMigrationCompleted: Bool

    init(
        schemaVersion: Int,
        games: [LaunchGame],
        dismissedScanKeys: [String],
        legacyPatchMigrationCompleted: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.games = games
        self.dismissedScanKeys = dismissedScanKeys
        self.legacyPatchMigrationCompleted = legacyPatchMigrationCompleted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        games = try container.decodeIfPresent([LaunchGame].self, forKey: .games) ?? []
        dismissedScanKeys = try container.decodeIfPresent([String].self, forKey: .dismissedScanKeys) ?? []
        legacyPatchMigrationCompleted = try container.decodeIfPresent(Bool.self, forKey: .legacyPatchMigrationCompleted) ?? false
    }
}

private struct DecodedLaunchArchive {
    let games: [LaunchGame]
    let dismissedScanKeys: Set<String>
    let legacyPatchMigrationCompleted: Bool
}

/// Independent persistent store for the Launch game library (`games.json`).
package actor LaunchGameStore: LaunchGameRepository {
    private static let schemaVersion = 1
    private let inMemoryOnly: Bool
    private let fileURL: URL
    private var preserveUnsupportedFile = false
    private var games: [UUID: LaunchGame]
    private var orderedIDs: [UUID]
    private var dismissedScanKeys: Set<String> = []
    private var legacyPatchMigrationCompleted = false

    package init(inMemoryOnly: Bool = false, customFileURL: URL? = nil, seed: [LaunchGame] = []) {
        self.inMemoryOnly = inMemoryOnly
        let deduped = LaunchGame.deduplicate(seed)
        self.games = deduped.reduce(into: [:]) { $0[$1.id] = $1 }
        self.orderedIDs = deduped.map(\.id)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: ("~/Library/Application Support" as NSString).expandingTildeInPath)
        let directory = appSupport.appendingPathComponent("Chrysa", isDirectory: true)
        self.fileURL = customFileURL ?? directory.appendingPathComponent("games.json")
    }

    package func load() -> LaunchGameStoreLoadResult {
        guard !inMemoryOnly else { return .loaded(all()) }
        let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        let data = try? Data(contentsOf: fileURL)
        if let data, Self.hasUnsupportedSchema(data) {
            preserveUnsupportedFile = true
            print("[persistence] games schema is newer than this app; file left untouched: \(fileURL.path)")
            return .unsupported
        }

        if let data, let decoded = Self.decodeArchive(data) {
            preserveUnsupportedFile = false
            dismissedScanKeys = decoded.dismissedScanKeys
            legacyPatchMigrationCompleted = decoded.legacyPatchMigrationCompleted
            let repaired = Self.repairHelperExecutables(in: decoded.games)
            let deduped = LaunchGame.deduplicate(repaired)
            applyLoadedGames(deduped)
            if deduped != decoded.games {
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
            dismissedScanKeys = restored.dismissedScanKeys
            legacyPatchMigrationCompleted = restored.legacyPatchMigrationCompleted
            let repaired = Self.repairHelperExecutables(in: restored.games)
            let deduped = LaunchGame.deduplicate(repaired)
            applyLoadedGames(deduped)
            persist()
            print("[persistence] restored games from backup: \(fileURL.path).bak")
            return .recovered(all())
        }

        guard fileExists || backup != nil else { return .missing }
        print("[persistence] games file is corrupt: \(fileURL.path)")
        return .corrupt
    }

    package func all() -> [LaunchGame] {
        orderedIDs.compactMap { games[$0] }
    }

    package func game(for id: UUID) -> LaunchGame? {
        games[id]
    }

    @discardableResult
    package func upsert(_ incoming: LaunchGame, preferIncomingMetadata: Bool) -> LaunchGame {
        if incoming.source != .crossoverScan {
            for key in incoming.allSuppressionKeys {
                dismissedScanKeys.remove(key)
            }
        }
        if let existingID = orderedIDs.first(where: { id in
            guard let existing = games[id] else { return false }
            return existing.matches(incoming)
        }), let existing = games[existingID] {
            let merged = existing.merged(with: incoming, preferIncomingMetadata: preferIncomingMetadata)
            games[existingID] = merged
            persist()
            return merged
        }
        games[incoming.id] = incoming
        orderedIDs.append(incoming.id)
        persist()
        return incoming
    }

    @discardableResult
    package func update(_ game: LaunchGame) async -> LaunchGame? {
        guard games[game.id] != nil else { return nil }
        var updated = game
        updated.updatedAt = Date()
        games[game.id] = updated
        persist()
        return updated
    }

    @discardableResult
    package func markPlayed(id: UUID, at date: Date) -> LaunchGame? {
        guard var entry = games[id] else { return nil }
        entry.lastPlayedAt = date
        entry.updatedAt = date
        games[id] = entry
        persist()
        return entry
    }

    package func remove(id: UUID, suppressRescan: Bool) {
        guard let removed = games.removeValue(forKey: id) else { return }
        orderedIDs.removeAll { $0 == id }
        if suppressRescan {
            for key in removed.allSuppressionKeys {
                dismissedScanKeys.insert(key)
            }
        }
        persist()
    }

    package func isSuppressed(_ game: LaunchGame) -> Bool {
        game.allSuppressionKeys.contains(where: { dismissedScanKeys.contains($0) })
    }

    package func clearSuppression(for game: LaunchGame) {
        var changed = false
        for key in game.allSuppressionKeys {
            if dismissedScanKeys.remove(key) != nil {
                changed = true
            }
        }
        if changed { persist() }
    }

    package func clearAllSuppressions() {
        guard !dismissedScanKeys.isEmpty else { return }
        dismissedScanKeys.removeAll()
        persist()
    }

    package func isLegacyJobMigrationCompleted() -> Bool {
        legacyPatchMigrationCompleted
    }

    package func markLegacyJobMigrationCompleted() {
        guard !legacyPatchMigrationCompleted else { return }
        legacyPatchMigrationCompleted = true
        persist()
    }

    private func applyLoadedGames(_ loaded: [LaunchGame]) {
        games = loaded.reduce(into: [:]) { $0[$1.id] = $1 }
        orderedIDs = loaded.map(\.id)
    }

    private static func repairHelperExecutables(in games: [LaunchGame]) -> [LaunchGame] {
        games.map { game in
            guard LaunchGame.isIgnoredHelperExecutable(game.exePath) else {
                return game
            }
            var updated = game
            if let dir = game.gameDirectory,
               let betterEXE = CrossOverBottleScanner.findMainExecutable(in: dir) {
                updated.exePath = betterEXE
            } else {
                updated.exePath = nil
            }
            return updated
        }
    }

    @discardableResult
    private func persist() -> Bool {
        guard !inMemoryOnly else { return true }
        guard !preserveUnsupportedFile else {
            print("[persistence] skipped game library save because file belongs to a newer schema: \(fileURL.path)")
            return false
        }

        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(LaunchGameStoreEnvelope(
                schemaVersion: Self.schemaVersion,
                games: all(),
                dismissedScanKeys: dismissedScanKeys.sorted(),
                legacyPatchMigrationCompleted: legacyPatchMigrationCompleted
            ))
            let backupURL = fileURL.appendingPathExtension("bak")
            if let existingData = try? Data(contentsOf: fileURL), Self.decodeArchive(existingData) != nil {
                try existingData.write(to: backupURL, options: [.atomic])
            }
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            print("[persistence] failed to save games: \(error.localizedDescription)")
            return false
        }
    }

    private static func hasUnsupportedSchema(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? Int else { return false }
        return version > schemaVersion
    }

    private static func decodeArchive(_ data: Data) -> DecodedLaunchArchive? {
        let decoder = JSONDecoder()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schemaVersion"] != nil,
              let envelope = try? decoder.decode(LaunchGameStoreEnvelope.self, from: data),
              envelope.schemaVersion > 0,
              envelope.schemaVersion <= schemaVersion else { return nil }
        return DecodedLaunchArchive(
            games: envelope.games,
            dismissedScanKeys: Set(envelope.dismissedScanKeys),
            legacyPatchMigrationCompleted: envelope.legacyPatchMigrationCompleted
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
            print("[persistence] preserved corrupt games file: \(target.path)")
        } catch {
            print("[persistence] failed to preserve corrupt games file: \(error.localizedDescription)")
        }
    }
}
