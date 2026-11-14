import Foundation
import Testing
import ChrysaCore

struct CoreModelTests {
    @Test
    func testSettingsDecodeUsesDefaultsForMissingFields() throws {
        let data = Data(#"{"autoRelay":false,"download":{"maxConcurrentConnections":8}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(!settings.autoRelay)
        #expect(settings.maxConcurrentConnections == 8)
        #expect(settings.downloadDirectory == AppSettings.default.downloadDirectory)
        #expect(settings.passwords == AppSettings.default.passwords)
        #expect(settings.accentColorMode == .monochrome)
    }

    @Test
    func testAccentColorModeDefaultsToMonochromeAndRoundTrips() throws {
        var settings = AppSettings.default
        #expect(settings.accentColorMode == .monochrome)
        #expect(settings.appearance.accentColorMode == .monochrome)

        settings.selectedIconID = "w6_burgundy"
        settings.accentColorMode = .followAppIcon

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        #expect(decoded.selectedIconID == "w6_burgundy")
        #expect(decoded.accentColorMode == .followAppIcon)
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
            output: ArtifactRef(kind: .file, value: "/games/Game/Game.exe"),
            pill: "已就绪",
            appID: "480", isArchived: true, expanded: true,
            checklist: [CheckItem(title: "Configured", isChecked: true)], listPosition: 5
        )
        let restored = try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job))
        #expect(restored == job)
        #expect(restored.pill == "已就绪" && restored.message == "已就绪")
        #expect(restored.legacyTask().pill == "已就绪")
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
        _ = try JSONEncoder().encode(changed)
    }

    @Test
    func testLaunchGameDeduplicationSortingAndDisplayText() throws {
        let now = Date()
        let scanned = LaunchGame(
            title: "Patrick‘s Parabox",
            exePath: "/Games/Parabox/Parabox.exe",
            gameDirectory: "/Games/Parabox",
            bottleName: "Patrick's Parabox",
            source: .crossoverScan,
            addedAt: now.addingTimeInterval(-3600)
        )
        let patched = LaunchGame(
            title: "Patrick's Parabox",
            exePath: "/Games/Parabox/Parabox.exe",
            gameDirectory: "/Games/Parabox",
            appID: "1260520",
            source: .patchPipeline,
            addedAt: now,
            lastPlayedAt: now.addingTimeInterval(-120)
        )
        let otherGame = LaunchGame(
            title: "Animal Well",
            exePath: "/Games/Animal Well/AnimalWell.exe",
            gameDirectory: "/Games/Animal Well",
            source: .manualImport,
            addedAt: now.addingTimeInterval(-7200),
            lastPlayedAt: nil
        )

        let deduped = LaunchGame.deduplicate([scanned, patched, otherGame])
        #expect(deduped.count == 2)
        let mergedParabox = try #require(deduped.first(where: { $0.appID == "1260520" }))
        #expect(mergedParabox.source == .patchPipeline)
        #expect(mergedParabox.bottleName == "Patrick's Parabox")
        #expect(mergedParabox.lastPlayedAt == patched.lastPlayedAt)

        let byPlayed = LaunchGame.sorted(deduped, by: .lastPlayed)
        #expect(byPlayed.map(\.title) == ["Patrick's Parabox", "Animal Well"])

        let byName = LaunchGame.sorted(deduped, by: .name)
        #expect(byName.map(\.title) == ["Animal Well", "Patrick's Parabox"])

        #expect(otherGame.lastPlayedDisplayText(relativeTo: now) == "未游玩")
        #expect(mergedParabox.lastPlayedDisplayText(relativeTo: now) == "2 分钟前")

        let encoded = try JSONEncoder().encode(mergedParabox)
        let decoded = try JSONDecoder().decode(LaunchGame.self, from: encoded)
        #expect(decoded == mergedParabox)
    }

    @Test
    func testLaunchGameIconPreferenceRoundTripAndMergePreservation() throws {
        let custom = LaunchGame(
            title: "Hollow Knight",
            exePath: "/Games/Hollow Knight/hollow_knight.exe",
            gameDirectory: "/Games/Hollow Knight",
            appID: "367520",
            source: .manualImport,
            customIconPath: "/tmp/custom-hk.png",
            iconPreference: .steam
        )
        let encoded = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(LaunchGame.self, from: encoded)
        #expect(decoded.iconPreference == .steam)
        #expect(decoded.customIconPath == "/tmp/custom-hk.png")

        let rescanIncoming = LaunchGame(
            title: "Hollow Knight",
            bottleName: "Hollow Knight",
            source: .crossoverScan
        )
        let merged = decoded.merged(with: rescanIncoming, preferIncomingMetadata: false)
        #expect(merged.iconPreference == .steam)
        #expect(merged.customIconPath == "/tmp/custom-hk.png")
        #expect(merged.bottleName == "Hollow Knight")
    }

    @Test
    func testDownloadSettingsMaxConcurrentDownloadsDefaultsAndClamps() throws {
        let legacyData = Data(#"{"download":{"downloadDirectory":"/tmp/dl","maxConcurrentConnections":8}}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)
        #expect(decoded.maxConcurrentConnections == 8)
        #expect(decoded.maxConcurrentDownloads == 2)

        let overData = Data(#"{"download":{"maxConcurrentDownloads":99}}"#.utf8)
        let clampedHigh = try JSONDecoder().decode(AppSettings.self, from: overData)
        #expect(clampedHigh.maxConcurrentDownloads == 4)

        var s = AppSettings.default
        s.maxConcurrentDownloads = 0
        #expect(s.maxConcurrentDownloads == 1)
        s.maxConcurrentDownloads = 3
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(roundTrip.maxConcurrentDownloads == 3)
    }

    @Test
    func testJobPausedStatusAndDownloadPartsBackwardCompatibility() throws {
        let part = DownloadPart(
            filename: "Game.part1.rar",
            originalURL: "https://fuckingfast.co/abc#Game.part1.rar",
            resolvedURL: "https://fuckingfast.co/dl/xyz",
            status: .paused,
            progress: 0.45,
            downloadedBytes: 450,
            totalBytes: 1000,
            message: "已暂停"
        )
        let job = Job(
            kind: .download,
            title: "Game",
            status: .paused,
            progress: 0.45,
            passwordHint: "cs.rin.ru",
            downloadParts: [part]
        )
        let restored = try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job))
        #expect(restored.status == .paused)
        #expect(restored.passwordHint == "cs.rin.ru")
        #expect(restored.downloadParts == [part])
        if case .paused(let pct) = restored.taskStatus {
            #expect(abs(pct - 0.45) < 0.001)
        } else {
            Issue.record("Expected paused taskStatus")
        }
    }

    @Test
    func testDownloadInputParserExtractsURLsPasswordsAndGroupsMultipart() {
        let text = """
        [Release] Cool Game v1.2
        解压密码：my_custom_pw!
        Part 1: https://fuckingfast.co/aaa#Cool_Game_v1.2.part01.rar
        Part 2: fuckingfast.co/bbb#Cool_Game_v1.2.part02.rar
        Magnet ignored: magnet:?xt=urn:btih:123456
        Torrent ignored: https://example.com/file.torrent
        Another: https://pixeldrain.com/u/other123
        """
        let parsed = DownloadInputParser.parse(text)
        #expect(parsed.primaryPassword == "my_custom_pw!")
        #expect(parsed.urls == [
            "https://fuckingfast.co/aaa#Cool_Game_v1.2.part01.rar",
            "https://fuckingfast.co/bbb#Cool_Game_v1.2.part02.rar",
            "https://pixeldrain.com/u/other123"
        ])

        let groups = DownloadInputParser.groupMultipartItems([
            MultipartGroupItem(url: "https://a/1", filename: "Cool_Game_v1.2.part01.rar"),
            MultipartGroupItem(url: "https://a/2", filename: "Cool_Game_v1.2.part02.rar"),
            MultipartGroupItem(url: "https://b/1", filename: "OtherGame.7z")
        ])
        #expect(groups.count == 2)
        #expect(groups[0].isMultipartSet)
        #expect(groups[0].items.count == 2)
        #expect(groups[0].title == "Cool Game")
        #expect(!groups[1].isMultipartSet)
        #expect(groups[1].items.count == 1)
    }

    @Test
    func testProxyPolicyAccelerationCredentialsAndSecretRedaction() throws {
        let legacyData = Data(#"{"download":{"downloadDirectory":"/tmp/dl"}}"#.utf8)
        let legacyDecoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)
        #expect(legacyDecoded.proxyPolicy == .smart)
        #expect(legacyDecoded.pixeldrainAPIKey == "")
        #expect(legacyDecoded.realDebridToken == "")
        #expect(legacyDecoded.torBoxToken == "")

        var settings = AppSettings.default
        settings.proxyPolicy = .directOnly
        settings.pixeldrainAPIKey = "pd-secret-123"
        settings.realDebridToken = "rd-token-456"
        settings.torBoxToken = "tb-key-789"
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip.proxyPolicy == .directOnly)
        #expect(roundTrip.pixeldrainAPIKey == "pd-secret-123")
        #expect(roundTrip.realDebridToken == "rd-token-456")
        #expect(roundTrip.torBoxToken == "tb-key-789")
        #expect(roundTrip.download.redactedSecrets.contains("pd-secret-123"))
        #expect(roundTrip.download.redactedSecrets.contains("rd-token-456"))
        #expect(roundTrip.download.redactedSecrets.contains("tb-key-789"))

        let sanitized = try #require(
            LogEntry.sanitizeRawOutput(
                "Authorization: Bearer rd-token-456 / key=pd-secret-123",
                redact: roundTrip.download.redactedSecrets
            )
        )
        #expect(!sanitized.contains("rd-token-456"))
        #expect(!sanitized.contains("pd-secret-123"))
    }

    @Test
    func testJobAndDownloadPartMirrorURLsAndNewHostPipeParsing() throws {
        // Legacy DownloadPart & Job JSON without mirrorURLs field decodes with []
        let legacyJobJSON = Data(#"{"id":"11111111-1111-1111-1111-111111111111","kind":"download","title":"Game","status":"paused","progress":0.5,"mirrorURLs":null}"#.utf8)
        // Missing mirrorURLs key case:
        let noMirrorJobJSON = Data(#"{"id":"11111111-1111-1111-1111-111111111111","kind":"download","title":"Game","status":"paused","progress":0.5}"#.utf8)
        let decodedNoMirror = try JSONDecoder().decode(Job.self, from: noMirrorJobJSON)
        #expect(decodedNoMirror.mirrorURLs.isEmpty)
        _ = try? JSONDecoder().decode(Job.self, from: legacyJobJSON)

        let part = DownloadPart(
            filename: "Game.part1.rar",
            originalURL: "https://datanodes.to/abc/Game.part1.rar",
            resolvedURL: "https://cdn.datanodes.to/dl/1",
            mirrorURLs: ["https://qiwi.gg/file/m1"]
        )
        let job = Job(
            kind: .download,
            title: "Game",
            status: .running,
            downloadParts: [part],
            mirrorURLs: ["https://workupload.com/file/m2"]
        )
        let roundTrip = try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job))
        #expect(roundTrip.mirrorURLs == ["https://workupload.com/file/m2"])
        #expect(roundTrip.downloadParts?.first?.mirrorURLs == ["https://qiwi.gg/file/m1"])

        let input = """
        https://datanodes.to/aaa111/Game.7z | qiwi.gg/file/bbb222 | https://workupload.com/file/ccc333
        krakenfiles.com/view/ddd444/file.html
        """
        let parsed = DownloadInputParser.parse(input)
        #expect(parsed.urls == [
            "https://datanodes.to/aaa111/Game.7z",
            "https://krakenfiles.com/view/ddd444/file.html"
        ])
        #expect(parsed.mirrorGroups["https://datanodes.to/aaa111/Game.7z"] == [
            "https://qiwi.gg/file/bbb222",
            "https://workupload.com/file/ccc333"
        ])
    }
}
