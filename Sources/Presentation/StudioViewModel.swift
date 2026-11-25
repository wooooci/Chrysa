import ChrysaCore
import ChrysaApplication
import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
package final class StudioViewModel: ObservableObject {
    @Published package var activeTab: StudioTab = .download {
        didSet {
            if activeTab != .settings {
                lastWorkspaceTab = activeTab
            }
        }
    }
    @Published package var settingsCategory: SettingsCategory = .appearance
    private var lastWorkspaceTab: StudioTab = .download
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
    @Published package private(set) var patchingGameIDs: Set<UUID> = []
    @Published package private(set) var snapshotRevision: Int = 0
    @Published package var logs: [LogEntry] = []
    @Published package var isLogDrawerPresented: Bool = false
    @Published package var logModuleFilter: LogModule? = nil
    @Published package var logErrorsOnly: Bool = false
    @Published package var logWarningsAndErrorsOnly: Bool = false
    @Published package var logSearchQuery: String = ""
    @Published package var hasUnreadErrorLogs: Bool = false
    @Published package var logTimestampShowFullDate: Bool = true
    @Published package var logAutoScrollEnabled: Bool = true
    @Published package var logDrawerHeight: CGFloat = 260
    @Published package var isSidebarQuickLaunchExpanded: Bool = true
    @Published package var inputFocusNonce: Int = 0
    @Published package var searchFocusNonce: Int = 0
    @Published package private(set) var isMascotSiphoningText: Bool = false
    private var siphonMaskTask: Task<Void, Never>?

    package struct LaunchErrorNotice: Identifiable, Equatable {
        package let id = UUID()
        package let title: String
        package let message: String
    }
    package let settingsStore: AppSettingsStore
    package let taskStore: any LegacyTaskLoading
    package let coordinator: PipelineCoordinator
    package let mascot = MascotController()
    private var cancellables = Set<AnyCancellable>()
    private var eventTask: Task<Void, Never>?
    private var restorationTask: Task<Void, Never>?
    private var bottleScanTask: Task<Void, Never>?
    private var attemptedIconSignatureByID: [UUID: String] = [:]
    private let inMemoryOnly: Bool
    private var canWriteJobs = true
    private static let sidebarQuickLaunchDefaultsKey = "Chrysa.SidebarQuickLaunchExpanded.v1"

    deinit {
        eventTask?.cancel()
        restorationTask?.cancel()
        bottleScanTask?.cancel()
        siphonMaskTask?.cancel()
    }

    package var iconOptions: [AppIconOption] { settingsStore.iconOptions }
    package var passwords: [String] { settingsStore.settings.passwords }
    package var themePalette: AppThemePalette { AppThemePalette.resolve(settings: settingsStore.settings) }
    package func resolvedThemePalette(for colorScheme: ColorScheme) -> AppThemePalette {
        AppThemePalette.resolve(settings: settingsStore.settings, colorScheme: colorScheme)
    }
    package var appearanceMode: AppearanceMode {
        get { settingsStore.settings.appearanceMode }
        set { setAppearanceMode(newValue) }
    }
    package var accentColorMode: AccentColorMode {
        get { settingsStore.settings.accentColorMode }
        set { settingsStore.settings.accentColorMode = newValue }
    }
    package var accentSwatch: AccentSwatch {
        get { settingsStore.settings.accentSwatch }
        set { settingsStore.settings.accentSwatch = newValue }
    }
    package var mascotTheme: MascotTheme {
        get { settingsStore.settings.mascotTheme }
        set { setMascotTheme(newValue) }
    }
    package var autoRelay: Bool {
        get { settingsStore.settings.autoRelay }
        set { settingsStore.settings.autoRelay = newValue }
    }

    package func openSettings(category: SettingsCategory? = nil) {
        if activeTab != .settings {
            lastWorkspaceTab = activeTab
        }
        if let category {
            settingsCategory = category
        }
        activeTab = .settings
    }

    package func exitSettings() {
        guard activeTab == .settings else { return }
        activeTab = (lastWorkspaceTab == .settings) ? .download : lastWorkspaceTab
    }

    package init(
        seedDemoData: Bool = false,
        inMemoryOnly: Bool = false,
        settingsStore: AppSettingsStore,
        taskStore: any LegacyTaskLoading,
        coordinator: PipelineCoordinator
    ) {
        let ephemeral = seedDemoData || inMemoryOnly
        self.inMemoryOnly = ephemeral
        if !ephemeral, UserDefaults.standard.object(forKey: Self.sidebarQuickLaunchDefaultsKey) != nil {
            self.isSidebarQuickLaunchExpanded = UserDefaults.standard.bool(forKey: Self.sidebarQuickLaunchDefaultsKey)
        }
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
            appendLog(LogEntry(module: .patch, level: .warning, message: "旧任务迁移未完成，稍后重试"))
        case .missing, .corrupt:
            restoredJobs = []
            canWriteJobs = true
        case .unsupported:
            canWriteJobs = false
            let legacy = await taskStore.load()
            restoredJobs = legacy.downloadTasks.map { Job.fromLegacy($0, kind: .download) }
                + legacy.unpackTasks.map { Job.fromLegacy($0, kind: .unpack) }
                + legacy.patchTasks.map { Job.fromLegacy($0, kind: .patch) }
            appendLog(LogEntry(module: .patch, level: .warning, message: "任务档案来自较新版本，当前只读"))
        }

        if canWriteJobs {
            await coordinator.migrateLegacyPatchEntriesToLaunchLibrary()
            jobs = await coordinator.jobStore.all()
        } else {
            jobs = restoredJobs
        }
        launchGames = await coordinator.gameLibrary.all()
        let persistedPairs: [(date: Date, seq: Int, entry: LogEntry)] = jobs.enumerated().flatMap { jobIdx, job in
            job.logs.enumerated().map { logIdx, entry in
                let inferred = entry.timestamp
                    ?? LogEntry.combine(legacyTime: entry.time, onCalendarDayOf: job.updatedAt)
                    ?? job.updatedAt
                return (date: inferred, seq: jobIdx * 1000 + logIdx, entry: entry)
            }
        }
        if !persistedPairs.isEmpty {
            let sortedPersisted = persistedPairs
                .sorted { lhs, rhs in
                    if lhs.date != rhs.date { return lhs.date < rhs.date }
                    return lhs.seq < rhs.seq
                }
                .map(\.entry)
            logs = Array((sortedPersisted + logs).suffix(300))
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

    package static let maxQuickLaunchGames = 6

    package var quickLaunchGames: [LaunchGame] {
        Array(LaunchGame.sorted(launchGames, by: .lastPlayed).prefix(Self.maxQuickLaunchGames))
    }

    package func toggleSidebarQuickLaunch() {
        isSidebarQuickLaunchExpanded.toggle()
        if !inMemoryOnly {
            UserDefaults.standard.set(isSidebarQuickLaunchExpanded, forKey: Self.sidebarQuickLaunchDefaultsKey)
        }
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
            let previousStatus = jobs.first(where: { $0.id == job.id })?.status
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index] = job
            } else {
                jobs.append(job)
            }
            jobs.sort(by: Self.jobOrder)
            if let previousStatus, previousStatus != .succeeded, job.status == .succeeded {
                mascot.triggerCheerHop()
            } else if let previousStatus, previousStatus != .failed, job.status == .failed, mascot.mode == .idle {
                mascot.triggerIntake(kind: .reject, rawText: job.title)
            }
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

    package func setAppearanceMode(_ mode: AppearanceMode) {
        guard settingsStore.settings.appearanceMode != mode else { return }
        settingsStore.settings.appearanceMode = mode
    }

    package func setAccentColorMode(_ mode: AccentColorMode) {
        guard settingsStore.settings.accentColorMode != mode else { return }
        settingsStore.settings.accentColorMode = mode
    }

    package func setCustomAccentSwatch(_ swatch: AccentSwatch) {
        if settingsStore.settings.accentSwatch != swatch {
            settingsStore.settings.accentSwatch = swatch
        }
        if settingsStore.settings.accentColorMode != .custom {
            settingsStore.settings.accentColorMode = .custom
        }
    }

    package func toggleFollowAppIconTheme() {
        let next: AccentColorMode = (settingsStore.settings.accentColorMode == .followAppIcon) ? .monochrome : .followAppIcon
        setAccentColorMode(next)
    }

    package func setMascotTheme(_ theme: MascotTheme) {
        guard settingsStore.settings.mascotTheme != theme else {
            if theme.isEnabled {
                mascot.triggerBoing()
            }
            return
        }
        settingsStore.settings.mascotTheme = theme
        mascot.notifyThemeChanged(theme)
    }

    package func cycleMascotTheme() {
        let all = MascotTheme.allCases
        guard let idx = all.firstIndex(of: mascotTheme) else { return }
        let next = all[(idx + 1) % all.count]
        setMascotTheme(next)
    }

    package var activePipelineProgressSummary: (progress: Double?, isPaused: Bool) {
        let tabKind: JobKind? = switch activeTab {
        case .download: .download
        case .unpack:   .unpack
        case .patch:    .patch
        case .launch, .settings: nil
        }

        let primaryPool: [Job] = {
            guard let tabKind else { return [] }
            return jobs.filter { $0.kind == tabKind && !$0.isArchived }
        }()
        let allPool = jobs.filter { !$0.isArchived }

        for pool in [primaryPool, allPool] {
            let running = pool.filter { $0.status == .running }
            if !running.isEmpty {
                let avg = running.reduce(0.0) { $0 + $1.progress } / Double(running.count)
                return (max(0.03, min(0.995, avg)), false)
            }
            let paused = pool.filter { $0.status == .paused }
            if let firstPaused = paused.first {
                return (max(0.03, min(0.995, firstPaused.progress)), true)
            }
        }
        return (nil, true)
    }

    package func requestPrimaryInputFocus() {
        inputFocusNonce &+= 1
    }

    package func requestSearchFocus() {
        searchFocusNonce &+= 1
    }

    package var bottomBarStatusSummary: (text: String, isActive: Bool) {
        let activeJobs = jobs.filter { !$0.isArchived }
        let running = activeJobs.filter { $0.status == .running }
        if !running.isEmpty {
            let dlSpeeds = running
                .filter { $0.kind == .download }
                .compactMap { $0.pill }
                .filter { $0.contains("/s") }
            if let firstSpeed = dlSpeeds.first {
                let speedSummary: String
                if dlSpeeds.count > 1 {
                    speedSummary = Self.sumSpeedStrings(dlSpeeds) ?? firstSpeed
                } else {
                    speedSummary = firstSpeed
                }
                return ("\(running.count) 项进行中 · \(speedSummary)", true)
            }
            return ("\(running.count) 项进行中", true)
        }
        let pausedCount = activeJobs.filter { $0.status == .paused }.count
        if pausedCount > 0 {
            return ("\(pausedCount) 项已暂停", false)
        }
        switch activeTab {
        case .launch:
            return (launchGames.isEmpty ? "暂无游戏" : "共 \(launchGames.count) 款游戏", false)
        case .settings:
            return ("外观：\(appearanceMode.displayName)", false)
        case .download, .unpack, .patch:
            let kind: JobKind = activeTab == .download ? .download : (activeTab == .unpack ? .unpack : .patch)
            let count = activeJobs.filter { $0.kind == kind }.count
            return (count == 0 ? "就绪" : "共 \(count) 项", false)
        }
    }

    private static func sumSpeedStrings(_ speeds: [String]) -> String? {
        var totalMBps: Double = 0
        var parsedAny = false
        for raw in speeds {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(separator: " ")
            guard parts.count >= 2, let value = Double(parts[0]) else { continue }
            let unit = parts[1].lowercased()
            if unit.hasPrefix("gb") {
                totalMBps += value * 1024.0
                parsedAny = true
            } else if unit.hasPrefix("mb") {
                totalMBps += value
                parsedAny = true
            } else if unit.hasPrefix("kb") {
                totalMBps += value / 1024.0
                parsedAny = true
            }
        }
        guard parsedAny else { return nil }
        if totalMBps >= 1024.0 {
            return String(format: "%.2f GB/s", totalMBps / 1024.0)
        } else if totalMBps >= 10.0 {
            return String(format: "%.1f MB/s", totalMBps)
        } else {
            return String(format: "%.2f MB/s", totalMBps)
        }
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

    package func setProxyPolicy(_ policy: ProxyPolicy) {
        settingsStore.settings.proxyPolicy = policy
    }

    package func accelerationCredential(for kind: AccelerationCredentialKind) -> String {
        switch kind {
        case .pixeldrain: return settingsStore.settings.pixeldrainAPIKey
        case .realDebrid: return settingsStore.settings.realDebridToken
        case .torBox: return settingsStore.settings.torBoxToken
        }
    }

    package func setAccelerationCredential(_ value: String, for kind: AccelerationCredentialKind) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .pixeldrain: settingsStore.settings.pixeldrainAPIKey = trimmed
        case .realDebrid: settingsStore.settings.realDebridToken = trimmed
        case .torBox: settingsStore.settings.torBoxToken = trimmed
        }
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

    package func triggerMascotIntake(kind: MascotIntakeKind, rawText: String) {
        mascot.triggerIntake(kind: kind, rawText: rawText)
        guard mascotTheme.isEnabled, kind != .idle else { return }
        isMascotSiphoningText = true
        siphonMaskTask?.cancel()
        let maskNs: UInt64 = (kind == .multiDrop) ? 1_540_000_000 : 1_400_000_000
        siphonMaskTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: maskNs)
            guard !Task.isCancelled else { return }
            self?.isMascotSiphoningText = false
        }
    }

    package func stopSiphonPlaceholderMaskForSnapshot() {
        siphonMaskTask?.cancel()
        isMascotSiphoningText = false
    }

    package func startDownload(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasSuffix(".txt"),
           FileManager.default.fileExists(atPath: trimmed),
           let text = try? String(contentsOfFile: trimmed, encoding: .utf8) {
            let parsed = DownloadInputParser.parse(text)
            let displayLine = parsed.urls.first ?? URL(fileURLWithPath: trimmed).lastPathComponent
            if !parsed.urls.isEmpty {
                triggerMascotIntake(kind: parsed.urls.count > 1 ? .multiDrop : .url, rawText: displayLine)
            } else {
                triggerMascotIntake(kind: .reject, rawText: URL(fileURLWithPath: trimmed).lastPathComponent)
            }
            coordinator.startDownloads(rawInput: text, settings: settingsStore.settings)
            return
        }
        let parsed = DownloadInputParser.parse(trimmed)
        let primaryText = parsed.urls.first ?? trimmed
        if parsed.urls.count > 1 {
            triggerMascotIntake(kind: .multiDrop, rawText: primaryText)
        } else if parsed.urls.count == 1 || coordinator.containsValidDownloadURL(trimmed) {
            triggerMascotIntake(kind: .url, rawText: primaryText)
        } else if !trimmed.isEmpty {
            triggerMascotIntake(kind: .reject, rawText: trimmed)
        }
        coordinator.startDownloads(rawInput: urlString, settings: settingsStore.settings)
    }
    package func startUnpack(filePath: String) {
        let name = URL(fileURLWithPath: filePath).lastPathComponent
        triggerMascotIntake(kind: .fileDrop, rawText: name)
        coordinator.startUnpack(filePath: filePath, settings: settingsStore.settings)
    }

    package func startPatch(folderPath: String) {
        let name = URL(fileURLWithPath: folderPath).lastPathComponent
        triggerMascotIntake(kind: .fileDrop, rawText: name)
        coordinator.startPatch(folderPath: folderPath, settings: settingsStore.settings)
    }

    package func launchGame(_ game: LaunchGame) {
        coordinator.launchGame(game, settings: settingsStore.settings)
    }

    package func removeLaunchGame(_ game: LaunchGame, mode: LaunchGameRemovalMode = .recordOnly) {
        launchGameIcons.removeValue(forKey: game.id)
        attemptedIconSignatureByID.removeValue(forKey: game.id)
        Task { [weak self] in
            guard let self else { return }
            let outcome = await coordinator.removeLaunchGame(
                game.id,
                mode: mode,
                settings: settingsStore.settings
            )
            let trashErrors = outcome.warnings.filter { $0.contains("无法将") }
            if !trashErrors.isEmpty {
                self.launchErrorAlert = LaunchErrorNotice(
                    title: "部分文件未移入废纸篓 · \(game.title)",
                    message: trashErrors.joined(separator: "\n")
                )
            }
        }
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

    package func loadBottleRuntimeOptions(for game: LaunchGame) async -> CrossOverBottleRuntimeOptions? {
        await coordinator.readBottleRuntimeOptions(
            for: game,
            bottlesDirectory: settingsStore.settings.bottlesDirectory
        )
    }

    package func saveEditedLaunchGame(
        _ updated: LaunchGame,
        previousCustomIconPath: String?,
        bottleRuntimeOptions: CrossOverBottleRuntimeOptions? = nil
    ) {
        editingLaunchGame = nil
        launchGameIcons.removeValue(forKey: updated.id)
        attemptedIconSignatureByID.removeValue(forKey: updated.id)
        let bottlesDirectory = settingsStore.settings.bottlesDirectory
        Task { [weak self] in
            guard let self else { return }
            if let saved = await coordinator.updateLaunchGame(
                updated,
                previousCustomIconPath: previousCustomIconPath,
                bottlesDirectory: bottlesDirectory
            ) {
                if let bottleRuntimeOptions {
                    do {
                        try await coordinator.saveBottleRuntimeOptions(
                            bottleRuntimeOptions,
                            for: saved,
                            bottlesDirectory: bottlesDirectory
                        )
                    } catch {
                        self.launchErrorAlert = LaunchErrorNotice(
                            title: "容器配置写入失败 · \(saved.title)",
                            message: error.localizedDescription
                        )
                    }
                }
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

    package func candidateExecutables(in directory: String?) -> [String] {
        guard let directory, !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return coordinator.listCandidateExecutables(in: directory)
    }

    package func hasBaselineSnapshot(for game: LaunchGame) -> Bool {
        _ = snapshotRevision
        return coordinator.hasBaselineSnapshot(for: game)
    }

    package func pickAndInstallPatchOrDLC(for game: LaunchGame) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择补丁 / 汉化 / DLC 压缩包、文件夹、.pak 或 .exe 安装程序"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else {
            return
        }
        installPatchOrDLC(from: panel.urls, for: game)
    }

    package func installPatchOrDLC(from url: URL, for game: LaunchGame) {
        installPatchOrDLC(from: [url], for: game)
    }

    package func installPatchOrDLC(from urls: [URL], for game: LaunchGame) {
        guard !urls.isEmpty else { return }
        runExclusiveGameMutation(for: game, errorTitle: "补丁安装失败 · \(game.title)") { coordinator, settings in
            let outcome = await coordinator.applyLaunchGamePatch(
                gameID: game.id,
                sourceURLs: urls,
                settings: settings
            )
            switch outcome {
            case .applied:
                return (true, nil)
            case .cancelled:
                return (false, nil)
            case .failed(let message):
                return (false, message)
            }
        }
    }

    package func restoreBaselineSnapshot(for game: LaunchGame) {
        runExclusiveGameMutation(for: game, errorTitle: "恢复原版失败 · \(game.title)") { coordinator, settings in
            let outcome = await coordinator.restoreBaselineSnapshot(
                for: game.id,
                settings: settings
            )
            switch outcome {
            case .restored:
                return (true, nil)
            case .failed(let message):
                return (false, message)
            }
        }
    }

    private func runExclusiveGameMutation(
        for game: LaunchGame,
        errorTitle: String,
        operation: @escaping @Sendable (PipelineCoordinator, AppSettings) async -> (succeeded: Bool, errorMessage: String?)
    ) {
        guard !patchingGameIDs.contains(game.id) else { return }
        patchingGameIDs.insert(game.id)
        let coordinator = self.coordinator
        let settings = settingsStore.settings
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.patchingGameIDs.remove(game.id)
                self.snapshotRevision &+= 1
            }
            let result = await operation(coordinator, settings)
            if result.succeeded {
                self.launchGameIcons.removeValue(forKey: game.id)
                self.attemptedIconSignatureByID.removeValue(forKey: game.id)
            } else if let message = result.errorMessage {
                self.launchErrorAlert = LaunchErrorNotice(
                    title: errorTitle,
                    message: message
                )
            }
        }
    }

    package func handleDroppedPatchProviders(_ providers: [NSItemProvider], for game: LaunchGame) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }

        final class CollectedURLs: @unchecked Sendable {
            let lock = NSLock()
            var slots: [URL?]
            init(count: Int) {
                self.slots = Array(repeating: nil, count: count)
            }
            func set(_ url: URL?, at index: Int) {
                lock.lock()
                slots[index] = url
                lock.unlock()
            }
            func compact() -> [URL] {
                lock.lock()
                defer { lock.unlock() }
                return slots.compactMap(\.self)
            }
        }

        let collected = CollectedURLs(count: fileProviders.count)
        let group = DispatchGroup()
        for (index, provider) in fileProviders.enumerated() {
            group.enter()
            loadDroppedFileURL(from: provider) { fileURL in
                collected.set(fileURL, at: index)
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            let urls = collected.compact()
            guard !urls.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.installPatchOrDLC(from: urls, for: game)
            }
        }
        return true
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

    private func loadDroppedFileURL(
        from provider: NSItemProvider,
        onComplete: @escaping @Sendable (URL?) -> Void
    ) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let fileURL: URL?
            if let data = item as? Data {
                fileURL = URL(dataRepresentation: data, relativeTo: nil)
            } else if let directURL = item as? URL {
                fileURL = directURL
            } else {
                fileURL = nil
            }
            onComplete(fileURL)
        }
    }

    private func extractDroppedFileURL(
        from provider: NSItemProvider,
        onResolved: @escaping @MainActor (URL) -> Void
    ) -> Bool {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return false
        }
        loadDroppedFileURL(from: provider) { fileURL in
            guard let fileURL else { return }
            Task { @MainActor in
                onResolved(fileURL)
            }
        }
        return true
    }

    package func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if extractDroppedFileURL(from: provider, onResolved: { [weak self] fileURL in
                self?.routeDroppedFile(url: fileURL)
            }) {
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
                        message: "删除本地文件失败，已保留文件: \(error.localizedDescription)"
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
                let base = task.sourceURL ?? task.localPath ?? ""
                if !job.mirrorURLs.isEmpty && !base.isEmpty {
                    editPathOrURLInput = ([base] + job.mirrorURLs).joined(separator: " | ")
                } else {
                    editPathOrURLInput = base
                }
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
            if job.kind == .download {
                let parsed = DownloadInputParser.parse(newTarget)
                if let primary = parsed.urls.first {
                    let mirrors = parsed.mirrorGroups[primary] ?? Array(parsed.urls.dropFirst())
                    let updatedRef = ArtifactRef(kind: .remoteURL, value: primary)
                    job.source = updatedRef
                    job.input = updatedRef
                    job.mirrorURLs = mirrors
                } else {
                    let updatedRef = ArtifactRef(kind: .remoteURL, value: newTarget)
                    job.source = updatedRef
                    job.input = updatedRef
                    job.mirrorURLs = []
                }
            } else {
                let artifactKind: ArtifactKind = job.kind == .unpack ? .file : .directory
                let updatedRef = ArtifactRef(kind: artifactKind, value: newTarget)
                if job.source?.kind != .remoteURL {
                    job.source = updatedRef
                }
                job.input = updatedRef
                if job.kind == .unpack && job.status == .succeeded {
                    job.output = ArtifactRef(kind: .directory, value: newTarget)
                }
            }
        }
        editingTask = nil
        Task {
            await coordinator.updateJob(job.id, title: job.title, source: job.source, input: job.input, output: job.output)
            if job.kind == .download {
                _ = await coordinator.jobStore.updateDownloadMetadata(
                    id: job.id,
                    passwordHint: job.passwordHint,
                    downloadParts: nil,
                    mirrorURLs: job.mirrorURLs
                )
            }
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
            let base = job.sourceURL ?? job.input?.value ?? job.title
            let combined = job.mirrorURLs.isEmpty ? base : ([base] + job.mirrorURLs).joined(separator: " | ")
            startDownload(urlString: combined)
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
        print("[\(entry.fullTimestampString)] [\(entry.module.rawValue):\(entry.level.rawValue)] \(entry.message)")
    }

    package func appendLog(_ text: String, highlight: Bool = false) {
        let lower = text.lowercased()
        let level: LogLevel = (lower.hasPrefix("error") || lower.contains("失败") || lower.contains("异常") || lower.contains("不足"))
            ? .error
            : (lower.hasPrefix("warn") || lower.contains("限速") ? .warning : .info)
        appendLog(LogEntry(module: .patch, level: level, message: text))
    }

    package func logs(for taskID: UUID) -> [LogEntry] {
        if let jobLogs = jobs.first(where: { $0.id == taskID })?.logs, !jobLogs.isEmpty {
            return jobLogs
        }
        return logs.filter { $0.taskID == taskID }
    }

    package func taskTitle(for taskID: UUID?) -> String? {
        guard let taskID else { return nil }
        return jobs.first(where: { $0.id == taskID })?.title
    }

    /// Resolves the best available `Date` for display and delta calculation:
    /// uses `entry.timestamp` when present, or combines legacy `HH:mm:ss` with the owning job's `updatedAt` date.
    package func resolvedTimestampDate(for entry: LogEntry) -> Date? {
        if let ts = entry.timestamp {
            return ts
        }
        if let taskID = entry.taskID, let job = jobs.first(where: { $0.id == taskID }) {
            return LogEntry.combine(legacyTime: entry.time, onCalendarDayOf: job.updatedAt) ?? job.updatedAt
        }
        return nil
    }

    package func resolvedDateString(for entry: LogEntry) -> String? {
        if let explicit = entry.datePartString {
            return explicit
        }
        if let inferred = resolvedTimestampDate(for: entry) {
            return LogEntry.formatDateString(date: inferred)
        }
        return nil
    }

    package func formattedLogLine(_ entry: LogEntry) -> String {
        let tsText: String
        if let ts = entry.timestamp {
            tsText = LogEntry.formatFullTimestamp(date: ts)
        } else if let datePart = resolvedDateString(for: entry) {
            tsText = "\(datePart) \(entry.time)"
        } else {
            tsText = entry.time
        }
        let levelTag = entry.displayLevel.shortTag
        let moduleTag = entry.module.label
        if let title = taskTitle(for: entry.taskID), !title.isEmpty {
            return "[\(tsText)] [\(levelTag)] [\(moduleTag)] [\(title)] \(entry.message)"
        }
        return "[\(tsText)] [\(levelTag)] [\(moduleTag)] \(entry.message)"
    }

    package func rawErrorOutput(for taskID: UUID) -> String? {
        let chunks = logs(for: taskID).compactMap(\.rawOutput).filter { !$0.isEmpty }
        guard !chunks.isEmpty else { return nil }
        return chunks.joined(separator: "\n\n")
    }

    package func copySingleLog(_ entry: LogEntry) {
        var text = formattedLogLine(entry)
        if let raw = entry.rawOutput, !raw.isEmpty {
            text += "\n\(raw)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    package func copyGlobalLogs() {
        let entries = filteredGlobalLogs
        guard !entries.isEmpty else { return }
        let output = entries.map { entry in
            var line = formattedLogLine(entry)
            if let raw = entry.rawOutput, !raw.isEmpty {
                let indented = raw.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "    \($0)" }
                    .joined(separator: "\n")
                line += "\n\(indented)"
            }
            return line
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }

    package func copyTaskLogs(taskID: UUID, includeRawOnly: Bool = false) {
        let taskLogs = logs(for: taskID)
        let rawText = rawErrorOutput(for: taskID)
        let output: String
        if includeRawOnly, let rawText {
            output = rawText
        } else {
            var lines = taskLogs.map { formattedLogLine($0) }
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
            if logWarningsAndErrorsOnly && entry.displayLevel == .info { return false }
            if !query.isEmpty {
                let matchMsg = entry.message.localizedCaseInsensitiveContains(query)
                let matchRaw = entry.rawOutput?.localizedCaseInsensitiveContains(query) == true
                let matchTask = taskTitle(for: entry.taskID)?.localizedCaseInsensitiveContains(query) == true
                let matchTime = entry.fullTimestampString.localizedCaseInsensitiveContains(query)
                if !matchMsg && !matchRaw && !matchTask && !matchTime { return false }
            }
            return true
        }
    }

    package var activeRunningJobCount: Int {
        jobs.filter { !$0.isArchived && $0.status == .running }.count
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
        let now = Date()
        let dlJob1ID = UUID()
        let dlJob2ID = UUID()
        let unJob1ID = UUID()
        let paJob1ID = UUID()

        let downloadTasks = [
            StudioTask(id: dlJob1ID, title: "Esoteric_Ebb_Build_1402.7z", status: .running(0.68), pill: "48.4 MB/s", rightText: "1.47 / 2.16 GB"),
            StudioTask(id: dlJob2ID, title: "Order_of_the_Sinking_Star_v1.02.rar", status: .running(0.28), pill: "19.2 MB/s", rightText: "0.27 / 0.95 GB"),
            StudioTask(title: "Animal_Well_v1.0.7z", status: .done, pill: nil, rightText: "38.4 MB")
        ]
        let unpackTasks = [
            StudioTask(id: unJob1ID, title: "Esoteric_Ebb_Build_1402.7z", status: .locked(0.55), pill: "试密中", rightText: "2.16 GB"),
            StudioTask(title: "Animal_Well_v1.0.7z", status: .done, pill: "已解锁", rightText: "38.4 MB")
        ]
        let patchTasks = [
            StudioTask(
                id: paJob1ID,
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

        var seededJobs = downloadTasks.map { Job.fromLegacy($0, kind: .download) }
            + unpackTasks.map { Job.fromLegacy($0, kind: .unpack) }
            + patchTasks.map { Job.fromLegacy($0, kind: .patch) }

        let demoPatchLogs: [LogEntry] = [
            LogEntry(taskID: paJob1ID, module: .patch, level: .info, timestamp: now.addingTimeInterval(-95.420), message: "pe-scan ▸ 开始扫描目录与 PE 导入表: Esoteric Ebb"),
            LogEntry(taskID: paJob1ID, module: .patch, level: .info, timestamp: now.addingTimeInterval(-94.812), message: "gbe_fork ▸ [Esoteric Ebb] 已就绪 (Goldberg x64, AppID: 2057760)"),
            LogEntry(taskID: paJob1ID, module: .patch, level: .info, timestamp: now.addingTimeInterval(-94.105), message: "dlc ▸ 已写入 2 条 Steam DLC 解锁清单至 steam_settings/configs.app.ini"),
            LogEntry(taskID: paJob1ID, module: .patch, level: .info, timestamp: now.addingTimeInterval(-91.640), message: "config ▸ [Esoteric Ebb] 已写入 AppID=2057760、简中配置及 [DXMT + MSync]")
        ]

        if let paIdx = seededJobs.firstIndex(where: { $0.id == paJob1ID }) {
            seededJobs[paIdx].logs = demoPatchLogs
        }
        jobs = seededJobs

        logs = [
            LogEntry(taskID: dlJob1ID, module: .download, level: .info, timestamp: now.addingTimeInterval(-142.830), message: "sniff ▸ 解析链接: https://pixeldrain.com/u/Hk46yJoF"),
            LogEntry(taskID: dlJob1ID, module: .download, level: .info, timestamp: now.addingTimeInterval(-142.215), message: "proxy ▸ 直连探测畅通，通过 sf-dl 启用 16 线程下载"),
            LogEntry(taskID: dlJob2ID, module: .download, level: .warning, timestamp: now.addingTimeInterval(-118.490), message: "warn ▸ 服务端触发 1MB/s 限速，可在设置配置 Pixeldrain API Key 或切换节点"),
            LogEntry(taskID: unJob1ID, module: .unpack, level: .info, timestamp: now.addingTimeInterval(-108.110), message: "7zz ▸ 检测到加密分卷，正在匹配密码词典 (3/12)..."),
            LogEntry(taskID: unJob1ID, module: .unpack, level: .info, timestamp: now.addingTimeInterval(-104.302), message: "perm ▸ 已修复读写权限 (chmod u+rwX) 并清除隔离锁 (xattr -cr)"),
        ] + demoPatchLogs + [
            LogEntry(taskID: dlJob2ID, module: .download, level: .error, timestamp: now.addingTimeInterval(-22.148), message: "error ▸ 解析直链失败 (HTTP 403 · 直链签名已过期)，尝试刷新镜像失败", rawOutput: "curl: (22) The requested URL returned error: 403 Forbidden\nX-Cache: Error from cloudfront\nRetry-After: 30"),
            LogEntry(taskID: nil, module: .launch, level: .info, timestamp: now.addingTimeInterval(-4.615), message: "容器目录扫描新增 2 款游戏 · CrossOver 25.1 已就绪")
        ]

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
