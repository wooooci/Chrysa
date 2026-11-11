import Foundation

struct StageID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

struct StageContext: Sendable {
    let jobID: UUID
    let input: ArtifactRef?
    let metadata: [String: String]

    init(jobID: UUID, input: ArtifactRef? = nil, metadata: [String: String] = [:]) {
        self.jobID = jobID
        self.input = input
        self.metadata = metadata
    }
}

struct StageOutput: Sendable, Equatable {
    let artifact: ArtifactRef?
    let metadata: [String: String]

    init(artifact: ArtifactRef? = nil, metadata: [String: String] = [:]) {
        self.artifact = artifact
        self.metadata = metadata
    }
}

enum StageError: LocalizedError, Equatable, Sendable {
    case missingInput(stage: StageID)
    case unavailable(stage: StageID)

    var errorDescription: String? {
        switch self {
        case .missingInput(let stage): return "Stage \(stage) requires an input artifact"
        case .unavailable(let stage): return "Stage \(stage) is not registered"
        }
    }
}

/// A unit of work that can be executed without knowing anything about SwiftUI.
protocol Stage: Sendable {
    var id: StageID { get }
    func execute(context: StageContext) async throws -> StageOutput
}

/// Compile-time registration point for the stages supported by the application.
struct StageRegistry {
    private var stages: [StageID: any Stage] = [:]

    init(stages: [any Stage] = []) {
        for stage in stages {
            self.stages[stage.id] = stage
        }
    }

    mutating func register(_ stage: any Stage) {
        stages[stage.id] = stage
    }

    func stage(for id: StageID) -> (any Stage)? {
        stages[id]
    }

    var registeredIDs: [StageID] {
        stages.keys.sorted { $0.rawValue < $1.rawValue }
    }
}
