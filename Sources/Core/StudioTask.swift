import Foundation

package enum TaskStatus: Equatable, Codable, Sendable {
    case queued
    case running(Double)
    case locked(Double)
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

package struct LogEntry: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let time: String
    package let message: String
    package let highlight: Bool

    package init(id: UUID = UUID(), time: String, message: String, highlight: Bool) {
        self.id = id
        self.time = time
        self.message = message
        self.highlight = highlight
    }
}
