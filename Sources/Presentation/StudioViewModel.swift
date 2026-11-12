import ChrysaCore
import ChrysaApplication
import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
package final class StudioViewModel: ObservableObject {
    @Published package var activeTab: StudioTab = .download
    @Published package var settingsCategory: SettingsCategory = .appearance
    @Published package var urlInput: String = ""
    @Published package var newPasswordInput: String = ""
    @Published package var showArchived: Bool = false

    @Published package var editingTask: StudioTask? = nil
    @Published package var editTitleInput: String = ""
    @Published package var editPathOrURLInput: String = ""

    @Published package private(set) var jobs: [Job] = []
    @Published package var logs: [LogEntry] = []

    package let settingsStore: AppSettingsStore
    package let taskStore: any LegacyTaskLoading
    package let coordinator: PipelineCoordinator

    private var cancellables = Set<AnyCancellable>()
    private var eventTask: Task<Void, Never>?
    private var restorationTask: Task<Void, Never>?
    private var bottleScanTask: Task<Void, Never>?
    private var canWriteJobs = true

    deinit {
        eventTask?.cancel()
        restorationTask?.cancel()
        bottleScanTask?.cancel()
    }

    package var iconOptions: [AppIconOption] { settingsStore.iconOptions }
    package var passwords: [String] { settingsStore.settings.passwords }
    package var autoRelay: Bool {
        get { settingsStore.settings.autoRelay }
        set { settingsStore.settings.autoRelay = newValue }
    }

    package init(
        seedDemoData: Bool = false,
        inMemoryOnly: Bool = false,
        settingsStore: AppSettingsStore,
        taskStore: any LegacyTaskLoading,
        coordinator: PipelineCoordinator
    ) {
        let ephemeral = seedDemoData || inMemoryOnly
        let resolvedSettings = settingsStore
        let resolvedTaskStore = taskStore
        let resolvedCoordinator = coordinator

        self.settingsStore = resolvedSettings
        self.taskStore = resolvedTaskStore
        self.coordinator = resolvedCoordinator
        eventTask = Task { [weak self, events = resolvedCoordinator.events] in
            for await event in events {
                self?.receive(event)
            }
        }

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
            canWriteJobs = false
            appendLog("daemon ▸ 引擎就绪 (aria2c + 7zz + gbe_fork + CrossOver 动态扫描)", highlight: false)
            _ = resolvedSettings.applyAppIcon(
                id: resolvedSettings.settings.selectedIconID,
                variant: resolvedSettings.settings.selectedIconVariant
            )
            restorationTask = Task { [weak self, coordinator = resolvedCoordinator, legacyStore = resolvedTaskStore] in
                let result = await coordinator.loadJobs(migratingLegacyStore: legacyStore)
                await self?.restorePersistedTasks(result)
            }
        }
    }

    private func restorePersistedTasks(_ loadResult: JobStoreLoadResult) async {
        let restoredJobs: [Job]
        switch loadResult {
        case .loaded(let jobs), .recovered(let jobs):
            restoredJobs = jobs
            canWriteJobs = true
        case .migrated(let jobs):
            restoredJobs = jobs
            canWriteJobs = true
            appendLog("persistence ▸ 已从旧任务记录迁移 \(jobs.count) 项", highlight: false)
        case .migrationPending(let jobs):
            restoredJobs = jobs
            canWriteJobs = true
            appendLog("persistence ▸ 已载入 \(jobs.count) 项旧记录，迁移写入失败，后续保存时将重试", highlight: true)
        case .missing, .corrupt:
            restoredJobs = []
            canWriteJobs = true
        case .unsupported:
            canWriteJobs = false
            let legacy = await taskStore.load()
            restoredJobs = legacy.downloadTasks.map { Job.fromLegacy($0, kind: .download) }
                + legacy.unpackTasks.map { Job.fromLegacy($0, kind: .unpack) }
                + legacy.patchTasks.map { Job.fromLegacy($0, kind: .patch) }
            appendLog("persistence ▸ 任务档案由较新版本创建，当前仅显示可读的旧记录", highlight: true)
        }

        jobs = restoredJobs
        rescanCrossOverBottles()
    }

    package func rescanCrossOverBottles() {
        let bottlesDirectory = settingsStore.settings.bottlesDirectory
        bottleScanTask?.cancel()
        bottleScanTask = Task { [coordinator] in
            await coordinator.rescanCrossOverBottles(bottlesDirectory: bottlesDirectory)
        }
    }

    package func jobs(of kind: JobKind) -> [Job] {
        jobs.filter { $0.kind == kind }
    }

    package func tasks(for kind: JobKind) -> [StudioTask] {
        jobs(of: kind).map { $0.legacyTask() }
    }

    package func task(for id: UUID) -> StudioTask? {
        jobs.first(where: { $0.id == id })?.legacyTask()
    }

    package func flushTasksImmediately() async {
        await restorationTask?.value
        bottleScanTask?.cancel()
        bottleScanTask = nil
        guard canWriteJobs else { return }
        await coordinator.flushJobStoreWrites()
    }

    private func receive(_ event: PipelineEvent) {
        switch event {
        case .jobUpdated(let job):
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index] = job
            } else {
                jobs.append(job)
            }
            jobs.sort(by: Self.jobOrder)
        case .jobRemoved(let id):
            jobs.removeAll { $0.id == id }
        case .log(let message, let highlight):
            appendLog(message, highlight: highlight)
        }
    }

    private static func jobOrder(_ lhs: Job, _ rhs: Job) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.listPosition != rhs.listPosition { return lhs.listPosition < rhs.listPosition }
        if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
        return lhs.createdAt > rhs.createdAt
    }

    // MARK: - Settings Intents
    package func selectAppIcon(id: String, variant: String? = nil) {
        let targetVariant = variant ?? settingsStore.settings.selectedIconVariant
        if let opt = settingsStore.applyAppIcon(id: id, variant: targetVariant) {
            appendLog("icon ▸ 已切换应用图标: \(opt.title) (微调版 \(targetVariant))", highlight: true)
        }
    }

    package func iconPreviewPath(id: String, variant: String) -> String {
        settingsStore.iconPreviewPath(id: id, variant: variant)
    }

    package func toggleAutoRelay() {
        settingsStore.settings.autoRelay.toggle()
        appendLog("config ▸ 自动流转: \(settingsStore.settings.autoRelay ? "开启 (后台静默接力)" : "关闭")", highlight: false)
    }

    package func toggleDeleteArchiveAfterUnpack() {
        settingsStore.settings.deleteArchiveAfterUnpack.toggle()
        appendLog("config ▸ 解压后自动清理压缩包: \(settingsStore.settings.deleteArchiveAfterUnpack ? "开启" : "关闭")", highlight: false)
    }

    package func setConcurrentConnections(_ count: Int) {
        settingsStore.settings.maxConcurrentConnections = count
        appendLog("config ▸ 默认下载并发连接数已设为: \(count)", highlight: false)
    }

    package func setDefaultLanguage(_ lang: SteamLanguageOption) {
        settingsStore.settings.defaultLanguage = lang
        appendLog("config ▸ Goldberg 默认语言已设为: \(lang.rawValue) (\(lang.shortLabel))", highlight: false)
    }

    package func chooseDownloadDirectory() {
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

    package func resetDownloadDirectory() {
        settingsStore.settings.downloadDirectory = AppSettings.default.downloadDirectory
        appendLog("config ▸ 下载目录已恢复默认: ~/Downloads", highlight: false)
    }

    package func openDownloadDirectoryInFinder() {
        let dl = (settingsStore.settings.downloadDirectory as NSString).expandingTildeInPath
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dl)
    }

    package func chooseBottlesDirectory() {
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

    package func resetBottlesDirectory() {
        settingsStore.settings.bottlesDirectory = AppSettings.default.bottlesDirectory
        rescanCrossOverBottles()
    }

    package func openBottlesDirectoryInFinder() {
        let bottles = (settingsStore.settings.bottlesDirectory as NSString).expandingTildeInPath
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: bottles)
    }

    package func addPassword() {
        let trimmed = newPasswordInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !settingsStore.settings.passwords.contains(trimmed) {
            settingsStore.settings.passwords.insert(trimmed, at: 0)
            appendLog("dict ▸ 已向密码本新增 1 条掩码密码 (共 \(settingsStore.settings.passwords.count) 组)", highlight: true)
        }
        newPasswordInput = ""
    }

    package func removePassword(at index: Int) {
        guard settingsStore.settings.passwords.indices.contains(index) else { return }
        settingsStore.settings.passwords.remove(at: index)
    }

    // MARK: - Pipeline Entry Intents
    package func startDownloadFromInputOrClipboard() {
        let raw = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            urlInput = ""
            startDownload(urlString: coordinator.normalizeDownloadInput(raw) ?? raw)
            return
        }
        if let clip = NSPasteboard.general.string(forType: .string),
           let normalized = coordinator.normalizeDownloadInput(clip) {
            startDownload(urlString: normalized)
            return
        }
        pickFileForActiveTab()
    }

    package func startDownload(urlString: String) {
        coordinator.startDownload(urlString: urlString, settings: settingsStore.settings)
    }

    package func startUnpack(filePath: String) {
        coordinator.startUnpack(filePath: filePath, settings: settingsStore.settings)
    }

    package func startPatch(folderPath: String) {
        coordinator.startPatch(folderPath: folderPath, settings: settingsStore.settings)
    }

    package func launchGame(_ task: StudioTask) {
        guard let job = jobs.first(where: { $0.id == task.id }) else { return }
        coordinator.launchGame(job, settings: settingsStore.settings)
    }

    // MARK: - File Picker & Drag-and-Drop Routing
    package func pickFileForActiveTab() {
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

    package func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
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
        Task { [weak self, coordinator] in
            let input = await coordinator.resolveDroppedFile(url)
            guard let self else { return }
            switch input.kind {
            case .download:
                activeTab = .download
                startDownload(urlString: input.path)
            case .unpack:
                activeTab = .unpack
                startUnpack(filePath: input.path)
            case .patch:
                activeTab = .patch
                startPatch(folderPath: input.path)
            }
        }
    }

    // MARK: - Task Management (Stop / Archive / Delete / Retry / Edit / Batch)
    package func stopTask(_ task: StudioTask) {
        Task { await coordinator.cancelTask(task.id) }
        appendLog("task ▸ 已终止任务: \(task.title)", highlight: false)
    }

    package func archiveTask(_ task: StudioTask) {
        guard let job = jobs.first(where: { $0.id == task.id }) else { return }
        Task { await coordinator.updateJob(job.id, isArchived: !job.isArchived) }
        let type = Self.taskTypeName(job.kind)
        appendLog("archive ▸ \(job.isArchived ? "已恢复" : "已归档")\(type)项目: \(task.title)", highlight: false)
    }

    package func deleteTask(_ task: StudioTask, deleteLocalFile: Bool = false) {
        Task { [weak self] in
            guard let self else { return }
            await coordinator.removeJob(task.id)
            if deleteLocalFile, let local = task.localPath {
                do {
                    if try coordinator.deleteDownloadedFile(local, downloadDirectory: settingsStore.settings.downloadDirectory) {
                        appendLog("delete ▸ 已删除记录及本地文件: \(task.title)", highlight: true)
                    } else {
                        appendLog("warning ▸ 为避免误删，容器/目录或下载目录外路径未删除；仅移除记录", highlight: true)
                    }
                } catch {
                    appendLog("error ▸ 本地文件删除失败，已保留文件: \(error.localizedDescription)", highlight: true)
                }
            } else {
                appendLog("delete ▸ 已移除项目记录: \(task.title)", highlight: false)
            }
        }
    }

    package func retryTask(_ task: StudioTask) {
        guard let job = jobs.first(where: { $0.id == task.id }) else { return }
        Task {
            await coordinator.removeJob(job.id)
            retry(job)
        }
    }

    package func beginEditTask(_ task: StudioTask) {
        editingTask = task
        editTitleInput = task.title
        editPathOrURLInput = task.sourceURL ?? task.localPath ?? ""
    }

    package func saveEditedTask(andRetry: Bool) {
        guard let task = editingTask else { return }
        guard var job = jobs.first(where: { $0.id == task.id }) else {
            editingTask = nil
            return
        }
        let newTitle = editTitleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTarget = editPathOrURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newTitle.isEmpty { job.title = newTitle }
        if !newTarget.isEmpty {
            let artifactKind: ArtifactKind = job.kind == .download ? .remoteURL : job.kind == .unpack ? .file : .directory
            job.source = ArtifactRef(kind: artifactKind, value: newTarget)
        }
        editingTask = nil
        appendLog("edit ▸ 已更新\(Self.taskTypeName(job.kind))项目: \(job.title)", highlight: false)
        Task {
            await coordinator.updateJob(job.id, title: job.title, source: job.source)
            if andRetry {
                await coordinator.removeJob(job.id)
                retry(job)
            }
        }
    }

    package func archiveAllCompletedInActiveTab() {
        for job in activeJobs where job.status == .succeeded && !job.isArchived {
            Task { await coordinator.updateJob(job.id, isArchived: true) }
        }
        appendLog("archive ▸ 已归档当前列表所有已完成项目", highlight: false)
    }

    package func deleteAllFailedInActiveTab() {
        let failedIDs = activeJobs.filter { $0.status == .failed || $0.status == .cancelled }.map(\.id)
        Task { await coordinator.clearJobs(failedIDs) }
        appendLog("clean ▸ 已清理当前列表所有失败项目", highlight: false)
    }

    package func retryAllFailedInActiveTab() {
        for job in activeJobs where job.status == .failed || job.status == .cancelled {
            Task {
                await coordinator.removeJob(job.id)
                retry(job)
            }
        }
    }

    package func clearAllInActiveTab() {
        let ids = activeJobs.map(\.id)
        Task { await coordinator.clearJobs(ids) }
        appendLog("clean ▸ 已清空当前列表", highlight: false)
    }

    package func toggleExpanded(_ task: StudioTask) {
        guard let job = jobs.first(where: { $0.id == task.id }) else { return }
        Task { await coordinator.updateJob(job.id, expanded: !job.expanded) }
    }

    package func toggleChecklistItem(taskID: UUID, itemID: UUID) {
        guard let job = jobs.first(where: { $0.id == taskID }),
              var item = job.checklist.first(where: { $0.id == itemID }),
              let index = job.checklist.firstIndex(where: { $0.id == itemID }) else { return }
        var checklist = job.checklist
        item.isChecked.toggle()
        checklist[index] = item
        Task { await coordinator.updateJob(job.id, checklist: checklist) }
    }

    private var activeJobs: [Job] {
        switch activeTab {
        case .download: return jobs(of: .download)
        case .unpack: return jobs(of: .unpack)
        case .patch: return jobs(of: .patch)
        case .settings: return []
        }
    }

    private func retry(_ job: Job) {
        switch job.kind {
        case .download:
            startDownload(urlString: job.sourceURL ?? job.title)
        case .unpack:
            if let path = job.source?.value, !path.isEmpty { startUnpack(filePath: path) }
        case .patch:
            if let path = job.source?.value, !path.isEmpty { startPatch(folderPath: path) }
        }
    }

    private static func taskTypeName(_ kind: JobKind) -> String {
        switch kind {
        case .download: return "下载"
        case .unpack: return "解压"
        case .patch: return "补丁"
        }
    }

    package func pasteFromClipboardToInput() {
        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !clip.isEmpty {
            urlInput = clip
            appendLog("clipboard ▸ 已从剪贴板粘贴链接", highlight: false)
        }
    }

    // MARK: - Logging & Showcase Seed
    package func appendLog(_ text: String, highlight: Bool = false) {
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

    package func clearLogs() {
        logs.removeAll()
    }

    package func seedShowcaseState() {
        let downloadTasks = [
            StudioTask(title: "Esoteric_Ebb_Build_1402.7z", status: .running(0.68), pill: "48.4 MB/s", rightText: "1.47 / 2.16 GB"),
            StudioTask(title: "Order_of_the_Sinking_Star_v1.02.rar", status: .running(0.28), pill: "19.2 MB/s", rightText: "0.27 / 0.95 GB"),
            StudioTask(title: "Animal_Well_v1.0.7z", status: .done, pill: nil, rightText: "38.4 MB")
        ]
        let unpackTasks = [
            StudioTask(title: "Esoteric_Ebb_Build_1402.7z", status: .locked(0.55), pill: "试密中", rightText: "2.16 GB"),
            StudioTask(title: "Animal_Well_v1.0.7z", status: .done, pill: "已解锁", rightText: "38.4 MB")
        ]
        let patchTasks = [
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
        jobs = downloadTasks.map { Job.fromLegacy($0, kind: .download) }
            + unpackTasks.map { Job.fromLegacy($0, kind: .unpack) }
            + patchTasks.map { Job.fromLegacy($0, kind: .patch) }
        Task {
            for job in jobs { await coordinator.addJob(job) }
        }
        appendLog("aria2c ▸ 嗅探直链 Esoteric_Ebb_Build_1402.7z (16 线程并发)", highlight: false)
        appendLog("7zz ▸ 密码本第 #01 项静默命中，自动修复 chmod/xattr 权限", highlight: true)
        appendLog("gbe_fork ▸ 已注入 Goldberg x64 补丁并写入 language=schinese", highlight: false)
    }
}
