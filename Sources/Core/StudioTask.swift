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

    package var shortTag: String {
        switch self {
        case .download: return "DL"
        case .unpack:   return "UN"
        case .patch:    return "PT"
        case .launch:   return "RN"
        }
    }
}

package enum LogLevel: String, CaseIterable, Codable, Equatable, Sendable {
    case info
    case warning
    case error

    package var shortTag: String {
        switch self {
        case .info:    return "INF"
        case .warning: return "WRN"
        case .error:   return "ERR"
        }
    }

    package var label: String {
        switch self {
        case .info:    return "信息"
        case .warning: return "警告"
        case .error:   return "错误"
        }
    }
}

package struct LogEntry: Identifiable, Codable, Equatable, Sendable {
    package static let maxRawLines = 150
    package static let maxRawCharacters = 8_000

    private enum CodingKeys: String, CodingKey {
        case id, taskID, module, level, time, timestamp, message, rawOutput
    }

    package let id: UUID
    package let taskID: UUID?
    package let module: LogModule
    package let level: LogLevel
    package let time: String
    /// Precise local/UTC instant captured when the log was emitted. `nil` only for legacy persisted entries.
    package let timestamp: Date?
    package let message: String
    package var rawOutput: String?

    package var highlight: Bool { level != .info }

    package init(
        id: UUID = UUID(),
        taskID: UUID? = nil,
        module: LogModule = .download,
        level: LogLevel = .info,
        time: String? = nil,
        timestamp: Date? = Date(),
        message: String,
        rawOutput: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.module = module
        self.level = level
        self.timestamp = timestamp
        self.time = time ?? Self.currentTimeString(date: timestamp ?? Date())
        self.message = message
        self.rawOutput = rawOutput.flatMap { Self.sanitizeRawOutput($0) }
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        taskID = try container.decodeIfPresent(UUID.self, forKey: .taskID)
        module = try container.decodeIfPresent(LogModule.self, forKey: .module) ?? .download
        level = try container.decodeIfPresent(LogLevel.self, forKey: .level) ?? .info
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp)
        time = try container.decodeIfPresent(String.self, forKey: .time)
            ?? timestamp.map { Self.currentTimeString(date: $0) }
            ?? Self.currentTimeString()
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        rawOutput = try container.decodeIfPresent(String.self, forKey: .rawOutput)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(taskID, forKey: .taskID)
        try container.encode(module, forKey: .module)
        try container.encode(level, forKey: .level)
        try container.encode(time, forKey: .time)
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(rawOutput, forKey: .rawOutput)
    }

    // MARK: - Precision Timestamp Formatting (Thread-Safe localtime_r)

    private static func localCalendarParts(from date: Date) -> (year: Int, month: Int, day: Int, hour: Int, min: Int, sec: Int, ms: Int) {
        let interval = date.timeIntervalSince1970
        let wholeSeconds = floor(interval)
        var seconds = time_t(wholeSeconds)
        var tmVal = tm()
        localtime_r(&seconds, &tmVal)
        let ms = max(0, min(999, Int(((interval - wholeSeconds) * 1000.0).rounded())))
        return (
            year: Int(tmVal.tm_year) + 1900,
            month: Int(tmVal.tm_mon) + 1,
            day: Int(tmVal.tm_mday),
            hour: Int(tmVal.tm_hour),
            min: Int(tmVal.tm_min),
            sec: Int(tmVal.tm_sec),
            ms: ms
        )
    }

    package static func currentTimeString(date: Date = Date()) -> String {
        let p = localCalendarParts(from: date)
        return String(format: "%02d:%02d:%02d", p.hour, p.min, p.sec)
    }

    package static func formatDateString(date: Date) -> String {
        let p = localCalendarParts(from: date)
        return String(format: "%04d-%02d-%02d", p.year, p.month, p.day)
    }

    package static func formatShortDateString(date: Date) -> String {
        let p = localCalendarParts(from: date)
        return String(format: "%02d-%02d", p.month, p.day)
    }

    package static func formatTimeWithMillisString(date: Date) -> String {
        let p = localCalendarParts(from: date)
        return String(format: "%02d:%02d:%02d.%03d", p.hour, p.min, p.sec, p.ms)
    }

    package static func formatMillisSuffix(date: Date) -> String {
        let p = localCalendarParts(from: date)
        return String(format: ".%03d", p.ms)
    }

    package static func formatFullTimestamp(date: Date) -> String {
        let p = localCalendarParts(from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d.%03d", p.year, p.month, p.day, p.hour, p.min, p.sec, p.ms)
    }

    package static func formatDelta(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        if seconds < 1.0 {
            let ms = Int((seconds * 1000.0).rounded())
            return "+\(ms)ms"
        }
        if seconds < 10.0 {
            return String(format: "+%.2fs", seconds)
        }
        if seconds < 60.0 {
            return String(format: "+%.1fs", seconds)
        }
        let totalSecs = Int(seconds.rounded())
        if totalSecs < 3600 {
            return "+\(totalSecs / 60)m\(String(format: "%02ds", totalSecs % 60))"
        }
        let hrs = totalSecs / 3600
        let mins = (totalSecs % 3600) / 60
        return "+\(hrs)h\(String(format: "%02dm", mins))"
    }

    /// Combines a legacy `HH:mm:ss` string with a fallback calendar day (e.g. owning job's `updatedAt`) for chronological ordering.
    package static func combine(legacyTime: String, onCalendarDayOf referenceDate: Date) -> Date? {
        let parts = legacyTime.split(separator: ":")
        guard parts.count == 3,
              let h = Int(parts[0]), (0...23).contains(h),
              let m = Int(parts[1]), (0...59).contains(m),
              let s = Int(parts[2]), (0...59).contains(s) else {
            return nil
        }
        var cal = Calendar.current
        cal.timeZone = .current
        var comps = cal.dateComponents([.year, .month, .day], from: referenceDate)
        comps.hour = h
        comps.minute = m
        comps.second = s
        return cal.date(from: comps)
    }

    package var fullTimestampString: String {
        if let timestamp {
            return Self.formatFullTimestamp(date: timestamp)
        }
        return time
    }

    package var datePartString: String? {
        timestamp.map { Self.formatDateString(date: $0) }
    }

    package var shortDatePartString: String? {
        timestamp.map { Self.formatShortDateString(date: $0) }
    }

    package var millisSuffixString: String? {
        timestamp.map { Self.formatMillisSuffix(date: $0) }
    }

    /// Splits structured stage logs like `"7zz ▸ 检测到无加密压缩包..."` into `(tag, body)`.
    package var parsedStagePrefix: (tag: String, body: String)? {
        guard let range = message.range(of: " ▸ ") else { return nil }
        let rawTag = message[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let body = message[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTag.isEmpty, rawTag.count <= 16, !body.isEmpty else { return nil }
        return (rawTag, body)
    }

    /// Display-level heuristic for highlighting positive milestone info entries with emerald `✓ OK`.
    package var isSuccessMilestone: Bool {
        guard level == .info else { return false }
        let lower = message.lowercased()
        if lower.hasPrefix("warn ▸") || lower.hasPrefix("warning") { return false }
        let markers = [
            "完成", "已入库", "已解锁", "已写入", "已修复", "已就绪",
            "校验通过", "成功", "新增", "畅通", "已绑定", "已按设置自动清理", "已清理"
        ]
        return markers.contains { message.contains($0) }
    }

    /// Effective visual level (catches legacy persisted `"warn ▸ ..."` entries that were previously stored as `.info`).
    package var displayLevel: LogLevel {
        if level != .info { return level }
        let lower = message.lowercased()
        if lower.hasPrefix("warn ▸") || lower.hasPrefix("warning") {
            return .warning
        }
        if lower.hasPrefix("error ▸") {
            return .error
        }
        return .info
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
