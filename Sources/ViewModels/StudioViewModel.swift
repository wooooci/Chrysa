import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class StudioViewModel: ObservableObject {
    @Published var activeTab: StudioTab = .download
    @Published var settingsCategory: SettingsCategory = .appearance
    @Published var urlInput: String = ""
    @Published var newPasswordInput: String = ""
    @Published var showArchived: Bool = false

    @Published var editingTask: StudioTask? = nil
    @Published var editTitleInput: String = ""
    @Published var editPathOrURLInput: String = ""

    @Published var downloadTasks: [StudioTask] = []
    @Published var unpackTasks: [StudioTask] = []
    @Published var patchTasks: [StudioTask] = []
    @Published var logs: [LogEntry] = []

    let settingsStore: AppSettingsStore
    let taskStore: TaskStore
    let coordinator: PipelineCoordinator

    private var cancellables = Set<AnyCancellable>()
    private var pendingSaveTask: Task<Void, Never>? = nil

    var iconOptions: [AppIconOption] { settingsStore.iconOptions }
    var passwords: [String] { settingsStore.settings.passwords }
    var autoRelay: Bool {
        get { settingsStore.settings.autoRelay }
        set { settingsStore.settings.autoRelay = newValue }
    }

    init(
        seedDemoData: Bool = false,
        inMemoryOnly: Bool = false,
        settingsStore: AppSettingsStore? = nil,
        taskStore: TaskStore? = nil,
        coordinator: PipelineCoordinator? = nil
    ) {
        let ephemeral = seedDemoData || inMemoryOnly
        let resolvedSettings = settingsStore ?? AppSettingsStore(inMemoryOnly: ephemeral)
        let resolvedTaskStore = taskStore ?? TaskStore(inMemoryOnly: ephemeral)
        let resolvedCoordinator = coordinator ?? PipelineCoordinator()

        self.settingsStore = resolvedSettings
        self.taskStore = resolvedTaskStore
        self.coordinator = resolvedCoordinator
        resolvedCoordinator.viewModel = self

        // Forward nested ObservableObject changes so Views observing `vm` refresh immediately when settings change
        resolvedSettings.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        if seedDemoData {
            seedShowcaseState()
        } else if ephemeral {
            appendLog("daemon ▸ 自检内存沙箱已就绪", highlight: false)
        } else {
            appendLog("daemon ▸ 引擎就绪 (aria2c + 7zz + gbe_fork + CrossOver 动态扫描)", highlight: false)
            _ = resolvedSettings.applyAppIcon(
                id: resolvedSettings.settings.selectedIconID,
                variant: resolvedSettings.settings.selectedIconVariant
            )
            Task { [weak self] in
                await self?.restorePersistedTasksAndScanBottles()
            }
        }
    }

    private func restorePersistedTasksAndScanBottles() async {
        let saved = await taskStore.load()
        self.downloadTasks = saved.downloadTasks
        self.unpackTasks = saved.unpackTasks

        var mergedPatchTasks = saved.patchTasks
        let bottlesDirectory = settingsStore.settings.bottlesDirectory
        let scannedBottles = await Task.detached(priority: .utility) {
            PatchAndBottleService.scanInstalledBottles(bottlesDirectory: bottlesDirectory)
        }.value
        for bottleTask in scannedBottles {
            let exists = mergedPatchTasks.contains {
                $0.title.caseInsensitiveCompare(bottleTask.title) == .orderedSame
                    || ($0.localPath != nil && $0.localPath == bottleTask.localPath)
            }
            if !exists {
                mergedPatchTasks.append(bottleTask)
            }
        }
        if !mergedPatchTasks.isEmpty && !mergedPatchTasks.contains(where: { $0.expanded }) {
            mergedPatchTasks[0].expanded = true
        }
        self.patchTasks = mergedPatchTasks
        scheduleTaskSave()
    }

    func rescanCrossOverBottles() {
        let bottlesDirectory = settingsStore.settings.bottlesDirectory
        Task { @MainActor [weak self] in
            let scanned = await Task.detached(priority: .utility) {
                PatchAndBottleService.scanInstalledBottles(bottlesDirectory: bottlesDirectory)
            }.value
            guard let self else { return }
            var addedCount = 0
            for bottleTask in scanned {
                let exists = self.patchTasks.contains {
                    $0.title.caseInsensitiveCompare(bottleTask.title) == .orderedSame
                        || ($0.localPath != nil && $0.localPath == bottleTask.localPath)
                }
                if !exists {
                    self.patchTasks.append(bottleTask)
                    addedCount += 1
                }
            }
            self.scheduleTaskSave()
            self.appendLog("crossover ▸ 容器目录扫描完成 (共识别 \(scanned.count) 款游戏，新增 \(addedCount) 款)", highlight: true)
        }
    }

    func scheduleTaskSave() {
        let snapshot = PersistedTaskSnapshot(
            downloadTasks: downloadTasks,
            unpackTasks: unpackTasks,
            patchTasks: patchTasks
        )
        pendingSaveTask?.cancel()
        let store = taskStore
        pendingSaveTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await store.save(snapshot)
        }
    }

    func flushTasksImmediately() async {
        pendingSaveTask?.cancel()
        let snapshot = PersistedTaskSnapshot(
            downloadTasks: downloadTasks,
            unpackTasks: unpackTasks,
            patchTasks: patchTasks
        )
        await taskStore.save(snapshot)
    }

    // MARK: - Settings Intents
    func selectAppIcon(id: String, variant: String? = nil) {
        let targetVariant = variant ?? settingsStore.settings.selectedIconVariant
        if let opt = settingsStore.applyAppIcon(id: id, variant: targetVariant) {
            appendLog("icon ▸ 已切换应用图标: \(opt.title) (微调版 \(targetVariant))", highlight: true)
        }
    }

    func iconPreviewPath(id: String, variant: String) -> String {
        settingsStore.iconPreviewPath(id: id, variant: variant)
    }

    func toggleAutoRelay() {
        settingsStore.settings.autoRelay.toggle()
        appendLog("config ▸ 自动流转: \(settingsStore.settings.autoRelay ? "开启 (后台静默接力)" : "关闭")", highlight: false)
    }

    func toggleDeleteArchiveAfterUnpack() {
        settingsStore.settings.deleteArchiveAfterUnpack.toggle()
        appendLog("config ▸ 解压后自动清理压缩包: \(settingsStore.settings.deleteArchiveAfterUnpack ? "开启" : "关闭")", highlight: false)
    }

    func setConcurrentConnections(_ count: Int) {
        settingsStore.settings.maxConcurrentConnections = count
        appendLog("config ▸ 默认下载并发连接数已设为: \(count)", highlight: false)
    }

    func setDefaultLanguage(_ lang: SteamLanguageOption) {
        settingsStore.settings.defaultLanguage = lang
        appendLog("config ▸ Goldberg 默认语言已设为: \(lang.rawValue) (\(lang.shortLabel))", highlight: false)
    }

    func chooseDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择默认下载保存目录"
        if panel.runModal() == .OK, let url = panel.url {
            settingsStore.settings.downloadDirectory = url.path
            appendLog("config ▸ 下载目录已更新为: \(settingsStore.settings.displayDownloadDirectory)", highlight: true)
        }
    }

    func resetDownloadDirectory() {
        settingsStore.settings.downloadDirectory = AppSettings.default.downloadDirectory
        appendLog("config ▸ 下载目录已恢复默认: ~/Downloads", highlight: false)
    }

    func openDownloadDirectoryInFinder() {
        let dl = (settingsStore.settings.downloadDirectory as NSString).expandingTildeInPath
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dl)
    }

    func chooseBottlesDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择 CrossOver 容器根目录 (Bottles)"
        if panel.runModal() == .OK, let url = panel.url {
            settingsStore.settings.bottlesDirectory = url.path
            appendLog("config ▸ 容器目录已更新为: \(settingsStore.settings.displayBottlesDirectory)", highlight: true)
            rescanCrossOverBottles()
        }
    }

    func resetBottlesDirectory() {
        settingsStore.settings.bottlesDirectory = AppSettings.default.bottlesDirectory
        rescanCrossOverBottles()
    }

    func openBottlesDirectoryInFinder() {
        let bottles = (settingsStore.settings.bottlesDirectory as NSString).expandingTildeInPath
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: bottles)
    }

    func addPassword() {
        let trimmed = newPasswordInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !settingsStore.settings.passwords.contains(trimmed) {
            settingsStore.settings.passwords.insert(trimmed, at: 0)
            appendLog("dict ▸ 已向密码本新增 1 条掩码密码 (共 \(settingsStore.settings.passwords.count) 组)", highlight: true)
        }
        newPasswordInput = ""
    }

    func removePassword(at index: Int) {
        guard settingsStore.settings.passwords.indices.contains(index) else { return }
        settingsStore.settings.passwords.remove(at: index)
    }

    // MARK: - Pipeline Entry Intents
    func startDownloadFromInputOrClipboard() {
        let raw = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            urlInput = ""
            coordinator.startDownload(urlString: HostResolverRegistry.normalizeDownloadInput(raw) ?? raw)
            return
        }
        if let clip = NSPasteboard.general.string(forType: .string),
           let normalized = HostResolverRegistry.normalizeDownloadInput(clip) {
            coordinator.startDownload(urlString: normalized)
            return
        }
        pickFileForActiveTab()
    }

    func startDownload(urlString: String) {
        coordinator.startDownload(urlString: urlString)
    }

    func startUnpack(filePath: String) {
        coordinator.startUnpack(filePath: filePath)
    }

    func startPatch(folderPath: String) {
        coordinator.startPatch(folderPath: folderPath)
    }

    func launchGame(_ task: StudioTask) {
        coordinator.launchGame(task)
    }

    // MARK: - File Picker & Drag-and-Drop Routing
    func pickFileForActiveTab() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        switch activeTab {
        case .download:
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.message = "选择种子文件 (.torrent) 或包含下载链接的文本"
            if panel.runModal() == .OK, let url = panel.url {
                startDownload(urlString: url.path)
            }
        case .unpack:
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.message = "选择需要解压的 .7z / .rar / .zip 压缩包"
            if panel.runModal() == .OK, let url = panel.url {
                startUnpack(filePath: url.path)
            }
        case .patch, .settings:
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.message = "选择游戏文件夹或主程序 .exe"
            if panel.runModal() == .OK, let url = panel.url {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                let folder = isDir.boolValue ? url.path : url.deletingLastPathComponent().path
                activeTab = .patch
                startPatch(folderPath: folder)
            }
        }
    }

    func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let fileURL = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        self.routeDroppedFile(url: fileURL)
                    }
                }
                return true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    if let text = item as? String {
                        Task { @MainActor in
                            self.activeTab = .download
                            self.startDownload(urlString: text)
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    private func routeDroppedFile(url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        if isDir.boolValue {
            if let items = try? FileManager.default.contentsOfDirectory(atPath: url.path),
               let archiveItem = items.sorted().first(where: { UnpackService.isArchiveFile($0) }) {
                let fullArchive = (url.path as NSString).appendingPathComponent(archiveItem)
                activeTab = .unpack
                startUnpack(filePath: fullArchive)
                return
            }
            activeTab = .patch
            startPatch(folderPath: url.path)
        } else if UnpackService.isArchiveFile(url.path) {
            activeTab = .unpack
            startUnpack(filePath: url.path)
        } else if url.pathExtension.lowercased() == "exe" {
            let path = url.path
            let parent = url.deletingLastPathComponent().path
            Task { @MainActor [weak self] in
                let isInstaller = await Task.detached(priority: .utility) {
                    UnpackService.isInnoSetupInstaller(path)
                }.value
                guard let self else { return }
                if isInstaller {
                    self.activeTab = .unpack
                    self.startUnpack(filePath: path)
                } else {
                    self.activeTab = .patch
                    self.startPatch(folderPath: parent)
                }
            }
        } else {
            activeTab = .download
            startDownload(urlString: url.path)
        }
    }

    // MARK: - Task Management (Stop / Archive / Delete / Retry / Edit / Batch)
    func stopTask(_ task: StudioTask) {
        coordinator.markTaskCancelled(task.id)
        Task { await ProcessSupervisor.shared.cancel(taskID: task.id) }
        if let i = downloadTasks.firstIndex(where: { $0.id == task.id }) {
            downloadTasks[i].status = .failed
            downloadTasks[i].pill = "已停止"
            downloadTasks[i].rightText = "已停止"
        } else if let i = unpackTasks.firstIndex(where: { $0.id == task.id }) {
            unpackTasks[i].status = .failed
            unpackTasks[i].pill = "已停止"
            unpackTasks[i].rightText = "已停止"
        } else if let i = patchTasks.firstIndex(where: { $0.id == task.id }) {
            patchTasks[i].status = .failed
            patchTasks[i].pill = "已停止"
            patchTasks[i].rightText = "已停止"
        }
        scheduleTaskSave()
        appendLog("task ▸ 已终止任务: \(task.title)", highlight: false)
    }

    func archiveTask(_ task: StudioTask) {
        Task { await ProcessSupervisor.shared.cancel(taskID: task.id) }
        if let i = downloadTasks.firstIndex(where: { $0.id == task.id }) {
            downloadTasks[i].isArchived.toggle()
            appendLog("archive ▸ \(downloadTasks[i].isArchived ? "已归档" : "已恢复")下载项目: \(task.title)", highlight: false)
        } else if let i = unpackTasks.firstIndex(where: { $0.id == task.id }) {
            unpackTasks[i].isArchived.toggle()
            appendLog("archive ▸ \(unpackTasks[i].isArchived ? "已归档" : "已恢复")解压项目: \(task.title)", highlight: false)
        } else if let i = patchTasks.firstIndex(where: { $0.id == task.id }) {
            patchTasks[i].isArchived.toggle()
            appendLog("archive ▸ \(patchTasks[i].isArchived ? "已归档" : "已恢复")补丁项目: \(task.title)", highlight: false)
        }
        scheduleTaskSave()
    }

    private func safeLocalFileURL(for path: String) -> URL? {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard !expandedPath.isEmpty else { return nil }
        guard let root = try? PathSafety.canonicalDirectory(settingsStore.settings.downloadDirectory) else { return nil }
        let candidate = URL(fileURLWithPath: expandedPath).standardizedFileURL
        guard let contained = PathSafety.containedURL(candidate, in: root),
              contained.path != root.path else { return nil }
        guard let values = try? contained.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }
        return contained
    }

    func deleteTask(_ task: StudioTask, deleteLocalFile: Bool = false) {
        coordinator.markTaskCancelled(task.id)
        Task { await ProcessSupervisor.shared.cancel(taskID: task.id) }
        if deleteLocalFile, let local = task.localPath, let target = safeLocalFileURL(for: local) {
            do {
                try FileManager.default.removeItem(at: target)
                if let sidecar = safeLocalFileURL(for: target.path + ".aria2") {
                    try? FileManager.default.removeItem(at: sidecar)
                }
                appendLog("delete ▸ 已删除记录及本地文件: \(target.lastPathComponent)", highlight: true)
            } catch {
                appendLog("error ▸ 本地文件删除失败，已保留文件: \(error.localizedDescription)", highlight: true)
            }
        } else if deleteLocalFile, task.localPath != nil {
            appendLog("warning ▸ 为避免误删，容器/目录或下载目录外路径未删除；仅移除记录", highlight: true)
        } else {
            appendLog("delete ▸ 已移除项目记录: \(task.title)", highlight: false)
        }
        downloadTasks.removeAll { $0.id == task.id }
        unpackTasks.removeAll { $0.id == task.id }
        patchTasks.removeAll { $0.id == task.id }
        scheduleTaskSave()
    }

    func retryTask(_ task: StudioTask) {
        Task { await ProcessSupervisor.shared.clearCancellation(for: task.id) }
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
            scheduleTaskSave()
            appendLog("edit ▸ 已更新下载项目: \(updated.title)", highlight: false)
            if andRetry { retryTask(updated) }
        } else if let i = unpackTasks.firstIndex(where: { $0.id == task.id }) {
            if !newTitle.isEmpty { unpackTasks[i].title = newTitle }
            if !newTarget.isEmpty { unpackTasks[i].localPath = newTarget }
            let updated = unpackTasks[i]
            editingTask = nil
            scheduleTaskSave()
            appendLog("edit ▸ 已更新解压项目: \(updated.title)", highlight: false)
            if andRetry { retryTask(updated) }
        } else if let i = patchTasks.firstIndex(where: { $0.id == task.id }) {
            if !newTitle.isEmpty { patchTasks[i].title = newTitle }
            if !newTarget.isEmpty { patchTasks[i].localPath = newTarget }
            let updated = patchTasks[i]
            editingTask = nil
            scheduleTaskSave()
            appendLog("edit ▸ 已更新补丁项目: \(updated.title)", highlight: false)
            if andRetry { retryTask(updated) }
        } else {
            editingTask = nil
        }
    }

    func archiveAllCompletedInActiveTab() {
        switch activeTab {
        case .download:
            for i in downloadTasks.indices where downloadTasks[i].status == .done { downloadTasks[i].isArchived = true }
        case .unpack:
            for i in unpackTasks.indices where unpackTasks[i].status == .done { unpackTasks[i].isArchived = true }
        case .patch:
            for i in patchTasks.indices where patchTasks[i].status == .done { patchTasks[i].isArchived = true }
        case .settings:
            break
        }
        scheduleTaskSave()
        appendLog("archive ▸ 已归档当前列表所有已完成项目", highlight: false)
    }

    func deleteAllFailedInActiveTab() {
        switch activeTab {
        case .download: downloadTasks.removeAll { $0.status == .failed }
        case .unpack:   unpackTasks.removeAll { $0.status == .failed }
        case .patch:    patchTasks.removeAll { $0.status == .failed }
        case .settings: break
        }
        scheduleTaskSave()
        appendLog("clean ▸ 已清理当前列表所有失败项目", highlight: false)
    }

    func retryAllFailedInActiveTab() {
        switch activeTab {
        case .download:
            for t in downloadTasks.filter({ $0.status == .failed }) { retryTask(t) }
        case .unpack:
            for t in unpackTasks.filter({ $0.status == .failed }) { retryTask(t) }
        case .patch:
            for t in patchTasks.filter({ $0.status == .failed }) { retryTask(t) }
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
            for t in patchTasks { stopTask(t) }
            patchTasks.removeAll()
        case .settings:
            break
        }
        scheduleTaskSave()
        appendLog("clean ▸ 已清空当前列表", highlight: false)
    }

    func pasteFromClipboardToInput() {
        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !clip.isEmpty {
            urlInput = clip
            appendLog("clipboard ▸ 已从剪贴板粘贴链接", highlight: false)
        }
    }

    // MARK: - Logging & Showcase Seed
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
}
