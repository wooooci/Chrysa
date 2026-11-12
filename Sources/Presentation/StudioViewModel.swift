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
    @Published package var isLogDrawerPresented: Bool = false
    @Published package var logModuleFilter: LogModule? = nil
    @Published package var logErrorsOnly: Bool = false
    @Published package var logSearchQuery: String = ""
    @Published package var hasUnreadErrorLogs: Bool = false
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
    package var themePalette: AppThemePalette { AppThemePalette.resolve(settings: settingsStore.settings) }
    package var accentColorMode: AccentColorMode {
        get { settingsStore.settings.accentColorMode }
        set { settingsStore.settings.accentColorMode = newValue }
    }
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
        } else if !ephemeral {
            canWriteJobs = false
            resolvedSettings.warmPreviewCache()
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
        case .migrationPending(let jobs):
            restoredJobs = jobs
            canWriteJobs = true
            appendLog(LogEntry(module: .patch, level: .warning, message: "persistence ▸ 旧任务迁移尚未完成，将在条件恢复后重试"))
        case .missing, .corrupt:
            restoredJobs = []
            canWriteJobs = true
        case .unsupported:
            canWriteJobs = false
            let legacy = await taskStore.load()
            restoredJobs = legacy.downloadTasks.map { Job.fromLegacy($0, kind: .download) }
                + legacy.unpackTasks.map { Job.fromLegacy($0, kind: .unpack) }
                + legacy.patchTasks.map { Job.fromLegacy($0, kind: .patch) }
            appendLog(LogEntry(module: .patch, level: .warning, message: "persistence ▸ 任务档案由较新版本创建，当前仅显示只读旧记录"))
        }

        jobs = restoredJobs
        let persistedLogs = restoredJobs.flatMap(\.logs)
        if !persistedLogs.isEmpty {
            logs = Array((persistedLogs + logs).suffix(300))
        }
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
        case .log(let entry):
            appendLog(entry)
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
        guard settingsStore.settings.selectedIconID != id || settingsStore.settings.selectedIconVariant != targetVariant else {
            return
        }
        _ = settingsStore.applyAppIcon(id: id, variant: targetVariant)
    }

    package func setAccentColorMode(_ mode: AccentColorMode) {
        guard settingsStore.settings.accentColorMode != mode else { return }
        settingsStore.settings.accentColorMode = mode
    }
    package func toggleFollowAppIconTheme() {
        let next: AccentColorMode = (settingsStore.settings.accentColorMode == .followAppIcon) ? .monochrome : .followAppIcon
        setAccentColorMode(next)
    }

    package func iconPreviewPath(id: String, variant: String) -> String {
        settingsStore.iconPreviewPath(id: id, variant: variant)
    }

    package func iconPreviewImage(id: String, variant: String) -> NSImage? {
        settingsStore.iconPreviewImage(id: id, variant: variant)
    }

    package func toggleAutoRelay() {
        settingsStore.settings.autoRelay.toggle()
    }

    package func toggleDeleteArchiveAfterUnpack() {
        settingsStore.settings.deleteArchiveAfterUnpack.toggle()
    }

    package func setConcurrentConnections(_ count: Int) {
        settingsStore.settings.maxConcurrentConnections = count
    }

    package func setDefaultLanguage(_ lang: SteamLanguageOption) {
        settingsStore.settings.defaultLanguage = lang
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
        }
    }

    package func resetDownloadDirectory() {
        settingsStore.settings.downloadDirectory = AppSettings.default.downloadDirectory
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
    }

    package func archiveTask(_ task: StudioTask) {
        guard let job = jobs.first(where: { $0.id == task.id }) else { return }
        Task { await coordinator.updateJob(job.id, isArchived: !job.isArchived) }
    }

    package func deleteTask(_ task: StudioTask, deleteLocalFile: Bool = false) {
        Task { [weak self] in
            guard let self else { return }
            await coordinator.removeJob(task.id)
            if deleteLocalFile, let local = task.localPath {
                do {
                    _ = try coordinator.deleteDownloadedFile(local, downloadDirectory: settingsStore.settings.downloadDirectory)
                } catch {
                    appendLog(LogEntry(
                        taskID: task.id,
                        module: .download,
                        level: .error,
                        message: "error ▸ 本地文件删除失败，已保留文件: \(error.localizedDescription)"
                    ))
                }
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
        if let job = jobs.first(where: { $0.id == task.id }) {
            switch job.kind {
            case .download:
                editPathOrURLInput = task.sourceURL ?? task.localPath ?? ""
            case .unpack, .patch:
                editPathOrURLInput = task.localPath ?? task.sourceURL ?? ""
            }
        } else {
            editPathOrURLInput = task.sourceURL ?? task.localPath ?? ""
        }
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
            let updatedRef = ArtifactRef(kind: artifactKind, value: newTarget)
            if job.kind == .download || job.source?.kind != .remoteURL {
                job.source = updatedRef
            }
            job.input = updatedRef
            if job.kind == .unpack && job.status == .succeeded {
                job.output = ArtifactRef(kind: .directory, value: newTarget)
            }
        }
        editingTask = nil
        Task {
            await coordinator.updateJob(job.id, title: job.title, source: job.source, input: job.input, output: job.output)
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
    }

    package func deleteAllFailedInActiveTab() {
        let failedIDs = activeJobs.filter { $0.status == .failed || $0.status == .cancelled }.map(\.id)
        Task { await coordinator.clearJobs(failedIDs) }
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
            startDownload(urlString: job.sourceURL ?? job.input?.value ?? job.title)
        case .unpack:
            let target = (job.input?.kind == .file ? job.input?.value : nil)
                ?? (job.source?.kind == .file ? job.source?.value : nil)
                ?? job.localPath
            if let path = target, !path.isEmpty { startUnpack(filePath: path) }
        case .patch:
            let target = (job.input?.kind == .directory ? job.input?.value : nil)
                ?? (job.source?.kind == .directory ? job.source?.value : nil)
                ?? job.localPath
            if let path = target, !path.isEmpty { startPatch(folderPath: path) }
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
        }
    }

    // MARK: - Structured Logging & Drawer Queries
    package func appendLog(_ entry: LogEntry) {
        logs.append(entry)
        if logs.count > 300 {
            logs.removeFirst(logs.count - 300)
        }
        if entry.level == .error && !isLogDrawerPresented {
            hasUnreadErrorLogs = true
        }
        print("[\(entry.time)] [\(entry.module.rawValue):\(entry.level.rawValue)] \(entry.message)")
    }

    package func appendLog(_ text: String, highlight: Bool = false) {
        let lower = text.lowercased()
        let level: LogLevel = (lower.hasPrefix("error") || lower.contains("失败") || lower.contains("异常"))
            ? .error
            : (lower.hasPrefix("warning") ? .warning : .info)
        appendLog(LogEntry(module: .patch, level: level, message: text))
    }

    package func logs(for taskID: UUID) -> [LogEntry] {
        if let jobLogs = jobs.first(where: { $0.id == taskID })?.logs, !jobLogs.isEmpty {
            return jobLogs
        }
        return logs.filter { $0.taskID == taskID }
    }

    package func rawErrorOutput(for taskID: UUID) -> String? {
        let chunks = logs(for: taskID).compactMap(\.rawOutput).filter { !$0.isEmpty }
        guard !chunks.isEmpty else { return nil }
        return chunks.joined(separator: "\n\n")
    }

    package func copyTaskLogs(taskID: UUID, includeRawOnly: Bool = false) {
        let taskLogs = logs(for: taskID)
        let rawText = rawErrorOutput(for: taskID)
        let output: String
        if includeRawOnly, let rawText {
            output = rawText
        } else {
            var lines = taskLogs.map { "[\($0.time)] \($0.message)" }
            if let rawText, !rawText.isEmpty {
                lines.append("\n--- Raw Output ---\n\(rawText)")
            }
            output = lines.joined(separator: "\n")
        }
        guard !output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }

    package var filteredGlobalLogs: [LogEntry] {
        let query = logSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return logs.filter { entry in
            if let mod = logModuleFilter, entry.module != mod { return false }
            if logErrorsOnly && entry.level != .error { return false }
            if !query.isEmpty {
                let matchMsg = entry.message.localizedCaseInsensitiveContains(query)
                let matchRaw = entry.rawOutput?.localizedCaseInsensitiveContains(query) == true
                if !matchMsg && !matchRaw { return false }
            }
            return true
        }
    }

    package func toggleLogDrawer() {
        isLogDrawerPresented.toggle()
        if isLogDrawerPresented {
            hasUnreadErrorLogs = false
        }
    }

    package func clearLogs() {
        logs.removeAll()
        hasUnreadErrorLogs = false
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
    }
}
