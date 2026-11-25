import ChrysaCore
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
        let prefsItem = appMenu.addItem(withTitle: "设置...", action: #selector(openSettingsFromMenu(_:)), keyEquivalent: ",")
        prefsItem.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏 Chrysa", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 Chrysa", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // 2. File Menu (Cmd+N)
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "文件")
        let newItem = fileMenu.addItem(withTitle: "新建 / 添加...", action: #selector(triggerPrimaryAddFromMenu(_:)), keyEquivalent: "n")
        newItem.target = self
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        // 3. Edit Menu (Cmd+V, Cmd+C, Cmd+X, Cmd+A, Cmd+Z, Cmd+F)
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
        editMenu.addItem(NSMenuItem.separator())
        let findItem = editMenu.addItem(withTitle: "搜索", action: #selector(focusSearchFromMenu(_:)), keyEquivalent: "f")
        findItem.target = self
        editMenuItem.submenu = editMenu

        // 4. View / Navigation Menu (Cmd+1..4, Shift+Cmd+L)
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "显示")
        let navSpecs: [(String, Selector, String)] = [
            ("下载", #selector(selectDownloadTab(_:)), "1"),
            ("解压", #selector(selectUnpackTab(_:)), "2"),
            ("补丁", #selector(selectPatchTab(_:)), "3"),
            ("启动", #selector(selectLaunchTab(_:)), "4")
        ]
        for (title, sel, key) in navSpecs {
            let item = viewMenu.addItem(withTitle: title, action: sel, keyEquivalent: key)
            item.target = self
        }
        viewMenu.addItem(NSMenuItem.separator())
        let logItem = viewMenu.addItem(withTitle: "显示 / 隐藏诊断日志", action: #selector(toggleLogDrawerFromMenu(_:)), keyEquivalent: "l")
        logItem.keyEquivalentModifierMask = [.command, .shift]
        logItem.target = self
        viewMenuItem.submenu = viewMenu

        // 5. Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @MainActor @objc private func openSettingsFromMenu(_ sender: Any?) {
        vm?.openSettings()
    }

    @MainActor @objc private func selectDownloadTab(_ sender: Any?) {
        vm?.activeTab = .download
    }

    @MainActor @objc private func selectUnpackTab(_ sender: Any?) {
        vm?.activeTab = .unpack
    }

    @MainActor @objc private func selectPatchTab(_ sender: Any?) {
        vm?.activeTab = .patch
    }

    @MainActor @objc private func selectLaunchTab(_ sender: Any?) {
        vm?.activeTab = .launch
    }

    @MainActor @objc private func toggleLogDrawerFromMenu(_ sender: Any?) {
        vm?.toggleLogDrawer()
    }

    @MainActor @objc private func triggerPrimaryAddFromMenu(_ sender: Any?) {
        guard let vm else { return }
        switch vm.activeTab {
        case .download:
            vm.requestPrimaryInputFocus()
        case .launch:
            vm.importLaunchGameFromPanel()
        case .unpack, .patch:
            vm.pickFileForActiveTab()
        case .settings:
            vm.activeTab = .download
            vm.requestPrimaryInputFocus()
        }
    }

    @MainActor @objc private func focusSearchFromMenu(_ sender: Any?) {
        guard let vm else { return }
        if vm.activeTab == .settings {
            vm.exitSettings()
            DispatchQueue.main.async {
                vm.requestSearchFocus()
            }
        } else {
            vm.requestSearchFocus()
        }
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        vm = AppComposition.makeViewModel(seedDemoData: false)
        NSApp.appearance = vm.appearanceMode.nsAppearance
        let contentView = ThingsStudioMainView(vm: vm, isSnapshotMode: false)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 610),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
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
            vmRef?.settingsStore.flushPendingPersistence()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ChrysaAppMain {
    private struct SnapshotPreset {
        let tab: StudioTab
        let category: SettingsCategory
        let mascot: MascotTheme
        let appearance: AppearanceMode
        let accentMode: AccentColorMode
        let siphonSteps: Int
        let showLogs: Bool
        let suffix: String

        init(
            _ tab: StudioTab,
            _ category: SettingsCategory,
            _ mascot: MascotTheme,
            appearance: AppearanceMode = .light,
            accentMode: AccentColorMode = .monochrome,
            siphonSteps: Int = 0,
            showLogs: Bool = false,
            suffix: String
        ) {
            self.tab = tab
            self.category = category
            self.mascot = mascot
            self.appearance = appearance
            self.accentMode = accentMode
            self.siphonSteps = siphonSteps
            self.showLogs = showLogs
            self.suffix = suffix
        }
    }

    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--render-snapshots") {
            let app = NSApplication.shared
            let outDir = ProcessInfo.processInfo.environment["CHRYSA_SNAPSHOT_DIR"]
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("ChrysaSnapshots", isDirectory: true).path
            try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            let presets: [SnapshotPreset] = [
                // Light mode presets
                SnapshotPreset(.download, .appearance, .forestCube, suffix: "dl"),
                SnapshotPreset(.download, .appearance, .roundMochi, suffix: "dl_mochi"),
                SnapshotPreset(.download, .appearance, .grokAstral, suffix: "dl_grok"),
                SnapshotPreset(.download, .appearance, .forestCube, siphonSteps: 15, suffix: "dl_phase1_early_cube"),
                SnapshotPreset(.download, .appearance, .roundMochi, siphonSteps: 31, suffix: "dl_phase1_arch_mochi"),
                SnapshotPreset(.download, .appearance, .forestCube, siphonSteps: 58, suffix: "dl_siphon_cube"),
                SnapshotPreset(.download, .appearance, .roundMochi, siphonSteps: 58, suffix: "dl_siphon_mochi"),
                SnapshotPreset(.download, .appearance, .grokAstral, siphonSteps: 58, suffix: "dl_siphon_grok"),
                SnapshotPreset(.download, .appearance, .forestCube, siphonSteps: 83, suffix: "dl_chomp_cube"),
                SnapshotPreset(.download, .appearance, .roundMochi, siphonSteps: 96, suffix: "dl_chew_mochi"),
                SnapshotPreset(.download, .appearance, .none, suffix: "dl_quiet"),
                SnapshotPreset(.download, .appearance, .forestCube, showLogs: true, suffix: "dl_logs"),
                SnapshotPreset(.unpack, .appearance, .forestCube, suffix: "un"),
                SnapshotPreset(.patch, .appearance, .forestCube, suffix: "pa"),
                SnapshotPreset(.launch, .appearance, .forestCube, suffix: "launch"),
                SnapshotPreset(.settings, .appearance, .forestCube, suffix: "settings_appearance"),
                SnapshotPreset(.settings, .download, .forestCube, suffix: "settings_download"),
                SnapshotPreset(.settings, .unpack, .forestCube, suffix: "settings_unpack"),
                SnapshotPreset(.settings, .patch, .forestCube, suffix: "settings_patch"),
                // Dark mode presets
                SnapshotPreset(.download, .appearance, .forestCube, appearance: .dark, suffix: "dl_dark"),
                SnapshotPreset(.download, .appearance, .forestCube, appearance: .dark, showLogs: true, suffix: "dl_logs_dark"),
                SnapshotPreset(.download, .appearance, .forestCube, appearance: .dark, accentMode: .followAppIcon, suffix: "dl_dark_accent"),
                SnapshotPreset(.unpack, .appearance, .forestCube, appearance: .dark, suffix: "un_dark"),
                SnapshotPreset(.patch, .appearance, .forestCube, appearance: .dark, suffix: "pa_dark"),
                SnapshotPreset(.launch, .appearance, .forestCube, appearance: .dark, suffix: "launch_dark"),
                SnapshotPreset(.settings, .appearance, .forestCube, appearance: .dark, suffix: "settings_appearance_dark"),
                SnapshotPreset(.settings, .appearance, .forestCube, appearance: .dark, accentMode: .custom, suffix: "settings_appearance_dark_cobalt"),
                SnapshotPreset(.settings, .download, .forestCube, appearance: .dark, suffix: "settings_download_dark"),
                SnapshotPreset(.settings, .unpack, .forestCube, appearance: .dark, suffix: "settings_unpack_dark"),
                SnapshotPreset(.settings, .patch, .forestCube, appearance: .dark, suffix: "settings_patch_dark")
            ]

            for preset in presets {
                let isDark = (preset.appearance == .dark)
                let vm = AppComposition.makeViewModel(seedDemoData: true)
                vm.activeTab = preset.tab
                vm.settingsCategory = preset.category
                vm.setAppearanceMode(preset.appearance)
                vm.setAccentColorMode(preset.accentMode)
                vm.setMascotTheme(preset.mascot)
                vm.isLogDrawerPresented = preset.showLogs
                if preset.showLogs {
                    vm.logDrawerHeight = 260
                }
                if preset.siphonSteps > 0 {
                    var t: TimeInterval = 0.20
                    _ = vm.mascot.stepTopFrame(at: t, theme: preset.mascot, width: 605, boxTopY: 52, isTypingURL: false, isSnapshotMode: false)
                    vm.triggerMascotIntake(
                        kind: .url,
                        rawText: "https://pixeldrain.com/api/file/SuperLongTokenId_1234567890?download"
                    )
                    for _ in 0..<preset.siphonSteps {
                        t += 1.0 / 60.0
                        _ = vm.mascot.stepTopFrame(at: t, theme: preset.mascot, width: 605, boxTopY: 52, isTypingURL: false, isSnapshotMode: false)
                    }
                    if preset.siphonSteps >= 82 {
                        vm.stopSiphonPlaceholderMaskForSnapshot()
                    }
                }

                let nsAppearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
                app.appearance = nsAppearance

                let snapshotWallpaper: LinearGradient = isDark
                    ? LinearGradient(
                        colors: [
                            Color(red: 0.25, green: 0.11, blue: 0.29),
                            Color(red: 0.10, green: 0.12, blue: 0.28),
                            Color(red: 0.32, green: 0.15, blue: 0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    : LinearGradient(
                        colors: [
                            Color(red: 0.87, green: 0.89, blue: 0.94),
                            Color(red: 0.92, green: 0.92, blue: 0.95),
                            Color(red: 0.93, green: 0.89, blue: 0.86)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                let framed = ThingsStudioMainView(vm: vm, isSnapshotMode: true)
                    .frame(width: 880, height: 610)
                    .clipShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous)
                            .stroke(isDark ? Color.white.opacity(0.11) : Color.black.opacity(0.11), lineWidth: 1)
                    )
                    .padding(22)
                    .background(snapshotWallpaper)
                    .environment(\.colorScheme, isDark ? .dark : .light)

                var cgImage: CGImage?
                if let nsAppearance {
                    nsAppearance.performAsCurrentDrawingAppearance {
                        let renderer = ImageRenderer(content: framed)
                        renderer.scale = 2.0
                        cgImage = renderer.cgImage
                    }
                } else {
                    let renderer = ImageRenderer(content: framed)
                    renderer.scale = 2.0
                    cgImage = renderer.cgImage
                }

                if let cgImage {
                    let rep = NSBitmapImageRep(cgImage: cgImage)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        let path = "\(outDir)/chrysa_ready_\(preset.suffix).png"
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
}
