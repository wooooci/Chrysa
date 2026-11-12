import ChrysaCore
import ChrysaApplication
import ChrysaAdapters
import ChrysaPresentation
import SwiftUI
import AppKit

// MARK: - App Delegate & Lifecycle Cleanup
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var vm: StudioViewModel!

    @MainActor
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // 1. App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Chrysa", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏 Chrysa", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 Chrysa", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // 2. Edit Menu (Cmd+V, Cmd+C, Cmd+X, Cmd+A, Cmd+Z)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "删除", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        // 3. Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        vm = AppComposition.makeViewModel(seedDemoData: false)
        let contentView = ThingsStudioMainView(vm: vm, isSnapshotMode: false)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "v" {
                if let responder = self.window?.firstResponder, responder is NSText {
                    return event
                }
                if self.vm.activeTab == .download, self.vm.editingTask == nil {
                    self.vm.pasteFromClipboardToInput()
                    return nil
                }
            }
            return event
        }

        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--install"), args.count > idx + 1 {
            let targetURL = args[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.vm.startDownload(urlString: targetURL)
            }
        } else if let idx = args.firstIndex(of: "--unpack"), args.count > idx + 1 {
            let targetFile = args[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                self.vm.activeTab = .unpack
                self.vm.startUnpack(filePath: targetFile)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let vmRef = self.vm
        Task { @MainActor in
            await ProcessSupervisor.shared.terminateAll()
            await vmRef?.flushTasksImmediately()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ChrysaAppMain {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--self-test") {
            await runArchitectureSelfTest()
            return
        }

        if CommandLine.arguments.contains("--render-snapshots") {
            let outDir = "/Users/woooci/.gemini/antigravity/brain/1469f655-160e-4a84-9da9-fa0217bac001"
            let presets: [(StudioTab, SettingsCategory, String)] = [
                (.download, .appearance, "dl"),
                (.unpack, .appearance, "un"),
                (.patch, .appearance, "pa"),
                (.settings, .appearance, "settings_appearance"),
                (.settings, .download, "settings_download"),
                (.settings, .unpack, "settings_unpack"),
                (.settings, .patch, "settings_patch")
            ]
            for (tab, cat, suffix) in presets {
                let vm = AppComposition.makeViewModel(seedDemoData: true)
                vm.activeTab = tab
                vm.settingsCategory = cat
                let framed = ThingsStudioMainView(vm: vm, isSnapshotMode: true)
                    .frame(width: 860, height: 580)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.black.opacity(0.12), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.14), radius: 24, x: 0, y: 12)
                    .padding(22)
                    .background(Color(red: 0.918, green: 0.925, blue: 0.937))

                let renderer = ImageRenderer(content: framed)
                renderer.scale = 2.0
                if let cgImage = renderer.cgImage {
                    let rep = NSBitmapImageRep(cgImage: cgImage)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        let path = "\(outDir)/chrysa_ready_\(suffix).png"
                        try? data.write(to: URL(fileURLWithPath: path))
                        print("Rendered ready snapshot: \(path)")
                    }
                }
            }
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    @MainActor
    static func runArchitectureSelfTest() async {
        print("=== [Chrysa Decoupled Architecture Self-Test] ===")

        // 1. ToolchainLocator & Proxy Routing
        let proxy = ToolchainLocator.detectSystemProxy()
        let gofileProxy = ToolchainLocator.hostNeedsProxy("https://store4.gofile.io/download/web/xxx/game.7z")
        let vfProxy = ToolchainLocator.hostNeedsProxy("https://bi.vikingfile.com/download/xxx/SAN.7z")
        let dlBin = ToolchainLocator.locateDownloadEngineBinary() ?? "missing"
        let gbe64 = ToolchainLocator.locateGbeDLL(is64Bit: true) != nil
        print("1. Infrastructure -> proxy=\(proxy ?? "none"), gofileProxy=\(gofileProxy), vfProxy=\(vfProxy), dlEngine=\((dlBin as NSString).lastPathComponent), gbe64Found=\(gbe64)")
        precondition(gofileProxy == true && vfProxy == false)

        // 2. AppSettingsStore & TaskStore Round-Trip + Interrupted Task Normalization
        let tmpDir = URL(fileURLWithPath: "/tmp/chrysa_selftest_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let settingsFile = tmpDir.appendingPathComponent("settings.json")
        let s1 = AppSettingsStore(inMemoryOnly: false, customFileURL: settingsFile)
        s1.settings.maxConcurrentConnections = 8
        s1.settings.defaultLanguage = .tchinese
        s1.settings.deleteArchiveAfterUnpack = true
        let s2 = AppSettingsStore(inMemoryOnly: false, customFileURL: settingsFile)
        precondition(s2.settings.maxConcurrentConnections == 8 && s2.settings.defaultLanguage == .tchinese && s2.settings.deleteArchiveAfterUnpack == true)

        let tasksFile = tmpDir.appendingPathComponent("tasks.json")
        let ts = TaskStore(inMemoryOnly: false, customFileURL: tasksFile)
        await ts.save(
            PersistedTaskSnapshot(
                downloadTasks: [StudioTask(title: "InFlight.7z", status: .running(0.42), pill: "12 MB/s", rightText: "1/2 GB")],
                unpackTasks: [],
                patchTasks: [StudioTask(title: "SavedGame", status: .done, pill: "Goldberg x64", rightText: "▶ 启动")]
            )
        )
        let loaded = await ts.load()
        precondition(loaded.downloadTasks.first?.status == .failed && loaded.downloadTasks.first?.pill == "已中断")
        precondition(loaded.patchTasks.first?.title == "SavedGame")
        print("2. Persistence -> AppSettingsStore & TaskStore round-trip OK, interrupted task normalized to '\(loaded.downloadTasks.first?.pill ?? "")'")

        let migratedDownload = Job.fromLegacy(loaded.downloadTasks[0], kind: .download)
        precondition(migratedDownload.status == .failed)
        let jobStore = JobStore(inMemoryOnly: true)
        let liveJob = Job(kind: .download, title: "JobStoreCheck.7z", status: .running, progress: 0.4)
        await jobStore.upsert(liveJob)
        await jobStore.update(id: liveJob.id, status: .succeeded, progress: 1)
        await jobStore.update(id: liveJob.id, status: .running, progress: 0.2)
        let savedJob = await jobStore.job(for: liveJob.id)
        precondition(savedJob?.status == .succeeded && savedJob?.progress == 1)

        let cancelledJob = Job(kind: .unpack, title: "CancelledCheck.7z", status: .running, progress: 0.6)
        await jobStore.upsert(cancelledJob)
        await jobStore.update(id: cancelledJob.id, status: .cancelled, message: "已停止")
        await jobStore.update(id: cancelledJob.id, status: .running, progress: 0.9, message: "迟到进度")
        let savedCancelledJob = await jobStore.job(for: cancelledJob.id)
        precondition(savedCancelledJob?.status == .cancelled && savedCancelledJob?.progress == 0.6 && savedCancelledJob?.message == "已停止")

        var stageRegistry = StageRegistry()
        let passthroughStage = SelfTestPassthroughStage()
        stageRegistry.register(passthroughStage)
        let stageInput = ArtifactRef(kind: .file, value: "/tmp/stage-input")
        guard let registeredStage = stageRegistry.stage(for: passthroughStage.id) else {
            preconditionFailure("Stage registry failed to retain a registered stage")
        }
        let stageResult = await registeredStage.execute(
            context: StageContext(jobID: UUID(), input: stageInput)
        )
        guard case .success(let stageOutput) = stageResult else {
            preconditionFailure("Stage registry returned an unexpected result")
        }
        precondition(stageOutput.artifact == stageInput)
        print("2B. Job/Stage Core -> legacy migration, terminal-state guard, and registry execution OK")

        do {
            try await JobPersistenceChecks.run()
            print("2C. Job Persistence -> migration, restart, backup recovery, schema protection, and display synchronization OK")
        } catch {
            FileHandle.standardError.write(Data("Job persistence check failed: \(error.localizedDescription)\n".utf8))
            preconditionFailure("Job persistence check failed: \(error.localizedDescription)")
        }

        // 3. HostResolverRegistry Plugin Rack
        let pdResolved = await HostResolverRegistry.resolveSingleLink("https://pixeldrain.com/u/zeC9sxvA")
        let mailItems = await HostResolverRegistry.resolveLinks("https://cloud.mail.ru/public/BqBr/K7pB3Myfy")
        print("3. HostResolverRegistry -> Pixeldrain='\(pdResolved.suggestedFilename ?? "")', Mail.ru count=\(mailItems.count)")

        // 4. UnpackService Multipart Normalization + Corrupt Archive Rejection
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("TestGame.part01.rar").path, contents: Data())
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("TestGame.7z.001").path, contents: Data())
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("setup_rain_world_1.11.8_(90164).exe").path, contents: Data())
        let normRar = UnpackService.normalizeMultipartArchivePath(tmpDir.appendingPathComponent("TestGame.part02.rar").path)
        let norm7z = UnpackService.normalizeMultipartArchivePath(tmpDir.appendingPathComponent("TestGame.7z.003").path)
        let normGOG = UnpackService.normalizeMultipartArchivePath(tmpDir.appendingPathComponent("setup_rain_world_1.11.8_(90164)-1.bin").path)
        precondition(normRar.hasSuffix("TestGame.part01.rar") && norm7z.hasSuffix("TestGame.7z.001") && normGOG.hasSuffix(".exe"))

        let badArchive = tmpDir.appendingPathComponent("corrupt_arch_test.7z").path
        try? Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x00]).write(to: URL(fileURLWithPath: badArchive))
        let unpackSvc = UnpackService()
        let badOut = await unpackSvc.executeUnpack(
            taskID: UUID(),
            archivePath: badArchive,
            candidatePasswords: ["cs.rin.ru"],
            onProgress: { _, _ in },
            onLog: { _, _ in }
        )
        let badRejected: Bool = {
            if case .failed = badOut { return true }
            return false
        }()
        precondition(badRejected)
        print("4. UnpackService -> multipart normalized OK, corruptArchiveRejected=\(badRejected)")

        // 5. PEBinaryInspector RVA Import Table Parser + Dynamic CrossOver Bottle Scanner + PatchService Language Binding
        let realOSS = "/Users/woooci/Library/Application Support/CrossOver/Bottles/Order of the Sinking Star/drive_c/Order of the Sinking Star/sinking_star.exe"
        if FileManager.default.fileExists(atPath: realOSS) {
            let pe = PEBinaryInspector.inspect(exePath: realOSS)
            print("5A. PEBinaryInspector (RVA Import Table) -> is64Bit=\(pe.is64Bit), importsSteamAPI=\(pe.importsSteamAPI), importsD3D12=\(pe.importsD3D12)")
            precondition(pe.is64Bit && pe.importsSteamAPI)
        }

        let discoveredBottles = CrossOverBottleScanner.scanInstalledBottles(
            bottlesDirectory: AppSettings.default.bottlesDirectory
        )
        let bottleTitles = discoveredBottles.map(\.title).joined(separator: ", ")
        print("5B. Dynamic Bottle Scanner -> discovered \(discoveredBottles.count) games: [\(bottleTitles)]")

        let collapsedBottle = Job(
            kind: .patch,
            title: "Existing Bottle",
            status: .succeeded,
            source: ArtifactRef(kind: .directory, value: "/tmp/existing-bottle"),
            expanded: false
        )
        let newBottle = Job(
            kind: .patch,
            title: "New Bottle",
            status: .succeeded,
            source: ArtifactRef(kind: .directory, value: "/tmp/new-bottle")
        )
        let scanCoordinator = PipelineCoordinator(
            services: DefaultWorkflowServices(),
            jobStore: JobStore(inMemoryOnly: true, seed: [collapsedBottle])
        )
        let addedBottleCount = await scanCoordinator.addDiscoveredBottles([newBottle])
        let bottleJobs = await scanCoordinator.jobStore.all().filter { $0.kind == .patch }
        let firstBottle = bottleJobs.min { $0.listPosition < $1.listPosition }
        precondition(addedBottleCount == 1 && firstBottle?.id == collapsedBottle.id && firstBottle?.expanded == true)
        print("5B. Dynamic Bottle Scanner -> discovered-job merge and first-item expansion verified")

        // Verify GOG thin Unity EXE selection + configurable defaultLanguage (tchinese -> TW)
        let gogMock = tmpDir.appendingPathComponent("GOG_RainWorld_Refactor_Mock").path
        try? FileManager.default.createDirectory(atPath: "\(gogMock)/__redist/ISI", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: "\(gogMock)/RainWorld_Data/Plugins/x86_64", withIntermediateDirectories: true)
        try? Data(repeating: 0x4D, count: 1_258_000).write(to: URL(fileURLWithPath: "\(gogMock)/__redist/ISI/scriptinterpreter.exe"))
        try? Data(repeating: 0x4D, count: 653_000).write(to: URL(fileURLWithPath: "\(gogMock)/RainWorld.exe"))
        try? Data(repeating: 0x4D, count: 295_000).write(to: URL(fileURLWithPath: "\(gogMock)/RainWorld_Data/Plugins/x86_64/steam_api64.dll"))
        try? "312520\n".write(toFile: "\(gogMock)/steam_appid.txt", atomically: true, encoding: .utf8)

        var customSettings = AppSettings.default
        customSettings.defaultLanguage = .tchinese
        let patchSvc = PatchService()
        let patchRes = try! await patchSvc.executePatch(
            taskID: UUID(),
            folderPath: gogMock,
            cleanTitle: "Rain World",
            settings: customSettings,
            onLog: { _, _ in }
        )
        let cfgContent = (try? String(contentsOfFile: "\(gogMock)/RainWorld_Data/Plugins/x86_64/steam_settings/configs.user.ini", encoding: .utf8)) ?? ""
        precondition((patchRes.exePath as NSString?)?.lastPathComponent == "RainWorld.exe")
        precondition(cfgContent.contains("language=tchinese") && cfgContent.contains("ip_country=TW"))
        print("5C. PatchService -> selectedEXE='RainWorld.exe', dynamic language=tchinese (TW) verified!")

        do {
            try await PatchWorkflowChecks.run()
        } catch {
            FileHandle.standardError.write(Data("Patch workflow check failed: \(error.localizedDescription)\n".utf8))
            preconditionFailure("Patch workflow check failed: \(error.localizedDescription)")
        }

        // 6. Verify Silent Background Relay (does NOT hijack activeTab!)
        let vm = AppComposition.makeViewModel(inMemoryOnly: true)
        vm.activeTab = .settings
        vm.autoRelay = true
        let silentArchiveDir = tmpDir.appendingPathComponent("silent-relay-source").path
        let silentArchive = tmpDir.appendingPathComponent("silent-relay.7z").path
        try? FileManager.default.createDirectory(atPath: silentArchiveDir, withIntermediateDirectories: true)
        try? "hello".write(toFile: "\(silentArchiveDir)/readme.txt", atomically: true, encoding: .utf8)
        if let sevenZip = ToolchainLocator.locateSevenZip() {
            _ = try? await ProcessSupervisor.shared.run(executable: sevenZip, arguments: ["a", "-y", silentArchive, "\(silentArchiveDir)/readme.txt"])
            let tid = UUID()
            let task = StudioTask(id: tid, title: "SilentRelay.7z", status: .locked(0.1), localPath: silentArchive)
            await vm.coordinator.addJob(Job.fromLegacy(task, kind: .unpack))
            await vm.coordinator.runUnpackTask(
                taskID: tid,
                archivePath: silentArchive,
                candidatePasswords: [""],
                settings: vm.settingsStore.settings
            )
            precondition(vm.activeTab == .settings, "AutoRelay must NOT hijack user's activeTab!")
            await waitForSelfTest({ !vm.tasks(for: .patch).isEmpty }, message: "AutoRelay did not enqueue a downstream Patch task")
            await waitForSelfTest({ vm.tasks(for: .patch).allSatisfy { $0.status == .done } }, message: "Silent relay patch did not finish")
            await vm.flushTasksImmediately()
            print("6. PipelineCoordinator -> Silent Background Relay verified (activeTab remained .settings while patch job count=\(vm.jobs(of: .patch).count))")
        }
        try? FileManager.default.removeItem(atPath: silentArchiveDir)
        try? FileManager.default.removeItem(atPath: silentArchive)

        let processStart = Date()
        let runningProcess = Task {
            try await ProcessSupervisor.shared.run(executable: "/bin/sleep", arguments: ["30"], taskID: UUID())
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        runningProcess.cancel()
        _ = try? await runningProcess.value
        precondition(Date().timeIntervalSince(processStart) < 5, "Task cancellation did not terminate the process")
        print("7. ProcessSupervisor -> Swift Task cancellation terminates a running process")

        if let localURL = ProcessInfo.processInfo.environment["CHRYSA_SELFTEST_DOWNLOAD_URL"] {
            await runLocalPipelineSelfTest(url: localURL, directory: tmpDir)
        } else {
            print("8. Local download pipeline -> skipped (CHRYSA_SELFTEST_DOWNLOAD_URL not set)")
        }
        if let slowURL = ProcessInfo.processInfo.environment["CHRYSA_SELFTEST_SLOW_DOWNLOAD_URL"] {
            await runActiveDownloadCancellationSelfTest(url: slowURL, directory: tmpDir)
        } else {
            print("10. Active download cancellation -> skipped (CHRYSA_SELFTEST_SLOW_DOWNLOAD_URL not set)")
        }

        await ProcessSupervisor.shared.terminateAll()
        print("=== [All Decoupled Architecture Self-Tests PASSED] ===")
    }

    @MainActor
    private static func runLocalPipelineSelfTest(url: String, directory: URL) async {
        let vm = AppComposition.makeViewModel(inMemoryOnly: true)
        vm.settingsStore.settings.downloadDirectory = directory.appendingPathComponent("downloads").path
        vm.settingsStore.settings.autoRelay = true
        vm.activeTab = .settings
        vm.startDownload(urlString: url)
        await waitForSelfTest({
            vm.jobs.count == 1 && vm.jobs[0].kind == .patch && vm.jobs[0].status == .succeeded
        }, message: "Local download pipeline did not finish")
        let firstPipelineID = vm.jobs[0].id
        precondition(vm.jobs(of: .download).isEmpty && vm.jobs(of: .unpack).isEmpty, "Automatic relay created extra stage jobs")
        precondition(vm.activeTab == .settings, "Automatic relay changed the selected tab")

        let missingURL = url + ".missing"
        let previousUnpacks = vm.jobs(of: .unpack).count
        vm.startDownload(urlString: missingURL)
        await waitForSelfTest({ vm.jobs(of: .download).contains(where: { $0.sourceURL == missingURL }) }, message: "Missing download job was not published")
        let failedTask = vm.tasks(for: .download).first(where: { $0.sourceURL == missingURL })!
        let failedID = failedTask.id
        await waitForSelfTest({ vm.task(for: failedID)?.status == .failed }, message: "Missing download did not fail")
        precondition(vm.task(for: failedID)?.status == .failed && vm.jobs(of: .unpack).count == previousUnpacks, "Failed download started a downstream task")
        vm.beginEditTask(vm.task(for: failedID)!)
        vm.editPathOrURLInput = url
        vm.saveEditedTask(andRetry: true)
        await waitForSelfTest({
            vm.jobs(of: .patch).count == 2 && vm.jobs(of: .patch).allSatisfy { $0.status == .succeeded }
        }, message: "Retried download pipeline did not finish")
        precondition(vm.jobs(of: .patch).contains(where: { $0.id != firstPipelineID && $0.status == .succeeded }), "Retried pipeline did not produce one completed job")
        await vm.flushTasksImmediately()
        let obsoleteJob = await vm.coordinator.jobStore.job(for: failedID)
        precondition(obsoleteJob == nil, "Retry retained the obsolete failed job")
        let savedJobs = await vm.coordinator.jobStore.all()
        precondition(savedJobs.count == 2 && savedJobs.allSatisfy { $0.kind == .patch && $0.status == .succeeded }, "Pipeline did not retain one terminal job per request")

        let stopped = StudioTask(title: "stopped.7z", status: .running(0), sourceURL: url)
        await vm.coordinator.addJob(Job.fromLegacy(stopped, kind: .download))
        vm.stopTask(stopped)
        await waitForSelfTest({ vm.task(for: stopped.id)?.pill == "已停止" }, message: "UI stop did not cancel the task")
        let resolved = ResolvedDownload(finalURL: url, headers: [], suggestedFilename: stopped.title)
        await vm.coordinator.runDownloadTask(taskID: stopped.id, resolved: resolved, settings: vm.settingsStore.settings)
        await vm.flushTasksImmediately()
        let savedStopped = await vm.coordinator.jobStore.job(for: stopped.id)
        precondition(savedStopped?.status == .cancelled && vm.task(for: stopped.id)?.pill == "已停止", "Stopped task was revived")
        precondition(vm.jobs(of: .unpack).isEmpty && vm.jobs(of: .patch).count == 2, "Stopped task started a downstream stage")
        print("8. Local download pipeline -> download, unpack, patch relay, failure, retry and UI stop OK")
        await runFolderPipelineSelfTest(url: url, directory: directory)
    }

    @MainActor
    private static func runFolderPipelineSelfTest(url: String, directory: URL) async {
        let vm = AppComposition.makeViewModel(inMemoryOnly: true)
        let root = directory.appendingPathComponent("folder-downloads", isDirectory: true)
        vm.settingsStore.settings.downloadDirectory = root.path
        vm.autoRelay = true
        vm.settingsStore.settings.deleteArchiveAfterUnpack = false
        vm.activeTab = .settings
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldFile = root.appendingPathComponent("fixture.7z")
        let oldBytes = Data("existing-file".utf8)
        try! oldBytes.write(to: oldFile)

        let first = StudioTask(title: "fixture.7z", status: .running(0), sourceURL: url)
        await vm.coordinator.addJob(Job.fromLegacy(first, kind: .download))
        await vm.coordinator.runFolderDownloadPipeline(firstTaskID: first.id, guessedName: first.title, items: [
            ResolvedDownload(finalURL: url, headers: [], suggestedFilename: "fixture.7z"),
            ResolvedDownload(finalURL: url, headers: [], suggestedFilename: "notes.txt")
        ], settings: vm.settingsStore.settings)
        await waitForSelfTest({
            vm.jobs(of: .patch).count == 1 && vm.jobs(of: .patch)[0].status == .succeeded
        }, message: "Folder download did not finish its relay")
        await vm.flushTasksImmediately()
        let downloadedPath = try! FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey])
            .first(where: { $0.pathExtension == "7z" && $0 != oldFile })!.path
        let primaryJob = await vm.coordinator.jobStore.job(for: first.id)
        precondition(downloadedPath != oldFile.path && primaryJob?.kind == .patch && primaryJob?.status == .succeeded,
            "Folder relay did not preserve the primary download job through patching")
        precondition(try! Data(contentsOf: oldFile) == oldBytes, "Folder download overwrote an existing file")
        precondition(vm.activeTab == .settings, "Folder relay changed the selected tab")

        let staleFile = root.appendingPathComponent("stale.7z")
        try! FileManager.default.copyItem(atPath: downloadedPath, toPath: staleFile.path)
        let failed = StudioTask(title: "stale.7z", status: .running(0), sourceURL: url + ".missing")
        await vm.coordinator.addJob(Job.fromLegacy(failed, kind: .download))
        await vm.coordinator.runFolderDownloadPipeline(firstTaskID: failed.id, guessedName: failed.title, items: [
            ResolvedDownload(finalURL: url + ".missing", headers: [], suggestedFilename: "stale.7z"),
            ResolvedDownload(finalURL: url, headers: [], suggestedFilename: "other-notes.txt")
        ], settings: vm.settingsStore.settings)
        await vm.flushTasksImmediately()
        precondition(vm.task(for: failed.id)?.status == .failed, "Missing folder download did not fail")
        precondition(vm.jobs(of: .unpack).isEmpty && vm.jobs(of: .patch).count == 1, "Failed folder download relayed an existing archive")
        precondition(FileManager.default.fileExists(atPath: staleFile.path), "Failed folder download removed the existing archive")
        print("9. Folder pipeline -> published artifact relay, existing-file preservation and failure gating OK")
    }

    @MainActor
    private static func runActiveDownloadCancellationSelfTest(url: String, directory: URL) async {
        let vm = AppComposition.makeViewModel(inMemoryOnly: true)
        let root = directory.appendingPathComponent("cancelled-download", isDirectory: true)
        vm.settingsStore.settings.downloadDirectory = root.path
        vm.autoRelay = true
        vm.startDownload(urlString: url)
        await waitForSelfTest({ !vm.jobs(of: .download).isEmpty }, message: "Cancellation test download was not published")
        let taskID = vm.jobs(of: .download)[0].id
        await waitForSelfTest({
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else {
                return false
            }
            for case let file as URL in entries {
                if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                    return true
                }
            }
            return false
        }, message: "Slow download never wrote its first bytes")
        guard let runningTask = vm.task(for: taskID),
              case .running = runningTask.status else {
            preconditionFailure("Slow download finished before cancellation could be checked")
        }
        vm.stopTask(runningTask)
        await waitForSelfTest({
            (try? FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty) == true
        }, message: "Cancelled download retained temporary or published files")
        await vm.flushTasksImmediately()
        let saved = await vm.coordinator.jobStore.job(for: taskID)
        precondition(saved?.status == .cancelled && saved?.output == nil, "Running download lost its cancelled state")
        precondition(vm.task(for: taskID)?.pill == "已停止", "Late download progress revived the stopped task")
        precondition(vm.jobs(of: .unpack).isEmpty && vm.jobs(of: .patch).isEmpty, "Running download cancellation started a downstream stage")
        print("10. Active download cancellation -> process stopped, temporary files removed, no downstream relay OK")
    }

    @MainActor
    private static func waitForSelfTest(_ condition: () -> Bool, message: String) async {
        let deadline = Date().addingTimeInterval(20)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(condition(), message)
    }
}

private struct SelfTestPassthroughStage: Stage {
    let id = StageID("self-test.passthrough")

    func execute(context: StageContext) async -> StageResult {
        .success(StageOutput(artifact: context.input))
    }
}
