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
    @Published package var editingLaunchGame: LaunchGame? = nil
    @Published package var editTitleInput: String = ""
    @Published package var editPathOrURLInput: String = ""
    @Published package private(set) var jobs: [Job] = []
    @Published package private(set) var launchGames: [LaunchGame] = []
    @Published package private(set) var launchGameIcons: [UUID: NSImage] = [:]
    @Published package var launchSearchQuery: String = ""
    @Published package var launchSortOrder: LaunchSortOrder = .lastPlayed
    @Published package var launchErrorAlert: LaunchErrorNotice? = nil
    @Published package var logs: [LogEntry] = []
    @Published package var isLogDrawerPresented: Bool = false
    @Published package var logModuleFilter: LogModule? = nil
    @Published package var logErrorsOnly: Bool = false
    @Published package var logSearchQuery: String = ""
    @Published package var hasUnreadErrorLogs: Bool = false

    package struct LaunchErrorNotice: Identifiable, Equatable {
        package let id = UUID()
        package let title: String
        package let message: String
    }
    package let settingsStore: AppSettingsStore
    package let taskStore: any LegacyTaskLoading
    package let coordinator: PipelineCoordinator
    private var cancellables = Set<AnyCancellable>()
    private var eventTask: Task<Void, Never>?
    private var restorationTask: Task<Void, Never>?
    private var bottleScanTask: Task<Void, Never>?
    private var attemptedIconSignatureByID: [UUID: String] = [:]
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
                _ = await coordinator.loadLaunchLibrary()
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

        if canWriteJobs {
            await coordinator.migrateLegacyPatchEntriesToLaunchLibrary()
            jobs = await coordinator.jobStore.all()
        } else {
            jobs = restoredJobs
        }
        launchGames = await coordinator.gameLibrary.all()
        let persistedLogs = jobs.flatMap(\.logs)
        if !persistedLogs.isEmpty {
            logs = Array((persistedLogs + logs).suffix(300))
        }
        rescanCrossOverBottles()
    }

    package func rescanCrossOverBottles(includePreviouslyRemoved: Bool = false) {
        let bottlesDirectory = settingsStore.settings.bottlesDirectory
        bottleScanTask?.cancel()
        bottleScanTask = Task { [coordinator] in
            await coordinator.rescanCrossOverBottles(
                bottlesDirectory: bottlesDirectory,
                includePreviouslyRemoved: includePreviouslyRemoved
            )
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

    package var filteredAndSortedLaunchGames: [LaunchGame] {
        let query = launchSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty
            ? launchGames
            : launchGames.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return LaunchGame.sorted(filtered, by: launchSortOrder)
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
        case .launchGameUpdated(let game):
            if let index = launchGames.firstIndex(where: { $0.id == game.id }) {
                let old = launchGames[index]
                launchGames[index] = game
                if Self.launchGameIconSignature(for: old) != Self.launchGameIconSignature(for: game) {
                    attemptedIconSignatureByID.removeValue(forKey: game.id)
                    launchGameIcons.removeValue(forKey: game.id)
                }
            } else {
                launchGames.append(game)
            }
        case .launchGameRemoved(let id):
            launchGames.removeAll { $0.id == id }
            launchGameIcons.removeValue(forKey: id)
            attemptedIconSignatureByID.removeValue(forKey: id)
        case .launchFailed(_, let title, let message):
            launchErrorAlert = LaunchErrorNotice(title: title, message: message)
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

    package func setMaxConcurrentDownloads(_ count: Int) {
        settingsStore.settings.maxConcurrentDownloads = count
        coordinator.updateMaxConcurrentDownloads(settingsStore.settings.maxConcurrentDownloads)
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
            startDownload(urlString: raw)
            return
        }
        if let clip = NSPasteboard.general.string(forType: .string),
           coordinator.containsValidDownloadURL(clip) {
            startDownload(urlString: clip)
            return
        }
        pickFileForActiveTab()
    }

    package func startDownload(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasSuffix(".txt"),
           FileManager.default.fileExists(atPath: trimmed),
           let text = try? String(contentsOfFile: trimmed, encoding: .utf8) {
            coordinator.startDownloads(rawInput: text, settings: settingsStore.settings)
            return
        }
        coordinator.startDownloads(rawInput: urlString, settings: settingsStore.settings)
    }
    package func startUnpack(filePath: String) {
        coordinator.startUnpack(filePath: filePath, settings: settingsStore.settings)
    }

    package func startPatch(folderPath: String) {
        coordinator.startPatch(folderPath: folderPath, settings: settingsStore.settings)
    }

    package func launchGame(_ game: LaunchGame) {
        coordinator.launchGame(game, settings: settingsStore.settings)
    }

    package func removeLaunchGame(_ game: LaunchGame) {
        Task { await coordinator.removeLaunchGame(game.id) }
    }

    package func launchGameIcon(for game: LaunchGame) -> NSImage? {
        launchGameIcons[game.id]
    }

    package static func launchGameIconSignature(for game: LaunchGame) -> String {
        "\(game.exePath ?? "")|\(game.gameDirectory ?? "")|\(game.appID ?? "")|\(game.title)|\(game.iconPreference.rawValue)|\(game.customIconPath ?? "")|\(game.bottleName ?? "")"
    }

    package func loadLaunchGameIconIfNeeded(for game: LaunchGame) async {
        let signature = Self.launchGameIconSignature(for: game)
        if launchGameIcons[game.id] != nil || attemptedIconSignatureByID[game.id] == signature {
            return
        }
        attemptedIconSignatureByID[game.id] = signature
        guard let pngData = await coordinator.resolveLaunchGameIcon(game),
              let image = NSImage(data: pngData) else {
            return
        }
        image.size = NSSize(width: 22, height: 22)
        launchGameIcons[game.id] = image
    }

    package func beginEditingLaunchGame(_ game: LaunchGame) {
        editingLaunchGame = game
    }

    package func refreshLaunchGameIcon(_ game: LaunchGame) {
        launchGameIcons.removeValue(forKey: game.id)
        attemptedIconSignatureByID.removeValue(forKey: game.id)
        Task { [weak self] in
            guard let self else { return }
            await coordinator.invalidateLaunchGameIconCache(for: game)
            await loadLaunchGameIconIfNeeded(for: game)
        }
    }

    package func saveEditedLaunchGame(_ updated: LaunchGame, previousCustomIconPath: String?) {
        editingLaunchGame = nil
        launchGameIcons.removeValue(forKey: updated.id)
        attemptedIconSignatureByID.removeValue(forKey: updated.id)
        Task { [weak self] in
            guard let self else { return }
            if let saved = await coordinator.updateLaunchGame(updated, previousCustomIconPath: previousCustomIconPath) {
                await loadLaunchGameIconIfNeeded(for: saved)
            }
        }
    }

    package func saveCustomIcon(from url: URL, for gameID: UUID) async -> String? {
        await coordinator.saveCustomLaunchGameIcon(from: url, for: gameID)
    }

    package func pickCustomIconFile(for gameID: UUID) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var allowedTypes: [UTType] = [.image, .icns, .applicationBundle]
        if let exeType = UTType(filenameExtension: "exe") {
            allowedTypes.append(exeType)
        }
        if let icoType = UTType(filenameExtension: "ico") {
            allowedTypes.append(icoType)
        }
        panel.allowedContentTypes = allowedTypes
        panel.message = "选择自定义图标图片（PNG / JPG / ICNS）、.app 或 .exe"
        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        return await coordinator.saveCustomLaunchGameIcon(from: url, for: gameID)
    }

    package func chooseLaunchExecutable(initialPath: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var allowedTypes: [UTType] = [.applicationBundle]
        if let exeType = UTType(filenameExtension: "exe") {
            allowedTypes.append(exeType)
        }
        panel.allowedContentTypes = allowedTypes
        if let initialPath, !initialPath.isEmpty {
            let url = URL(fileURLWithPath: initialPath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                panel.directoryURL = isDir.boolValue ? url : url.deletingLastPathComponent()
            }
        }
        panel.message = "选择游戏主程序 .exe 或 .app"
        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        return url.path
    }

    package func lookupSteamAppID(for title: String) async -> String? {
        await coordinator.lookupSteamAppID(for: title)
    }

    package func previewLaunchGameIcon(for game: LaunchGame) async -> NSImage? {
        guard let pngData = await coordinator.resolveLaunchGameIcon(game),
              let image = NSImage(data: pngData) else {
            return nil
        }
        return image
    }

    package func importLaunchGame(at url: URL) {
        Task {
            _ = await coordinator.importLaunchGame(at: url, settings: settingsStore.settings)
        }
    }
    package func importLaunchGameFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择要导入「启动」库的游戏目录、.app 或主程序 .exe"
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task {
                for url in urls {
                    _ = await coordinator.importLaunchGame(at: url, settings: settingsStore.settings)
                }
            }
        }
    }

    package func hasAccessibleDirectory(for game: LaunchGame) -> Bool {
        let fm = FileManager.default
        if let dir = game.gameDirectory, fm.fileExists(atPath: dir) {
            return true
        }
        if let exe = game.exePath {
            let parent = (exe as NSString).deletingLastPathComponent
            return fm.fileExists(atPath: parent)
        }
        return false
    }

    package func openLaunchGameDirectory(_ game: LaunchGame) {
        let fm = FileManager.default
        if let dir = game.gameDirectory {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue {
                NSWorkspace.shared.open(URL(fileURLWithPath: dir))
                return
            }
        }
        if let exe = game.exePath, fm.fileExists(atPath: exe) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: exe)])
        }
    }

    package func resolvedBottlePath(for game: LaunchGame) -> String? {
        let fm = FileManager.default
        let bottlesRoot = (settingsStore.settings.bottlesDirectory as NSString).expandingTildeInPath
        guard fm.fileExists(atPath: bottlesRoot) else { return nil }

        if let bottle = game.bottleName, !bottle.isEmpty {
            let candidate = (bottlesRoot as NSString).appendingPathComponent(bottle)
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
        }

        for path in [game.exePath, game.gameDirectory].compactMap({ $0 }) {
            let canonicalTarget = LaunchGame.canonicalPath(path) ?? path
            let canonicalRoot = LaunchGame.canonicalPath(bottlesRoot) ?? bottlesRoot
            if canonicalTarget.hasPrefix(canonicalRoot + "/") {
                let rel = String(canonicalTarget.dropFirst((canonicalRoot + "/").count))
                if let bottle = rel.components(separatedBy: "/").first, !bottle.isEmpty {
                    let candidate = (bottlesRoot as NSString).appendingPathComponent(bottle)
                    if fm.fileExists(atPath: candidate) {
                        return candidate
                    }
                }
            }
        }

        let normTitle = LaunchGame.normalizedIdentityTitle(game.title)
        if !normTitle.isEmpty,
           let entries = try? fm.contentsOfDirectory(atPath: bottlesRoot),
           let match = entries.first(where: { LaunchGame.normalizedIdentityTitle($0) == normTitle }) {
            let candidate = (bottlesRoot as NSString).appendingPathComponent(match)
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    package func revealLaunchGameBottle(_ game: LaunchGame, bottlePath: String? = nil) {
        if let path = bottlePath ?? resolvedBottlePath(for: game),
           FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return
        }
        let cxAppsDir = ("~/Applications/CrossOver" as NSString).expandingTildeInPath
        let shortcutApp = (cxAppsDir as NSString).appendingPathComponent("\(game.title).app")
        if FileManager.default.fileExists(atPath: shortcutApp) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: shortcutApp)])
        }
    }

    // MARK: - File Picker & Drag-and-Drop Routing
    package func pickFileForActiveTab() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        switch activeTab {
        case .download:
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.plainText]
            panel.message = "选择包含下载链接的文本文件 (.txt)"
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
        case .launch:
            importLaunchGameFromPanel()
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
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let fileURL = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        self.routeDroppedFile(url: fileURL)
                    }
                }
                handled = true
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
        return handled
    }

    private func routeDroppedFile(url: URL) {
        let droppedOnLaunch = (activeTab == .launch)
        Task { [weak self, coordinator] in
            let input = await coordinator.resolveDroppedFile(url)
            guard let self else { return }
            if droppedOnLaunch {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                let ext = url.pathExtension.lowercased()
                if isDir.boolValue && input.kind != .unpack {
                    _ = await coordinator.importLaunchGame(at: url, settings: settingsStore.settings)
                    return
                }
                if ext == "exe" || ext == "app" {
                    _ = await coordinator.importLaunchGame(at: url, settings: settingsStore.settings)
                    return
                }
            }
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
    // MARK: - Task Management (Pause / Resume / Stop / Archive / Delete / Retry / Edit / Batch)
    package func pauseTask(_ task: StudioTask) {
        Task { await coordinator.pauseTask(task.id) }
    }

    package func resumeTask(_ task: StudioTask) {
        coordinator.resumeDownloadJob(task.id, settings: settingsStore.settings)
    }

    package func retryDownloadPart(jobID: UUID, partID: UUID) {
        coordinator.retryDownloadPart(jobID: jobID, partID: partID, settings: settingsStore.settings)
    }

    package func downloadParts(for taskID: UUID) -> [DownloadPart] {
        jobs.first(where: { $0.id == taskID })?.downloadParts ?? []
    }

    package func stopTask(_ task: StudioTask) {
        Task {
            await coordinator.cancelTask(
                task.id,
                downloadDirectory: settingsStore.settings.downloadDirectory
            )
        }
    }

    package func archiveTask(_ task: StudioTask) {
        guard let job = jobs.first(where: { $0.id == task.id }) else { return }
        Task { await coordinator.updateJob(job.id, isArchived: !job.isArchived) }
    }

    package func deleteTask(_ task: StudioTask, deleteLocalFile: Bool = false) {
        Task { [weak self] in
            guard let self else { return }
            await coordinator.removeJob(
                task.id,
                downloadDirectory: settingsStore.settings.downloadDirectory
            )
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
        if job.kind == .download {
            coordinator.retryDownloadJob(job.id, settings: settingsStore.settings)
            return
        }
        Task {
            await coordinator.removeJob(job.id, downloadDirectory: settingsStore.settings.downloadDirectory)
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
                await coordinator.removeJob(job.id, downloadDirectory: settingsStore.settings.downloadDirectory)
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
        Task {
            await coordinator.clearJobs(
                failedIDs,
                downloadDirectory: settingsStore.settings.downloadDirectory
            )
        }
    }

    package func retryAllFailedInActiveTab() {
        for job in activeJobs where job.status == .failed || job.status == .cancelled {
            if job.kind == .download {
                coordinator.retryDownloadJob(job.id, settings: settingsStore.settings)
            } else {
                Task {
                    await coordinator.removeJob(job.id, downloadDirectory: settingsStore.settings.downloadDirectory)
                    retry(job)
                }
            }
        }
    }

    package func clearAllInActiveTab() {
        let ids = activeJobs.map(\.id)
        Task {
            await coordinator.clearJobs(
                ids,
                downloadDirectory: settingsStore.settings.downloadDirectory
            )
        }
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
        case .launch, .settings: return []
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
                rightText: "已入库",
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
                rightText: "已入库",
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

        let now = Date()
        launchGames = [
            LaunchGame(title: "Esoteric Ebb", source: .patchPipeline, addedAt: now.addingTimeInterval(-7200), lastPlayedAt: now.addingTimeInterval(-1800)),
            LaunchGame(title: "Order of the Sinking Star", source: .patchPipeline, addedAt: now.addingTimeInterval(-86400), lastPlayedAt: now.addingTimeInterval(-86400)),
            LaunchGame(title: "Patrick's Parabox", source: .crossoverScan, addedAt: now.addingTimeInterval(-86400 * 3), lastPlayedAt: now.addingTimeInterval(-86400 * 3)),
            LaunchGame(title: "Hollow Knight", source: .manualImport, addedAt: now.addingTimeInterval(-86400 * 5), lastPlayedAt: nil)
        ]
        Task {
            for job in jobs { await coordinator.addJob(job) }
        }
    }
}
