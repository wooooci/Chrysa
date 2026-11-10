import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - ViewModel & Full Backend Engine (Download / Unpack / Patch)
@MainActor
final class StudioViewModel: ObservableObject {
    @Published var activeTab: StudioTab = .download
    @Published var settingsCategory: SettingsCategory = .appearance
    @Published var autoRelay: Bool = true
    @Published var urlInput: String = ""
    @Published var showPasswordPopover: Bool = false
    @Published var newPasswordInput: String = ""
    @Published var showArchived: Bool = false

    @Published var editingTask: StudioTask? = nil
    @Published var editTitleInput: String = ""
    @Published var editPathOrURLInput: String = ""

    @Published var selectedIconID: String = "dark_nebula"
    @Published var selectedIconVariant: String = "B"

    @Published var downloadTasks: [StudioTask] = []
    @Published var unpackTasks: [StudioTask] = []
    @Published var patchTasks: [StudioTask] = []
    @Published var logs: [LogEntry] = []
    @Published var passwords: [String] = []

    var activeProcesses: [UUID: Process] = [:]
    var lastPrintedPctByTask: [UUID: Int] = [:]
    var cancelledTaskIDs: Set<UUID> = []

    private let passwordStorageKey = "Chrysa.PasswordDictionary.v1"
    private let iconIDStorageKey = "Chrysa.SelectedIconID.v1"
    private let iconVariantStorageKey = "Chrysa.SelectedIconVariant.v1"

    let iconOptions: [AppIconOption] = [
        AppIconOption(id: "cultured_prussian", title: "白底 3 · 学院普鲁士蓝", subtitle: "雾银浅蓝 ➔ 学院钴蓝 ➔ 普鲁士皇家深蓝", category: "白瓷底系列"),
        AppIconOption(id: "nordic_sage",       title: "白底 4 · 北欧莫兰迪冷杉", subtitle: "鼠尾草灰绿 ➔ 莫兰迪青松 ➔ 北欧深冷杉墨绿", category: "白瓷底系列"),
        AppIconOption(id: "w6_burgundy",       title: "白底 6A · 暖砂陶土与勃艮第", subtitle: "香槟暖砂 ➔ 赤陶红棕 ➔ 陈年勃艮第酒红棕", category: "白瓷底系列"),
        AppIconOption(id: "dark_nebula",       title: "黑底 1 · 曜石星云紫青", subtitle: "深空曜石 + 暮光紫 ➔ 电光冰蓝 ➔ 纯白雪光", category: "曜石黑底系列"),
        AppIconOption(id: "dark_terracotta_gold", title: "黑底 2 · 曜石黑金与赤陶", subtitle: "暖曜石黑 + 赤陶红棕 ➔ 干邑流金 ➔ 暖香槟钛白", category: "曜石黑底系列"),
        AppIconOption(id: "dark_emerald_mint", title: "黑底 3 · 曜石极光翡翠", subtitle: "深空曜石 + 北欧冷杉绿 ➔ 极光薄荷青 ➔ 冰川纯白", category: "曜石黑底系列")
    ]

    private let defaultPasswords = [
        "cs.rin.ru",
        "csrin.org",
        "steamrip.com",
        "www.ovagames.com",
        "online-fix.me",
        "elenemigos.com",
        "elamigos",
        "fitgirl",
        "gog",
        "123456"
    ]

    init(seedDemoData: Bool = false) {
        if let saved = UserDefaults.standard.stringArray(forKey: passwordStorageKey), !saved.isEmpty {
            self.passwords = saved
        } else if let legacy = UserDefaults.standard.stringArray(forKey: "SteamFlow.PasswordDictionary.v1"), !legacy.isEmpty {
            self.passwords = legacy
            UserDefaults.standard.set(legacy, forKey: passwordStorageKey)
        } else {
            self.passwords = defaultPasswords
            UserDefaults.standard.set(defaultPasswords, forKey: passwordStorageKey)
        }

        if let savedIcon = UserDefaults.standard.string(forKey: iconIDStorageKey) ?? UserDefaults.standard.string(forKey: "SteamFlow.SelectedIconID.v1"),
           iconOptions.contains(where: { $0.id == savedIcon }) {
            self.selectedIconID = savedIcon
        }
        if let savedVar = UserDefaults.standard.string(forKey: iconVariantStorageKey) ?? UserDefaults.standard.string(forKey: "SteamFlow.SelectedIconVariant.v1"),
           (savedVar == "A" || savedVar == "B") {
            self.selectedIconVariant = savedVar
        }

        if seedDemoData {
            seedShowcaseState()
        } else {
            appendLog("daemon ▸ 引擎就绪 (aria2c + 7zz + gbe_fork 双保险补丁)", highlight: false)
            scanExistingCrossOverGames()
            applyAppIcon(id: selectedIconID, variant: selectedIconVariant, silent: true)
        }
    }

    func iconPreviewPath(id: String, variant: String) -> String {
        let bundleIcons = (Bundle.main.bundlePath as NSString).appendingPathComponent("Contents/Resources/Icons/\(id)_\(variant).png")
        if FileManager.default.fileExists(atPath: bundleIcons) {
            return bundleIcons
        }
        let fallback = ("~/Applications/Chrysa.app/Contents/Resources/Icons/\(id)_\(variant).png" as NSString).expandingTildeInPath
        return fallback
    }

    func applyAppIcon(id: String, variant: String, silent: Bool = false) {
        selectedIconID = id
        selectedIconVariant = variant
        UserDefaults.standard.set(id, forKey: iconIDStorageKey)
        UserDefaults.standard.set(variant, forKey: iconVariantStorageKey)

        let appBundlePath: String = {
            if Bundle.main.bundlePath.hasSuffix(".app") {
                return Bundle.main.bundlePath
            }
            return ("~/Applications/Chrysa.app" as NSString).expandingTildeInPath
        }()

        let icnsPath = (appBundlePath as NSString).appendingPathComponent("Contents/Resources/Icons/\(id)_\(variant).icns")
        let targetAppIconPath = (appBundlePath as NSString).appendingPathComponent("Contents/Resources/AppIcon.icns")

        if FileManager.default.fileExists(atPath: icnsPath),
           let img = NSImage(contentsOfFile: icnsPath) {
            NSApplication.shared.applicationIconImage = img
            try? FileManager.default.removeItem(atPath: targetAppIconPath)
            try? FileManager.default.copyItem(atPath: icnsPath, toPath: targetAppIconPath)
            NSWorkspace.shared.setIcon(img, forFile: appBundlePath, options: [])
            if !silent, let opt = iconOptions.first(where: { $0.id == id }) {
                appendLog("icon ▸ 已切换应用图标: \(opt.title) (微调版 \(variant))", highlight: true)
            }
        }
    }

    func seedShowcaseState() {
        downloadTasks = [
            StudioTask(title: "Esoteric_Ebb_Build_1402.7z", status: .running(0.68), pill: "48.4 MB/s", rightText: "1.47 / 2.16 GB"),
            StudioTask(title: "Order_of_the_Sinking_Star_v1.02.rar", status: .running(0.28), pill: "19.2 MB/s", rightText: "0.27 / 0.95 GB"),
            StudioTask(title: "Animal_Well_v1.0.7z", status: .done, pill: nil, rightText: "38.4 MB")
        ]
        unpackTasks = [
            StudioTask(title: "Esoteric_Ebb_Build_1402.7z", status: .locked(0.55), pill: "试密中", rightText: "2.16 GB"),
            StudioTask(title: "Animal_Well_v1.0.7z", status: .done, pill: "已解锁", rightText: "38.4 MB")
        ]
        patchTasks = [
            StudioTask(
                title: "Esoteric Ebb",
                status: .done,
                pill: "Goldberg x64",
                rightText: "▶ 启动",
                appID: "2057760",
                expanded: true,
                checklist: [
                    CheckItem(title: "steam_api64.dll ➔ Goldberg (2057760) · 简中", isChecked: true),
                    CheckItem(title: "CrossOver 容器环境 (DXMT + MSync)", isChecked: true)
                ]
            ),
            StudioTask(
                title: "Order of the Sinking Star",
                status: .done,
                pill: "PE 补全 x64",
                rightText: "▶ 启动",
                appID: "499170",
                expanded: false,
                checklist: [
                    CheckItem(title: "steam_api64.dll ➔ Goldberg (499170) · 简中", isChecked: true),
                    CheckItem(title: "CrossOver 容器环境 (D3DMetal + MSync)", isChecked: true)
                ]
            )
        ]
        appendLog("aria2c ▸ 嗅探直链 Esoteric_Ebb_Build_1402.7z (16 线程并发)", highlight: false)
        appendLog("7zz ▸ 密码本第 #01 项静默命中，自动修复 chmod/xattr 权限", highlight: true)
        appendLog("gbe_fork ▸ 已注入 Goldberg x64 补丁并写入 language=schinese", highlight: false)
    }

    private func scanExistingCrossOverGames() {
        let bottlesPath = ("~/Library/Application Support/CrossOver/Bottles" as NSString).expandingTildeInPath
        let candidates: [(String, String, String, String, String)] = [
            (
                "Order of the Sinking Star",
                "\(bottlesPath)/Order of the Sinking Star/drive_c/Order of the Sinking Star",
                "\(bottlesPath)/Order of the Sinking Star/drive_c/Order of the Sinking Star/sinking_star.exe",
                "499170",
                "PE 补全 x64"
            ),
            (
                "Esoteric Ebb",
                "\(bottlesPath)/Esoteric Ebb/drive_c/Esoteric Ebb",
                "\(bottlesPath)/Esoteric Ebb/drive_c/Esoteric Ebb/Esoteric Ebb.exe",
                "2057760",
                "Goldberg x64"
            )
        ]
        var first = true
        for (name, dir, exe, appid, pill) in candidates {
            if FileManager.default.fileExists(atPath: dir) {
                patchTasks.append(
                    StudioTask(
                        title: name,
                        status: .done,
                        pill: pill,
                        rightText: "▶ 启动",
                        localPath: dir,
                        exePath: exe,
                        appID: appid,
                        expanded: first,
                        checklist: [
                            CheckItem(title: "steam_api64.dll ➔ Goldberg (\(appid)) · 简中", isChecked: true),
                            CheckItem(title: "CrossOver 容器环境 (D3DMetal + MSync)", isChecked: true)
                        ]
                    )
                )
                first = false
            }
        }
    }

    func appendLog(_ text: String, highlight: Bool = false) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let tStr = formatter.string(from: Date())
        let entry = LogEntry(time: tStr, message: text, highlight: highlight)
        logs.append(entry)
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
        print("[\(tStr)] \(text)")
        fflush(stdout)
    }

    func clearLogs() {
        logs.removeAll()
    }

    func addPassword() {
        let trimmed = newPasswordInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !passwords.contains(trimmed) {
            passwords.insert(trimmed, at: 0)
            UserDefaults.standard.set(passwords, forKey: passwordStorageKey)
            appendLog("dict ▸ 已向密码本新增 1 条掩码密码 (共 \(passwords.count) 组)", highlight: true)
        }
        newPasswordInput = ""
    }

    func removePassword(at index: Int) {
        guard passwords.indices.contains(index) else { return }
        passwords.remove(at: index)
        UserDefaults.standard.set(passwords, forKey: passwordStorageKey)
    }

    // MARK: - Task Management (Edit / Archive / Delete / Retry / Stop / Batch)
    func stopTask(_ task: StudioTask) {
        cancelledTaskIDs.insert(task.id)
        if let proc = activeProcesses[task.id] {
            if proc.isRunning {
                proc.terminate()
            }
            activeProcesses.removeValue(forKey: task.id)
        }
        if let i = downloadTasks.firstIndex(where: { $0.id == task.id }) {
            downloadTasks[i].status = .failed
            downloadTasks[i].pill = "已停止"
        } else if let i = unpackTasks.firstIndex(where: { $0.id == task.id }) {
            unpackTasks[i].status = .failed
            unpackTasks[i].pill = "已停止"
        } else if let i = patchTasks.firstIndex(where: { $0.id == task.id }) {
            patchTasks[i].status = .failed
            patchTasks[i].pill = "已停止"
        }
        appendLog("task ▸ 已终止任务: \(task.title)", highlight: false)
    }

    func archiveTask(_ task: StudioTask) {
        if let proc = activeProcesses[task.id], proc.isRunning {
            cancelledTaskIDs.insert(task.id)
            proc.terminate()
            activeProcesses.removeValue(forKey: task.id)
        }
        if let i = downloadTasks.firstIndex(where: { $0.id == task.id }) {
            downloadTasks[i].isArchived.toggle()
            let stateStr = downloadTasks[i].isArchived ? "已归档" : "已恢复"
            appendLog("archive ▸ \(stateStr)下载项目: \(task.title)", highlight: false)
        } else if let i = unpackTasks.firstIndex(where: { $0.id == task.id }) {
            unpackTasks[i].isArchived.toggle()
            let stateStr = unpackTasks[i].isArchived ? "已归档" : "已恢复"
            appendLog("archive ▸ \(stateStr)解压项目: \(task.title)", highlight: false)
        } else if let i = patchTasks.firstIndex(where: { $0.id == task.id }) {
            patchTasks[i].isArchived.toggle()
            let stateStr = patchTasks[i].isArchived ? "已归档" : "已恢复"
            appendLog("archive ▸ \(stateStr)补丁项目: \(task.title)", highlight: false)
        }
    }

    func deleteTask(_ task: StudioTask, deleteLocalFile: Bool = false) {
        cancelledTaskIDs.insert(task.id)
        if let proc = activeProcesses[task.id] {
            if proc.isRunning {
                proc.terminate()
            }
            activeProcesses.removeValue(forKey: task.id)
        }
        if deleteLocalFile, let local = task.localPath, !local.isEmpty {
            try? FileManager.default.removeItem(atPath: local)
            try? FileManager.default.removeItem(atPath: local + ".aria2")
            appendLog("delete ▸ 已删除记录及本地文件: \((local as NSString).lastPathComponent)", highlight: true)
        } else {
            appendLog("delete ▸ 已移除项目记录: \(task.title)", highlight: false)
        }
        downloadTasks.removeAll { $0.id == task.id }
        unpackTasks.removeAll { $0.id == task.id }
        patchTasks.removeAll { $0.id == task.id }
    }

    func retryTask(_ task: StudioTask) {
        cancelledTaskIDs.remove(task.id)
        if let i = downloadTasks.firstIndex(where: { $0.id == task.id }) {
            let src = downloadTasks[i].sourceURL ?? downloadTasks[i].title
            downloadTasks.remove(at: i)
            startDownload(urlString: src)
        } else if let i = unpackTasks.firstIndex(where: { $0.id == task.id }) {
            if let path = unpackTasks[i].localPath, !path.isEmpty {
                unpackTasks.remove(at: i)
                startUnpack(filePath: path)
            }
        } else if let i = patchTasks.firstIndex(where: { $0.id == task.id }) {
            if let path = patchTasks[i].localPath, !path.isEmpty {
                patchTasks.remove(at: i)
                startPatch(folderPath: path)
            }
        }
    }

    func beginEditTask(_ task: StudioTask) {
        editingTask = task
        editTitleInput = task.title
        editPathOrURLInput = task.sourceURL ?? task.localPath ?? ""
    }

    func saveEditedTask(andRetry: Bool) {
        guard let task = editingTask else { return }
        let newTitle = editTitleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTarget = editPathOrURLInput.trimmingCharacters(in: .whitespacesAndNewlines)

        if let i = downloadTasks.firstIndex(where: { $0.id == task.id }) {
            if !newTitle.isEmpty { downloadTasks[i].title = newTitle }
            if !newTarget.isEmpty { downloadTasks[i].sourceURL = newTarget }
            let updated = downloadTasks[i]
            editingTask = nil
            appendLog("edit ▸ 已更新下载项目: \(updated.title)", highlight: false)
            if andRetry { retryTask(updated) }
        } else if let i = unpackTasks.firstIndex(where: { $0.id == task.id }) {
            if !newTitle.isEmpty { unpackTasks[i].title = newTitle }
            if !newTarget.isEmpty { unpackTasks[i].localPath = newTarget }
            let updated = unpackTasks[i]
            editingTask = nil
            appendLog("edit ▸ 已更新解压项目: \(updated.title)", highlight: false)
            if andRetry { retryTask(updated) }
        } else if let i = patchTasks.firstIndex(where: { $0.id == task.id }) {
            if !newTitle.isEmpty { patchTasks[i].title = newTitle }
            if !newTarget.isEmpty { patchTasks[i].localPath = newTarget }
            let updated = patchTasks[i]
            editingTask = nil
            appendLog("edit ▸ 已更新补丁项目: \(updated.title)", highlight: false)
            if andRetry { retryTask(updated) }
        } else {
            editingTask = nil
        }
    }

    func archiveAllCompletedInActiveTab() {
        switch activeTab {
        case .download:
            for i in downloadTasks.indices where downloadTasks[i].status == .done {
                downloadTasks[i].isArchived = true
            }
        case .unpack:
            for i in unpackTasks.indices where unpackTasks[i].status == .done {
                unpackTasks[i].isArchived = true
            }
        case .patch:
            for i in patchTasks.indices where patchTasks[i].status == .done {
                patchTasks[i].isArchived = true
            }
        case .settings:
            break
        }
        appendLog("archive ▸ 已归档当前列表所有已完成项目", highlight: false)
    }

    func deleteAllFailedInActiveTab() {
        switch activeTab {
        case .download:
            downloadTasks.removeAll { $0.status == .failed }
        case .unpack:
            unpackTasks.removeAll { $0.status == .failed }
        case .patch:
            patchTasks.removeAll { $0.status == .failed }
        case .settings:
            break
        }
        appendLog("clean ▸ 已清理当前列表所有失败项目", highlight: false)
    }

    func retryAllFailedInActiveTab() {
        switch activeTab {
        case .download:
            let failed = downloadTasks.filter { $0.status == .failed }
            for t in failed { retryTask(t) }
        case .unpack:
            let failed = unpackTasks.filter { $0.status == .failed }
            for t in failed { retryTask(t) }
        case .patch:
            let failed = patchTasks.filter { $0.status == .failed }
            for t in failed { retryTask(t) }
        case .settings:
            break
        }
    }

    func clearAllInActiveTab() {
        switch activeTab {
        case .download:
            for t in downloadTasks { stopTask(t) }
            downloadTasks.removeAll()
        case .unpack:
            for t in unpackTasks { stopTask(t) }
            unpackTasks.removeAll()
        case .patch:
            patchTasks.removeAll()
        case .settings:
            break
        }
        appendLog("clean ▸ 已清空当前列表", highlight: false)
    }

    func pasteFromClipboardToInput() {
        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !clip.isEmpty {
            urlInput = clip
            appendLog("clipboard ▸ 已从剪贴板粘贴链接", highlight: false)
        }
    }

}
