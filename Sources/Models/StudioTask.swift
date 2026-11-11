import Foundation

enum TaskStatus: Equatable, Codable, Sendable {
    case queued
    case running(Double)
    case locked(Double)
    case done
    case failed
}

struct CheckItem: Identifiable, Equatable, Codable, Sendable {
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
    var downloadTasks: [StudioTask]
    var unpackTasks: [StudioTask]
    var patchTasks: [StudioTask]
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
