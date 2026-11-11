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
        vm = StudioViewModel(seedDemoData: false)
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
                let vm = StudioViewModel(seedDemoData: true)
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

        // 3. HostResolverRegistry Plugin Rack
        let pdResolved = await HostResolverRegistry.resolveSingleLink("https://pixeldrain.com/u/zeC9sxvA")
        let mailItems = await HostResolverRegistry.resolveLinks("https://cloud.mail.ru/public/BqBr/K7pB3Myfy")
        print("3. HostResolverRegistry -> Pixeldrain='\(pdResolved.suggestedFilename ?? "")', Mail.ru count=\(mailItems.count)")

        // 4. UnpackService Multipart Normalization + Corrupt Archive Rejection
        FileManager.default.createFile(atPath: "/tmp/TestGame.part01.rar", contents: Data())
        FileManager.default.createFile(atPath: "/tmp/TestGame.7z.001", contents: Data())
        FileManager.default.createFile(atPath: "/tmp/setup_rain_world_1.11.8_(90164).exe", contents: Data())
        let normRar = UnpackService.normalizeMultipartArchivePath("/tmp/TestGame.part02.rar")
        let norm7z = UnpackService.normalizeMultipartArchivePath("/tmp/TestGame.7z.003")
        let normGOG = UnpackService.normalizeMultipartArchivePath("/tmp/setup_rain_world_1.11.8_(90164)-1.bin")
        precondition(normRar.hasSuffix("TestGame.part01.rar") && norm7z.hasSuffix("TestGame.7z.001") && normGOG.hasSuffix(".exe"))

        let badArchive = "/tmp/corrupt_arch_test.7z"
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

        let discoveredBottles = PatchAndBottleService.scanInstalledBottles(
            bottlesDirectory: AppSettings.default.bottlesDirectory
        )
        let bottleTitles = discoveredBottles.map(\.title).joined(separator: ", ")
        print("5B. Dynamic Bottle Scanner -> discovered \(discoveredBottles.count) games: [\(bottleTitles)]")

        // Verify GOG thin Unity EXE selection + configurable defaultLanguage (tchinese -> TW)
        let gogMock = "/tmp/GOG_RainWorld_Refactor_Mock"
        try? FileManager.default.removeItem(atPath: gogMock)
        defer { try? FileManager.default.removeItem(atPath: gogMock) }
        try? FileManager.default.createDirectory(atPath: "\(gogMock)/__redist/ISI", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: "\(gogMock)/RainWorld_Data/Plugins/x86_64", withIntermediateDirectories: true)
        try? Data(repeating: 0x4D, count: 1_258_000).write(to: URL(fileURLWithPath: "\(gogMock)/__redist/ISI/scriptinterpreter.exe"))
        try? Data(repeating: 0x4D, count: 653_000).write(to: URL(fileURLWithPath: "\(gogMock)/RainWorld.exe"))
        try? Data(repeating: 0x4D, count: 295_000).write(to: URL(fileURLWithPath: "\(gogMock)/RainWorld_Data/Plugins/x86_64/steam_api64.dll"))
        try? "312520\n".write(toFile: "\(gogMock)/steam_appid.txt", atomically: true, encoding: .utf8)

        var customSettings = AppSettings.default
        customSettings.defaultLanguage = .tchinese
        let patchSvc = PatchAndBottleService()
        let patchRes = await patchSvc.executePatch(
            taskID: UUID(),
            folderPath: gogMock,
            cleanTitle: "Rain World",
            settings: customSettings,
            onLog: { _, _ in }
        )
        let cfgContent = (try? String(contentsOfFile: "\(gogMock)/RainWorld_Data/Plugins/x86_64/steam_settings/configs.user.ini", encoding: .utf8)) ?? ""
        precondition((patchRes.exePath as NSString?)?.lastPathComponent == "RainWorld.exe")
        precondition(cfgContent.contains("language=tchinese") && cfgContent.contains("ip_country=TW"))
        print("5C. PatchAndBottleService -> selectedEXE='RainWorld.exe', dynamic language=tchinese (TW) verified!")

        // 6. Verify Silent Background Relay (does NOT hijack activeTab!)
        let vm = StudioViewModel(inMemoryOnly: true)
        vm.activeTab = .settings
        vm.autoRelay = true
        let silentArchiveDir = "/tmp/silent_relay_src_\(UUID().uuidString)"
        let silentArchive = "/tmp/silent_relay_\(UUID().uuidString).7z"
        try? FileManager.default.createDirectory(atPath: silentArchiveDir, withIntermediateDirectories: true)
        try? "hello".write(toFile: "\(silentArchiveDir)/readme.txt", atomically: true, encoding: .utf8)
        if let sevenZip = ToolchainLocator.locateSevenZip() {
            _ = try? await ProcessSupervisor.shared.run(executable: sevenZip, arguments: ["a", "-y", silentArchive, "\(silentArchiveDir)/readme.txt"])
            let tid = UUID()
            vm.unpackTasks.insert(StudioTask(id: tid, title: "SilentRelay.7z", status: .locked(0.1), localPath: silentArchive), at: 0)
            await vm.coordinator.runUnpackTask(taskID: tid, archivePath: silentArchive, candidatePasswords: [""])
            precondition(vm.activeTab == .settings, "AutoRelay must NOT hijack user's activeTab!")
            precondition(!vm.patchTasks.isEmpty, "AutoRelay should enqueue downstream Patch task in background!")
            print("6. PipelineCoordinator -> Silent Background Relay verified (activeTab remained .settings while patchTasks count=\(vm.patchTasks.count))")
        }
        try? FileManager.default.removeItem(atPath: silentArchiveDir)
        try? FileManager.default.removeItem(atPath: silentArchive)

        await ProcessSupervisor.shared.terminateAll()
        print("=== [All Decoupled Architecture Self-Tests PASSED] ===")
    }
}
