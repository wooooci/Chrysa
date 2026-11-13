import Foundation

package enum TaskStatus: Equatable, Codable, Sendable {
    case queued
    case running(Double)
    case locked(Double)
    case paused(Double)
    case done
    case failed
}

package struct CheckItem: Identifiable, Equatable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey { case id, title, isChecked }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        isChecked = try container.decodeIfPresent(Bool.self, forKey: .isChecked) ?? false
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(isChecked, forKey: .isChecked)
    }
    package var id: UUID
    package var title: String
    package var isChecked: Bool

    package init(id: UUID = UUID(), title: String, isChecked: Bool) {
        self.id = id
        self.title = title
        self.isChecked = isChecked
    }
}

package struct StudioTask: Identifiable, Equatable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id, title, status, pill, rightText, sourceURL, localPath, exePath, appID
        case isArchived, expanded, checklist
    }

    package init(from decoder: Decoder) throws {
        let defaults = StudioTask(id: UUID(), title: "", status: .failed)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? defaults.id
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? defaults.title
        status = try container.decodeIfPresent(TaskStatus.self, forKey: .status) ?? defaults.status
        pill = try container.decodeIfPresent(String.self, forKey: .pill) ?? nil
        rightText = try container.decodeIfPresent(String.self, forKey: .rightText) ?? ""
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL) ?? nil
        localPath = try container.decodeIfPresent(String.self, forKey: .localPath) ?? nil
        exePath = try container.decodeIfPresent(String.self, forKey: .exePath) ?? nil
        appID = try container.decodeIfPresent(String.self, forKey: .appID) ?? nil
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        expanded = try container.decodeIfPresent(Bool.self, forKey: .expanded) ?? false
        checklist = try container.decodeIfPresent([CheckItem].self, forKey: .checklist) ?? []
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(pill, forKey: .pill)
        try container.encode(rightText, forKey: .rightText)
        try container.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try container.encodeIfPresent(localPath, forKey: .localPath)
        try container.encodeIfPresent(exePath, forKey: .exePath)
        try container.encodeIfPresent(appID, forKey: .appID)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encode(expanded, forKey: .expanded)
        try container.encode(checklist, forKey: .checklist)
    }
    package let id: UUID
    package var title: String
    package var status: TaskStatus
    package var pill: String?
    package var rightText: String
    package var sourceURL: String?
    package var localPath: String?
    package var exePath: String?
    package var appID: String?
    package var isArchived: Bool = false
    package var expanded: Bool = false
    package var checklist: [CheckItem] = []

    package init(
        id: UUID = UUID(),
        title: String,
        status: TaskStatus,
        pill: String? = nil,
        rightText: String = "",
        sourceURL: String? = nil,
        localPath: String? = nil,
        exePath: String? = nil,
        appID: String? = nil,
        isArchived: Bool = false,
        expanded: Bool = false,
        checklist: [CheckItem] = []
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.pill = pill
        self.rightText = rightText
        self.sourceURL = sourceURL
        self.localPath = localPath
        self.exePath = exePath
        self.appID = appID
        self.isArchived = isArchived
        self.expanded = expanded
        self.checklist = checklist
    }
}

package struct PersistedTaskSnapshot: Codable, Sendable {
    private enum CodingKeys: String, CodingKey { case downloadTasks, unpackTasks, patchTasks }

    package var downloadTasks: [StudioTask]
    package var unpackTasks: [StudioTask]
    package var patchTasks: [StudioTask]

    package init(downloadTasks: [StudioTask], unpackTasks: [StudioTask], patchTasks: [StudioTask]) {
        self.downloadTasks = downloadTasks
        self.unpackTasks = unpackTasks
        self.patchTasks = patchTasks
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downloadTasks = try container.decodeIfPresent([StudioTask].self, forKey: .downloadTasks) ?? []
        unpackTasks = try container.decodeIfPresent([StudioTask].self, forKey: .unpackTasks) ?? []
        patchTasks = try container.decodeIfPresent([StudioTask].self, forKey: .patchTasks) ?? []
    }
}

package enum LogModule: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case download
    case unpack
    case patch
    case launch

    package var id: String { rawValue }

    package var label: String {
        switch self {
        case .download: return "下载"
        case .unpack:   return "解压"
        case .patch:    return "补丁"
        case .launch:   return "启动"
        }
    }
}

package enum LogLevel: String, CaseIterable, Codable, Equatable, Sendable {
    case info
    case warning
    case error
}

package struct LogEntry: Identifiable, Codable, Equatable, Sendable {
    package static let maxRawLines = 150
    package static let maxRawCharacters = 8_000

    package let id: UUID
    package let taskID: UUID?
    package let module: LogModule
    package let level: LogLevel
    package let time: String
    package let message: String
    package var rawOutput: String?

    package var highlight: Bool { level != .info }

    package init(
        id: UUID = UUID(),
        taskID: UUID? = nil,
        module: LogModule = .download,
        level: LogLevel = .info,
        time: String = Self.currentTimeString(),
        message: String,
        rawOutput: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.module = module
        self.level = level
        self.time = time
        self.message = message
        self.rawOutput = rawOutput.flatMap { Self.sanitizeRawOutput($0) }
    }

    package static func currentTimeString(date: Date = Date()) -> String {
        var seconds = time_t(date.timeIntervalSince1970)
        var tmVal = tm()
        localtime_r(&seconds, &tmVal)
        return String(format: "%02d:%02d:%02d", tmVal.tm_hour, tmVal.tm_min, tmVal.tm_sec)
    }

    package static func sanitizeRawOutput(_ raw: String, redact secrets: [String] = []) -> String? {
        guard !raw.isEmpty else { return nil }
        var working = raw
        for secret in secrets where !secret.isEmpty {
            working = working.replacingOccurrences(of: secret, with: "***")
        }

        let rawLines = working
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var filtered: [String] = []
        filtered.reserveCapacity(min(rawLines.count, maxRawLines))
        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Filter out repetitive aria2 / 7zz percentage progress-bar ticks
            if trimmed.hasPrefix("[#") && trimmed.contains("%)") && trimmed.contains("DL:") {
                continue
            }
            if trimmed.range(of: #"^[0-9]{1,3}%\s*[-A-Za-z0-9_./]*$"#, options: .regularExpression) != nil {
                continue
            }
            if filtered.last == trimmed {
                continue
            }
            filtered.append(trimmed)
        }

        guard !filtered.isEmpty else { return nil }
        let tailLines = filtered.suffix(maxRawLines)
        var joined = tailLines.joined(separator: "\n")
        if joined.count > maxRawCharacters {
            joined = String(joined.suffix(maxRawCharacters))
        }
        return joined.isEmpty ? nil : joined
    }
}
