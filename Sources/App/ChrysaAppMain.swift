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
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--render-snapshots") {
            let outDir = ProcessInfo.processInfo.environment["CHRYSA_SNAPSHOT_DIR"]
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("ChrysaSnapshots", isDirectory: true).path
            try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            let presets: [(StudioTab, SettingsCategory, String)] = [
                (.download, .appearance, "dl"),
                (.unpack, .appearance, "un"),
                (.patch, .appearance, "pa"),
                (.launch, .appearance, "launch"),
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
}
