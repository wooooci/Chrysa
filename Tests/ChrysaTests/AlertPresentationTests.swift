import AppKit
import SwiftUI
import Testing
import ChrysaCore
import ChrysaApplication
import ChrysaAdapters
@testable import ChrysaPresentation

struct AlertPresentationTests {
    @MainActor
    @Test
    func optionalBindingIsPresentClearsValueOnDismiss() {
        var value: String? = nil
        let optionalBinding = Binding<String?>(
            get: { value },
            set: { value = $0 }
        )
        let flag = optionalBinding.isPresent()

        #expect(!flag.wrappedValue)

        value = "pending"
        #expect(flag.wrappedValue)

        flag.wrappedValue = true
        #expect(value == "pending")

        flag.wrappedValue = false
        #expect(value == nil)
        #expect(!flag.wrappedValue)
    }

    @MainActor
    @Test
    func mainViewLaunchErrorAlertPresentsAndDismisses() async {
        _ = NSApplication.shared

        let vm = makeViewModel()
        let window = makeHostWindow(rootView: ThingsStudioMainView(vm: vm, isSnapshotMode: false))
        defer { cleanup(window: window) }

        let rendered = await pumpMainRunLoop(until: { window.contentView?.fittingSize != .zero }, timeout: 1.0)
        #expect(rendered)

        vm.launchErrorAlert = StudioViewModel.LaunchErrorNotice(
            title: "Pentiment",
            message: "无法定位可执行文件"
        )

        let presented = await pumpMainRunLoop(until: { window.attachedSheet != nil }, timeout: 2.0)
        #expect(presented)

        if let sheetContent = window.attachedSheet?.contentView {
            let texts = collectTextValues(in: sheetContent)
            #expect(texts.contains("无法启动「Pentiment」"))
            #expect(texts.contains("无法定位可执行文件"))

            let okButton = collectButtons(in: sheetContent).first { $0.title == "好" }
            #expect(okButton != nil)
            okButton?.performClick(nil)
        }

        let dismissed = await pumpMainRunLoop(
            until: { window.attachedSheet == nil && vm.launchErrorAlert == nil },
            timeout: 2.0
        )
        #expect(dismissed)
    }

    @MainActor
    @Test
    func taskListDeletionAlertCoexistsWithAncestorAlertAndDeletesJobAndLocalFile() async throws {
        try await runDeletionAlertScenario(
            filename: "sample.zip",
            deleteLocalFile: true,
            expectedTitle: "删除记录及本地文件？",
            actionButtonTitle: "删除",
            expectedJobCount: 0,
            expectedFileExists: false
        )
    }

    @MainActor
    @Test
    func taskListDeletionAlertCancelPreservesJobAndLocalFile() async throws {
        try await runDeletionAlertScenario(
            filename: "keep.zip",
            deleteLocalFile: false,
            expectedTitle: "删除记录？",
            actionButtonTitle: "取消",
            expectedJobCount: 1,
            expectedFileExists: true
        )
    }

    @MainActor
    @Test
    func launchLibraryRemovalAlertPresentsRecordOnlyAndTrashActions() async throws {
        _ = NSApplication.shared

        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("chrysa-launch-alert-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let gameFolder = tempRoot.appendingPathComponent("UninstallableGame", isDirectory: true)
        try fm.createDirectory(at: gameFolder, withIntermediateDirectories: true)
        let exeFile = gameFolder.appendingPathComponent("Game.exe")
        try Data("PE".utf8).write(to: exeFile)

        let game = LaunchGame(
            title: "UninstallableGame",
            exePath: exeFile.path,
            gameDirectory: gameFolder.path,
            source: .manualImport
        )

        // 1. "仅移除记录" removes library entry and keeps local directory intact
        let library1 = LaunchGameStore(inMemoryOnly: true)
        await library1.upsert(game, preferIncomingMetadata: true)
        let settings1 = AppSettingsStore(inMemoryOnly: true)
        settings1.settings.bottlesDirectory = tempRoot.appendingPathComponent("Bottles").path
        let vm1 = StudioViewModel(
            inMemoryOnly: false,
            settingsStore: settings1,
            taskStore: TaskStore(inMemoryOnly: true),
            coordinator: PipelineCoordinator(
                services: DefaultWorkflowServices(),
                jobStore: JobStore(inMemoryOnly: true),
                gameLibrary: library1
            )
        )
        let loaded1 = await pumpMainRunLoop(until: { !vm1.launchGames.isEmpty }, timeout: 2.0)
        #expect(loaded1)

        let window1 = makeHostWindow(
            rootView: LaunchLibraryView(
                vm: vm1,
                isSnapshotMode: false,
                initialPendingRemoval: game
            )
            .frame(width: 640, height: 420)
            .launchErrorAlert(Binding(get: { vm1.launchErrorAlert }, set: { vm1.launchErrorAlert = $0 }))
        )
        defer { cleanup(window: window1) }

        let presented1 = await pumpMainRunLoop(until: { window1.attachedSheet != nil }, timeout: 2.0)
        #expect(presented1)
        if let sheetContent = window1.attachedSheet?.contentView {
            let titles = collectButtons(in: sheetContent).map(\.title)
            #expect(titles.contains("仅移除记录"))
            #expect(titles.contains("彻底卸载（移入废纸篓）"))
            #expect(titles.contains("取消"))
            collectButtons(in: sheetContent).first { $0.title == "仅移除记录" }?.performClick(nil)
        }
        let settled1 = await pumpMainRunLoop(
            until: { window1.attachedSheet == nil && vm1.launchGames.isEmpty },
            timeout: 2.0
        )
        #expect(settled1)
        #expect(fm.fileExists(atPath: gameFolder.path))

        // 2. "彻底卸载（移入废纸篓）" removes library entry and trashes local directory
        let library2 = LaunchGameStore(inMemoryOnly: true)
        await library2.upsert(game, preferIncomingMetadata: true)
        let vm2 = StudioViewModel(
            inMemoryOnly: false,
            settingsStore: settings1,
            taskStore: TaskStore(inMemoryOnly: true),
            coordinator: PipelineCoordinator(
                services: DefaultWorkflowServices(),
                jobStore: JobStore(inMemoryOnly: true),
                gameLibrary: library2
            )
        )
        let loaded2 = await pumpMainRunLoop(until: { !vm2.launchGames.isEmpty }, timeout: 2.0)
        #expect(loaded2)

        let trashDir = fm.urls(for: .trashDirectory, in: .userDomainMask).first
        let existingTrashItems = Set((trashDir.flatMap { try? fm.contentsOfDirectory(atPath: $0.path) }) ?? [])
        defer {
            if let trashDir, let currentItems = try? fm.contentsOfDirectory(atPath: trashDir.path) {
                for name in currentItems where !existingTrashItems.contains(name) && name.contains("UninstallableGame") {
                    try? fm.removeItem(at: trashDir.appendingPathComponent(name))
                }
            }
        }

        let window2 = makeHostWindow(
            rootView: LaunchLibraryView(
                vm: vm2,
                isSnapshotMode: false,
                initialPendingRemoval: game
            )
            .frame(width: 640, height: 420)
            .launchErrorAlert(Binding(get: { vm2.launchErrorAlert }, set: { vm2.launchErrorAlert = $0 }))
        )
        defer { cleanup(window: window2) }

        let presented2 = await pumpMainRunLoop(until: { window2.attachedSheet != nil }, timeout: 2.0)
        #expect(presented2)
        collectButtons(in: window2.attachedSheet!.contentView!).first { $0.title == "彻底卸载（移入废纸篓）" }?.performClick(nil)

        let settled2 = await pumpMainRunLoop(
            until: {
                window2.attachedSheet == nil
                    && vm2.launchGames.isEmpty
                    && !fm.fileExists(atPath: gameFolder.path)
            },
            timeout: 2.0
        )
        #expect(settled2)
    }

    @MainActor
    private func runDeletionAlertScenario(
        filename: String,
        deleteLocalFile: Bool,
        expectedTitle: String,
        actionButtonTitle: String,
        expectedJobCount: Int,
        expectedFileExists: Bool
    ) async throws {
        _ = NSApplication.shared

        let fm = FileManager.default
        let downloadDir = fm.temporaryDirectory
            .appendingPathComponent("chrysa-alert-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: downloadDir) }

        let archiveFile = downloadDir.appendingPathComponent(filename)
        try Data("payload".utf8).write(to: archiveFile)

        let (vm, task) = await makeViewModelWithDownloadTask(
            downloadDirectory: downloadDir.path,
            localPath: archiveFile.path
        )

        let rootView = TaskListSectionView(
            vm: vm,
            isSnapshotMode: false,
            initialPendingDeletion: TaskListSectionView.PendingDeletion(
                task: task,
                deleteLocalFile: deleteLocalFile
            )
        )
        .frame(width: 640, height: 420)
        .launchErrorAlert(
            Binding(
                get: { vm.launchErrorAlert },
                set: { vm.launchErrorAlert = $0 }
            )
        )

        let window = makeHostWindow(rootView: rootView)
        defer { cleanup(window: window) }

        let presented = await pumpMainRunLoop(until: { window.attachedSheet != nil }, timeout: 2.0)
        #expect(presented)

        if let sheetContent = window.attachedSheet?.contentView {
            let texts = collectTextValues(in: sheetContent)
            #expect(texts.contains(expectedTitle))

            let button = collectButtons(in: sheetContent).first { $0.title == actionButtonTitle }
            #expect(button != nil)
            button?.performClick(nil)
        }

        let settled = await pumpMainRunLoop(
            until: {
                window.attachedSheet == nil
                    && vm.jobs.count == expectedJobCount
                    && fm.fileExists(atPath: archiveFile.path) == expectedFileExists
            },
            timeout: 2.0
        )
        #expect(settled)
    }

    @MainActor
    private func makeViewModel(downloadDirectory: String? = nil) -> StudioViewModel {
        let settingsStore = AppSettingsStore(inMemoryOnly: true)
        if let downloadDirectory {
            settingsStore.settings.downloadDirectory = downloadDirectory
        }
        settingsStore.settings.bottlesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrysa-alert-bottles-\(UUID().uuidString)")
            .path
        return StudioViewModel(
            inMemoryOnly: true,
            settingsStore: settingsStore,
            taskStore: TaskStore(inMemoryOnly: true),
            coordinator: PipelineCoordinator(
                services: DefaultWorkflowServices(),
                jobStore: JobStore(inMemoryOnly: true)
            )
        )
    }

    @MainActor
    private func makeViewModelWithDownloadTask(
        downloadDirectory: String,
        localPath: String
    ) async -> (StudioViewModel, StudioTask) {
        let jobStore = JobStore(inMemoryOnly: true)
        let job = Job(
            kind: .download,
            title: URL(fileURLWithPath: localPath).lastPathComponent,
            status: .failed,
            source: ArtifactRef(kind: .remoteURL, value: "https://example.invalid/\(URL(fileURLWithPath: localPath).lastPathComponent)"),
            output: ArtifactRef(kind: .file, value: localPath)
        )
        await jobStore.upsert(job)

        let settingsStore = AppSettingsStore(inMemoryOnly: true)
        settingsStore.settings.downloadDirectory = downloadDirectory
        settingsStore.settings.bottlesDirectory = (downloadDirectory as NSString).appendingPathComponent("_bottles")
        let vm = StudioViewModel(
            inMemoryOnly: false,
            settingsStore: settingsStore,
            taskStore: TaskStore(inMemoryOnly: true),
            coordinator: PipelineCoordinator(services: DefaultWorkflowServices(), jobStore: jobStore)
        )

        let restored = await pumpMainRunLoop(until: { !vm.tasks(for: .download).isEmpty }, timeout: 2.0)
        #expect(restored)
        return (vm, vm.tasks(for: .download)[0])
    }

    @MainActor
    private func makeHostWindow<Content: View>(rootView: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 860, height: 580),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: rootView)
        window.orderFront(nil)
        return window
    }

    @MainActor
    private func cleanup(window: NSWindow) {
        if let sheet = window.attachedSheet {
            window.endSheet(sheet)
        }
        window.orderOut(nil)
    }

    @MainActor
    private func pumpMainRunLoop(until condition: () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @MainActor
    private func collectButtons(in view: NSView) -> [NSButton] {
        var result: [NSButton] = []
        if let button = view as? NSButton {
            result.append(button)
        }
        for subview in view.subviews {
            result.append(contentsOf: collectButtons(in: subview))
        }
        return result
    }

    @MainActor
    private func collectTextValues(in view: NSView) -> [String] {
        var result: [String] = []
        if let field = view as? NSTextField, !field.stringValue.isEmpty {
            result.append(field.stringValue)
        }
        for subview in view.subviews {
            result.append(contentsOf: collectTextValues(in: subview))
        }
        return result
    }
}
