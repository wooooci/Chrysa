import Foundation

enum TaskStatus: Equatable, Codable, Sendable {
    case queued
    case running(Double)
    case locked(Double)
    case done
    case failed
}

struct CheckItem: Identifiable, Equatable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey { case id, title, isChecked }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        isChecked = try container.decodeIfPresent(Bool.self, forKey: .isChecked) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(isChecked, forKey: .isChecked)
    }
    var id: UUID
    var title: String
    var isChecked: Bool

    init(id: UUID = UUID(), title: String, isChecked: Bool) {
        self.id = id
        self.title = title
        self.isChecked = isChecked
    }
}

struct StudioTask: Identifiable, Equatable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id, title, status, pill, rightText, sourceURL, localPath, exePath, appID
        case isArchived, expanded, checklist
    }

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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
    let id: UUID
    var title: String
    var status: TaskStatus
    var pill: String?
    var rightText: String
    var sourceURL: String?
    var localPath: String?
    var exePath: String?
    var appID: String?
    var isArchived: Bool = false
    var expanded: Bool = false
    var checklist: [CheckItem] = []

    init(
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

struct PersistedTaskSnapshot: Codable, Sendable {
    private enum CodingKeys: String, CodingKey { case downloadTasks, unpackTasks, patchTasks }

    var downloadTasks: [StudioTask]
    var unpackTasks: [StudioTask]
    var patchTasks: [StudioTask]

    init(downloadTasks: [StudioTask], unpackTasks: [StudioTask], patchTasks: [StudioTask]) {
        self.downloadTasks = downloadTasks
        self.unpackTasks = unpackTasks
        self.patchTasks = patchTasks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downloadTasks = try container.decodeIfPresent([StudioTask].self, forKey: .downloadTasks) ?? []
        unpackTasks = try container.decodeIfPresent([StudioTask].self, forKey: .unpackTasks) ?? []
        patchTasks = try container.decodeIfPresent([StudioTask].self, forKey: .patchTasks) ?? []
    }
}

struct LogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let time: String
    let message: String
    let highlight: Bool

    init(id: UUID = UUID(), time: String, message: String, highlight: Bool) {
        self.id = id
        self.time = time
        self.message = message
        self.highlight = highlight
    }
}
