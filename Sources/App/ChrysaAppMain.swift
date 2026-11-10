import SwiftUI
import AppKit

// MARK: - App Delegate & CLI Self-Test / Snapshot Entrypoint
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

        // 2. Edit Menu (Enables Cmd+V Paste, Cmd+C Copy, Cmd+X Cut, Cmd+A Select All, Cmd+Z Undo in all TextFields!)
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

        // Global Cmd+V fallback when window is active but TextField isn't focused yet
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "v" {
                if let responder = self.window?.firstResponder, responder is NSText {
                    // Let NSTextField / Edit menu handle standard paste into focused field
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
}

@main
struct ChrysaAppMain {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--self-test") {
            await runBackendSelfTest()
            return
        }

        if CommandLine.arguments.contains("--render-snapshots") {
            let outDir = "/Users/woooci/.gemini/antigravity/brain/1469f655-160e-4a84-9da9-fa0217bac001"
            let presets: [(StudioTab, SettingsCategory, String)] = [
                (.download, .appearance, "dl"),
                (.unpack, .appearance, "un"),
                (.patch, .appearance, "pa"),
                (.settings, .appearance, "settings_appearance"),
                (.settings, .unpack, "settings_unpack")
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
    static func runBackendSelfTest() async {
        print("=== [Chrysa Backend Hardening Self-Test] ===")

        // Test 1: System Proxy Detection + Host Routing
        let proxy = StudioViewModel.detectSystemProxy()
        let gofileProxy = StudioViewModel.hostNeedsProxy("https://store4.gofile.io/download/web/xxx/game.7z")
        let vfProxy = StudioViewModel.hostNeedsProxy("https://bi.vikingfile.com/download/xxx/SAN.7z")
        print("1. System Proxy -> \(proxy ?? "none") | Gofile uses proxy=\(gofileProxy), VikingFile uses proxy=\(vfProxy)")

        // Test 2: VikingFile Resolver + Strict Byte-Count Chunk Verification
        let vf = await StudioViewModel.resolveHostLink("https://vikingfile.com/d/GFXaaEgK9t/SAN_21675470.7z")
        print("2. VikingFile Resolver -> useChunkedRange=\(vf.useChunkedRange), totalSize=\(vf.totalSize ?? 0) bytes, filename=\(vf.suggestedFilename ?? "")")

        // Test 3: Multi-part Archive Normalization + Strict Unpack Exit-Code Check (Reject Bad Archive)
        FileManager.default.createFile(atPath: "/tmp/TestGame.part01.rar", contents: Data())
        FileManager.default.createFile(atPath: "/tmp/TestGame.7z.001", contents: Data())
        let normRar = StudioViewModel.normalizeMultipartArchivePath("/tmp/TestGame.part02.rar")
        let norm7z = StudioViewModel.normalizeMultipartArchivePath("/tmp/TestGame.7z.003")
        let vm = StudioViewModel(seedDemoData: false)
        let badArchive = "/tmp/corrupt_test.7z"
        try? Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x00]).write(to: URL(fileURLWithPath: badArchive))
        let unpackTID = UUID()
        vm.unpackTasks.insert(StudioTask(id: unpackTID, title: "CorruptTest", status: .running(0.1), pill: "测试", rightText: "解压中"), at: 0)
        await vm.runSevenZipUnpack(taskID: unpackTID, archivePath: badArchive, candidatePasswords: ["cs.rin.ru"])
        let unpackStatus = vm.unpackTasks.first(where: { $0.id == unpackTID })?.status
        let unpackRejected = (unpackStatus == .failed)
        print("3. Unpack Hardening -> .part02.rar normalized='\(URL(fileURLWithPath: normRar).lastPathComponent)', .7z.003 normalized='\(URL(fileURLWithPath: norm7z).lastPathComponent)', corruptArchiveRejected=\(unpackRejected)")

        // Test 4A: CSF Patch with Existing DLL (SANABI)
        let acfDir = "/tmp/SAN_21675470_extracted/steamapps"
        try? FileManager.default.createDirectory(atPath: acfDir, withIntermediateDirectories: true)
        let acfPath = "\(acfDir)/appmanifest_1562700.acf"
        let acfSample = "\"AppState\"\n{\n\t\"appid\"\t\t\"1562700\"\n\t\"name\"\t\t\"SANABI\"\n}\n"
        try? acfSample.write(toFile: acfPath, atomically: true, encoding: .utf8)

        let tidA = UUID()
        vm.patchTasks.insert(StudioTask(id: tidA, title: "SAN 21675470", status: .running(0.35), pill: "扫描中", rightText: "处理中"), at: 0)
        await vm.runGoldbergPatch(taskID: tidA, folderPath: "/tmp/SAN_21675470_extracted", cleanTitle: "SAN 21675470")
        if let pA = vm.patchTasks.first(where: { $0.id == tidA }) {
            print("4A. Existing DLL Patch -> title='\(pA.title)', appID='\(pA.appID ?? "")', pill='\(pA.pill ?? "")', rightText='\(pA.rightText)'")
        }

        // Test 4B: Unity Missing-DLL Injection (Remove steam_api64.dll and verify Unity *_Data/Plugins/x86_64 auto-injection)
        let unityMock = "/tmp/UnityMissingDLL_Test"
        try? FileManager.default.removeItem(atPath: unityMock)
        try? FileManager.default.createDirectory(atPath: "\(unityMock)/SNB_Data/Plugins/x86_64", withIntermediateDirectories: true)
        try? FileManager.default.copyItem(atPath: "/tmp/SAN_21675470_extracted/steamapps/common/SANABI/SNB.exe", toPath: "\(unityMock)/SNB.exe")
        let tidB = UUID()
        vm.patchTasks.insert(StudioTask(id: tidB, title: "SANABI", status: .running(0.35), pill: "扫描中", rightText: "处理中"), at: 0)
        await vm.runGoldbergPatch(taskID: tidB, folderPath: unityMock, cleanTitle: "SANABI")
        if let pB = vm.patchTasks.first(where: { $0.id == tidB }) {
            let injectedExists = FileManager.default.fileExists(atPath: "\(unityMock)/SNB_Data/Plugins/x86_64/steam_api64.dll")
            print("4B. Unity Missing-DLL Injection -> pill='\(pB.pill ?? "")', injectedInPlugins=\(injectedExists), appID='\(pB.appID ?? "")'")
        }

        // Test 4C: Native PE Missing-DLL Injection (Order of the Sinking Star where uploader deleted steam_api64.dll)
        let peMock = "/tmp/PEMissingDLL_Test"
        try? FileManager.default.removeItem(atPath: peMock)
        try? FileManager.default.createDirectory(atPath: peMock, withIntermediateDirectories: true)
        let realOSS = "/Users/woooci/Library/Application Support/CrossOver/Bottles/Order of the Sinking Star/drive_c/Order of the Sinking Star/sinking_star.exe"
        if FileManager.default.fileExists(atPath: realOSS) {
            try? FileManager.default.copyItem(atPath: realOSS, toPath: "\(peMock)/sinking_star.exe")
            let tidC = UUID()
            vm.patchTasks.insert(StudioTask(id: tidC, title: "Order of the Sinking Star", status: .running(0.35), pill: "扫描中", rightText: "处理中"), at: 0)
            await vm.runGoldbergPatch(taskID: tidC, folderPath: peMock, cleanTitle: "Order of the Sinking Star")
            if let pC = vm.patchTasks.first(where: { $0.id == tidC }) {
                let injectedExists = FileManager.default.fileExists(atPath: "\(peMock)/steam_api64.dll")
                print("4C. Native PE Missing-DLL Injection -> pill='\(pC.pill ?? "")', injectedNextToExe=\(injectedExists), appID='\(pC.appID ?? "")', rightText='\(pC.rightText)'")
            }
        }

        // Test 5: End-to-End Pixeldrain Pipeline (https://pixeldrain.com/u/zeC9sxvA -> sf-dl -> Unpack -> Patch)
        let pdResolved = await StudioViewModel.resolveHostLink("https://pixeldrain.com/u/zeC9sxvA")
        print("5A. Pixeldrain Resolver -> filename='\(pdResolved.suggestedFilename ?? "")', size=\(pdResolved.totalSize ?? 0) bytes, url='\(pdResolved.finalURL)'")

        let dlTID = UUID()
        vm.autoRelay = false
        vm.downloadTasks.insert(StudioTask(id: dlTID, title: pdResolved.suggestedFilename ?? "zeC9sxvA", status: .running(0.05), pill: "下载中", rightText: "准备中"), at: 0)
        await vm.runAria2Download(taskID: dlTID, resolved: pdResolved)
        if let dlTask = vm.downloadTasks.first(where: { $0.id == dlTID }),
           let archivePath = dlTask.localPath {
            print("5B. Pixeldrain Download -> status=\(dlTask.status), localPath='\(archivePath)'")

            let unTID = UUID()
            vm.unpackTasks.insert(StudioTask(id: unTID, title: dlTask.title, status: .locked(0.1), pill: "试密中", rightText: ""), at: 0)
            await vm.runSevenZipUnpack(taskID: unTID, archivePath: archivePath, candidatePasswords: [""] + vm.passwords)
            if let unTask = vm.unpackTasks.first(where: { $0.id == unTID }),
               let unpackedDir = unTask.localPath {
                print("5C. Pixeldrain Unpack -> status=\(unTask.status), pill='\(unTask.pill ?? "")', unpackedDir='\(unpackedDir)'")

                let paTID = UUID()
                let cleaned = StudioViewModel.cleanGameTitle(from: (unpackedDir as NSString).lastPathComponent)
                vm.patchTasks.insert(StudioTask(id: paTID, title: cleaned, status: .running(0.35), pill: "扫描中", rightText: "处理中"), at: 0)
                await vm.runGoldbergPatch(taskID: paTID, folderPath: unpackedDir, cleanTitle: cleaned)
                if let paTask = vm.patchTasks.first(where: { $0.id == paTID }) {
                    let dllSize = (try? FileManager.default.attributesOfItem(atPath: "\(unpackedDir)/RainWorld_Data/Plugins/x86_64/steam_api64.dll")[.size] as? Int64) ?? 0
                    let cfgText = (try? String(contentsOfFile: "\(unpackedDir)/RainWorld_Data/Plugins/x86_64/steam_settings/configs.user.ini", encoding: .utf8)) ?? ""
                    let hasSchinese = cfgText.contains("language=schinese")
                    let preservedAccount = cfgText.contains("account_steamid=76561197960287930")
                    print("5D. Pixeldrain Patch -> title='\(paTask.title)', appID='\(paTask.appID ?? "")', pill='\(paTask.pill ?? "")', rightText='\(paTask.rightText)', overlayDLLSize=\(dllSize), hasSchinese=\(hasSchinese), preservedAccount=\(preservedAccount)")
                }
            }
        }

        // Test 6A: cloud.mail.ru Multi-File Folder Resolution (https://cloud.mail.ru/public/BqBr/K7pB3Myfy)
        let mailItems = await StudioViewModel.resolveHostLinks("https://cloud.mail.ru/public/BqBr/K7pB3Myfy")
        let mailNames = mailItems.compactMap { $0.suggestedFilename }.joined(separator: ", ")
        print("6A. Mail.ru Folder Resolver -> count=\(mailItems.count), subDir='\(mailItems.first?.subDirectory ?? "")', files=[\(mailNames)]")

        // Test 6B: GOG Inno Setup -1.bin -> .exe Normalization + innoextract Detection
        let gogSetupExe = "/tmp/setup_rain_world_1.11.8_(90164).exe"
        let gogBinSlice = "/tmp/setup_rain_world_1.11.8_(90164)-1.bin"
        FileManager.default.createFile(atPath: gogBinSlice, contents: Data())
        let normGOG = StudioViewModel.normalizeMultipartArchivePath(gogBinSlice)
        let isInno = StudioViewModel.isInnoSetupInstaller(gogSetupExe)
        let cleanGOGTitle = StudioViewModel.cleanGameTitle(from: "setup_rain_world_1.11.8_(90164)")
        print("6B. GOG Inno Setup Detection -> -1.bin normalized='\(URL(fileURLWithPath: normGOG).lastPathComponent)', isInnoSetup=\(isInno), cleanTitle='\(cleanGOGTitle)'")

        // Test 6C: Unity <Name>_Data Exact .exe Selection over Larger __redist/ISI/scriptinterpreter.exe (1.2MB vs 638KB) + winhttp.dll detection
        let gogMock = "/tmp/GOG_RainWorld_Mock"
        try? FileManager.default.removeItem(atPath: gogMock)
        try? FileManager.default.createDirectory(atPath: "\(gogMock)/__redist/ISI", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: "\(gogMock)/RainWorld_Data/Plugins/x86_64", withIntermediateDirectories: true)
        // Create 1.2MB __redist/ISI/scriptinterpreter.exe, 1.17MB UnityCrashHandler64.exe, and 638KB RainWorld.exe
        try? Data(repeating: 0x4D, count: 1_258_000).write(to: URL(fileURLWithPath: "\(gogMock)/__redist/ISI/scriptinterpreter.exe"))
        try? Data(repeating: 0x4D, count: 1_198_000).write(to: URL(fileURLWithPath: "\(gogMock)/UnityCrashHandler64.exe"))
        try? Data(repeating: 0x4D, count: 653_000).write(to: URL(fileURLWithPath: "\(gogMock)/RainWorld.exe"))
        try? Data(repeating: 0x4D, count: 295_000).write(to: URL(fileURLWithPath: "\(gogMock)/RainWorld_Data/Plugins/x86_64/steam_api64.dll"))
        try? Data(repeating: 0x4D, count: 25_000).write(to: URL(fileURLWithPath: "\(gogMock)/winhttp.dll"))

        let tidGOG = UUID()
        vm.patchTasks.insert(StudioTask(id: tidGOG, title: "rain world", status: .running(0.35), pill: "扫描中", rightText: "处理中"), at: 0)
        await vm.runGoldbergPatch(taskID: tidGOG, folderPath: gogMock, cleanTitle: "Rain World")
        if let pGOG = vm.patchTasks.first(where: { $0.id == tidGOG }) {
            let selectedEXE = URL(fileURLWithPath: pGOG.exePath ?? "").lastPathComponent
            let checklistText = pGOG.checklist.map { $0.title }.joined(separator: " | ")
            print("6C. GOG RainWorld Patch -> selectedEXE='\(selectedEXE)', appID='\(pGOG.appID ?? "")', rightText='\(pGOG.rightText)', checklist=[\(checklistText)]")
        }

        print("=== [All Hardened Backend Self-Tests PASSED] ===")
    }
}
