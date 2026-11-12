import Foundation
import Testing
import ChrysaCore
import ChrysaApplication

struct StageRegistryTests {
    @Test
    func testStageRegistryRegistersAndExecutesStage() async throws {
        var registry = StageRegistry()
        let stage = EchoStage()
        registry.register(stage)

        #expect(registry.registeredIDs == [stage.id])
        let result = await registry.execute(
            stage.id, context: StageContext(jobID: UUID(), input: ArtifactRef(kind: .file, value: "/tmp/input"))
        )
        guard case .success(let output) = result else {
            Issue.record("Stage did not return success")
            return
        }
        #expect(output.artifact == ArtifactRef(kind: .file, value: "/tmp/input"))
    }

    @Test
    func testRegistryReportsUnavailableAndCancellationWithoutRunningStage() async {
        let stage = EchoStage()
        let registry = StageRegistry(stages: [stage])
        let missingID = StageID("missing")
        let missing = await registry.execute(missingID, context: StageContext(jobID: UUID()))
        #expect(missing == .failure(StageFailure(stage: missingID, message: StageError.unavailable(stage: missingID).localizedDescription)))
        let stopped = await registry.execute(stage.id, context: StageContext(jobID: UUID(), isCancelled: { true }))
        #expect(stopped == .cancelled)
        #expect(StageProgress(fraction: .nan).fraction == 0)
        #expect(StageProgress(fraction: nil).fraction == nil)
    }
}

private struct EchoStage: Stage {
    let id = StageID("test.echo")

    func execute(context: StageContext) async -> StageResult {
        .success(StageOutput(artifact: context.input))
    }
}
