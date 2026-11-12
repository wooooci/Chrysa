import Foundation
import Testing
import ChrysaCore

struct CoreModelTests {
    @Test
    func testSettingsDecodeUsesDefaultsForMissingFields() throws {
        let data = Data(#"{"autoRelay":false}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(!settings.autoRelay)
        #expect(settings.maxConcurrentConnections == AppSettings.default.maxConcurrentConnections)
        #expect(settings.downloadDirectory == AppSettings.default.downloadDirectory)
        #expect(settings.passwords == AppSettings.default.passwords)
    }

    @Test
    func testTaskDecodeUsesDefaultsForMissingFields() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id.uuidString)\"}".utf8)
        let task = try JSONDecoder().decode(StudioTask.self, from: data)

        #expect(task.id == id)
        #expect(task.status == .failed)
        #expect(task.rightText == "")
        #expect(!task.isArchived)
        #expect(task.checklist.isEmpty)
    }

    @Test
    func testLegacyStoppedTaskMapsToCancelledJob() {
        let task = StudioTask(title: "stopped.7z", status: .failed, pill: "已停止")
        let job = Job.fromLegacy(task, kind: .download)

        #expect(job.status == .cancelled)
    }

    @Test
    func testJobRoundTripPreservesIdentityArtifactsAndPresentationState() throws {
        let job = Job(
            kind: .patch, title: "Game", status: .succeeded, progress: 1,
            source: ArtifactRef(kind: .directory, value: "/games/Game"),
            output: ArtifactRef(kind: .file, value: "/games/Game/Game.exe"),
            appID: "480", isArchived: true, expanded: true,
            checklist: [CheckItem(title: "Configured", isChecked: true)], listPosition: 5
        )
        let restored = try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job))
        #expect(restored == job)
        #expect(restored.legacyTask().id == job.id)
    }

    @Test
    func testJobDecodeDefaultsAndClampsProgress() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id)\",\"kind\":\"download\",\"title\":\"game.7z\",\"progress\":2}".utf8)
        let job = try JSONDecoder().decode(Job.self, from: data)
        #expect(job.id == id)
        #expect(job.status == .queued)
        #expect(job.progress == 1)
        #expect(job.updatedAt == job.createdAt)
        #expect(Job(kind: .download, title: "invalid", progress: .nan).progress == 0)
        var changed = job
        changed.progress = .nan
        #expect(changed.progress == 0)
        changed.progress = .infinity
        #expect(changed.progress == 1)
        changed.progress = -.infinity
        #expect(changed.progress == 0)
        _ = try JSONEncoder().encode(changed)
    }
}
