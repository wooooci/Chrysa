import ChrysaCore
import ChrysaApplication
import SwiftUI
import AppKit

struct PageHeaderView: View {
    @ObservedObject var vm: StudioViewModel
    let isSnapshotMode: Bool
    @Environment(\.appTheme) private var theme
    @State private var isEllipsisHovered = false
    @State private var isSortPillHovered = false

    private var activeTabArchivedCount: Int {
        switch vm.activeTab {
        case .download: return vm.jobs(of: .download).filter(\.isArchived).count
        case .unpack:   return vm.jobs(of: .unpack).filter(\.isArchived).count
        case .patch:    return vm.jobs(of: .patch).filter(\.isArchived).count
        case .launch, .settings: return 0
        }
    }

    var body: some View {
        let archivedCount = activeTabArchivedCount

        HStack(alignment: .center, spacing: 9) {
            T3SidebarIcon(tab: vm.activeTab, placement: .pageHeader)

            Text(tabTitle)
                .font(ChrysaFont.pageTitle)
                .tracking(ChrysaTracking.pageTitle)
                .foregroundColor(.t3TextMain)

            if vm.activeTab != .settings && vm.activeTab != .launch && !isSnapshotMode {
                Menu {
                    Button(action: { vm.archiveAllCompletedInActiveTab() }) {
                        Label("归档所有已完成项目", systemImage: "archivebox")
                    }
                    Button(action: { vm.retryAllFailedInActiveTab() }) {
                        Label("重试所有失败项目", systemImage: "arrow.clockwise")
                    }
                    Button(action: { vm.deleteAllFailedInActiveTab() }) {
                        Label("清除所有失败项目", systemImage: "xmark.bin")
                    }
                    Divider()
                    Button(action: { vm.showArchived.toggle() }) {
                        let suffix = archivedCount > 0 ? "（\(archivedCount)）" : ""
                        Label(
                            vm.showArchived ? "隐藏已归档项目\(suffix)" : "显示已归档项目\(suffix)",
                            systemImage: vm.showArchived ? "eye.slash" : "eye"
                        )
                    }
                    Divider()
                    Menu {
                        ForEach(MascotTheme.allCases) { opt in
                            Button(action: { vm.setMascotTheme(opt) }) {
                                if vm.mascotTheme == opt {
                                    Label(opt.displayName, systemImage: "checkmark")
                                } else {
                                    Text(opt.displayName)
                                }
                            }
                        }
                    } label: {
                        Label("伴生灵主题（\(vm.mascotTheme.displayName)）", systemImage: "sparkles")
                    }
                    Divider()
                    Button(role: .destructive, action: { vm.clearAllInActiveTab() }) {
                        Label("清空当前列表", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isEllipsisHovered ? .t3TextMain : .t3TextMuted)
                        .frame(width: 24, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                                .fill(isEllipsisHovered ? Color.t3HoverBg : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .onHover { isEllipsisHovered = $0 }
                .help("列表操作")
            } else if vm.activeTab != .settings && vm.activeTab != .launch {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.t3TextMuted)
                    .padding(.leading, 4)
            }

            WindowDragArea(isSnapshotMode: isSnapshotMode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if vm.activeTab == .launch {
                if isSnapshotMode {
                    launchSortLabel
                } else {
                    Menu {
                        ForEach(LaunchSortOrder.allCases) { order in
                            Button(action: { vm.launchSortOrder = order }) {
                                HStack {
                                    Text(order.label)
                                    if vm.launchSortOrder == order {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        launchSortLabel
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .onHover { isSortPillHovered = $0 }
                    .help("排序方式")
                }
            }
        }
    }

    private var launchSortLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 10, weight: .medium))
            Text(vm.launchSortOrder.label)
                .font(ChrysaFont.control)
        }
        .foregroundColor(isSortPillHovered ? .t3TextMain : .t3TextSub)
        .padding(.horizontal, 8)
        .frame(height: ChrysaMetrics.microControlHeight)
        .background(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                .fill(isSortPillHovered ? Color.t3ControlHoverFill : Color.t3ControlFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                .stroke(Color.t3GroupedCardBorder, lineWidth: 0.75)
        )
        .animation(ChrysaMotion.hover(isSortPillHovered), value: isSortPillHovered)
    }

    private var tabTitle: String {
        switch vm.activeTab {
        case .download: return "下载"
        case .unpack:   return "解压"
        case .patch:    return "补丁"
        case .launch:   return "启动"
        case .settings: return "设置"
        }
    }
}

package struct TaskListSectionView: View {
    @ObservedObject var vm: StudioViewModel
    let isSnapshotMode: Bool
    @State private var pendingDeletion: PendingDeletion?
    @State private var isDropZoneHovered = false
    @FocusState private var isURLInputFocused: Bool
    @Environment(\.appTheme) private var theme

    package struct PendingDeletion {
        package let task: StudioTask
        package let deleteLocalFile: Bool

        package init(task: StudioTask, deleteLocalFile: Bool) {
            self.task = task
            self.deleteLocalFile = deleteLocalFile
        }

        var alertTitle: String {
            deleteLocalFile ? "删除记录及本地文件？" : "删除记录？"
        }

        var alertMessage: String {
            deleteLocalFile
                ? "仅允许删除下载目录内的普通文件；游戏目录、容器和目录不会被删除。"
                : "这只会移除任务记录，不会删除本地文件。"
        }
    }

    package init(
        vm: StudioViewModel,
        isSnapshotMode: Bool,
        initialPendingDeletion: PendingDeletion? = nil
    ) {
        self.vm = vm
        self.isSnapshotMode = isSnapshotMode
        self._pendingDeletion = State(initialValue: initialPendingDeletion)
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MascotTopDropZoneContainer(vm: vm, isSnapshotMode: isSnapshotMode) {
                topDropZone
            }
            .padding(.horizontal, ChrysaMetrics.canvasInset)
            .padding(.bottom, 14)

            if currentRows.isEmpty {
                emptyStateView
            } else if isSnapshotMode {
                taskListContent
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    taskListContent
                }
            }
        }
        .onChange(of: vm.inputFocusNonce) { _, _ in
            if vm.activeTab == .download && !isSnapshotMode {
                isURLInputFocused = true
            }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard !isSnapshotMode else { return }
            switch phase {
            case .active(let pt):
                vm.mascot.updatePointer(x: pt.x - ChrysaMetrics.canvasInset, y: pt.y + 52.0)
            case .ended:
                vm.mascot.clearPointer()
            }
        }
        // Avoid legacy `.alert(item:)` here because ancestor `.alert(item:)` modifiers on macOS swallow child alerts.
        .alert(
            pendingDeletion?.alertTitle ?? "删除记录？",
            isPresented: $pendingDeletion.isPresent(),
            presenting: pendingDeletion
        ) { pending in
            Button("删除", role: .destructive) {
                vm.deleteTask(pending.task, deleteLocalFile: pending.deleteLocalFile)
            }
            Button("取消", role: .cancel) {}
        } message: { pending in
            Text(pending.alertMessage)
        }
    }

    private var topDropZone: some View {
        let isFocused = isURLInputFocused && vm.activeTab == .download

        return HStack(spacing: 8) {
            if vm.activeTab == .download && !isSnapshotMode {
                TextField(vm.isMascotSiphoningText ? "" : "粘贴链接或拖入 .txt 列表...", text: $vm.urlInput, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .font(ChrysaFont.input)
                    .foregroundColor(.t3TextMain)
                    .focused($isURLInputFocused)
                    .onSubmit { vm.startDownloadFromInputOrClipboard() }

                if !vm.urlInput.isEmpty {
                    Button(action: { vm.urlInput = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.t3TextMuted)
                    }
                    .buttonStyle(.plain)
                    .help("清空输入")
                } else if !isFocused && !vm.isMascotSiphoningText {
                    Text("⌘V")
                        .font(ChrysaFont.monoSmall)
                        .foregroundColor(.t3TextMuted.opacity(0.85))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusMicro, style: .continuous)
                                .fill(Color.t3CanvasBg.opacity(0.7))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusMicro, style: .continuous)
                                .stroke(Color.t3TopBoxBorder, lineWidth: 0.8)
                        )
                }
            } else {
                Text(activeTabPlaceholder)
                    .font(ChrysaFont.input)
                    .foregroundColor(.t3TextSub)
                    .opacity(vm.isMascotSiphoningText ? 0 : 1)
                Spacer()
            }

            T3InlineActionButton(title: activeTabActionTitle, tooltip: activeTabActionTooltip) {
                if vm.activeTab == .download {
                    vm.startDownloadFromInputOrClipboard()
                } else {
                    vm.pickFileForActiveTab()
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .frame(minHeight: ChrysaMetrics.topBoxHeight)
        .background(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                .fill(isFocused ? Color.t3CardBg : Color.t3TopBoxBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                .stroke(
                    isFocused
                        ? theme.accent.opacity(theme.isDark ? 0.55 : 0.45)
                        : (isDropZoneHovered ? Color.t3PillBorder : Color.t3TopBoxBorder),
                    lineWidth: isFocused ? 1.4 : 1
                )
        )
        .onHover { isDropZoneHovered = $0 }
    }

    private var activeTabPlaceholder: String {
        switch vm.activeTab {
        case .download: return "粘贴下载链接或拖入 .txt 列表..."
        case .unpack:   return "拖入压缩包或点击添加文件..."
        case .patch, .launch, .settings: return "拖入游戏目录 / .exe 或点击选择..."
        }
    }

    private var activeTabActionTitle: String {
        switch vm.activeTab {
        case .download: return "+ 新建"
        case .unpack:   return "+ 添加文件"
        case .patch, .launch, .settings: return "+ 选择目录"
        }
    }

    private var activeTabActionTooltip: String {
        switch vm.activeTab {
        case .download: return "从输入或剪贴板新建下载 (⌘V)"
        case .unpack:   return "选择要解压的压缩包 (⌘N)"
        case .patch, .launch, .settings: return "选择要打补丁的游戏目录 (⌘N)"
        }
    }

    private var activeKind: JobKind {
        switch vm.activeTab {
        case .download: return .download
        case .unpack: return .unpack
        case .patch, .launch, .settings: return .patch
        }
    }

    private var allRowsInActiveTab: [StudioTask] {
        vm.tasks(for: activeKind)
    }

    private var currentRows: [StudioTask] {
        let rawList = allRowsInActiveTab
        return vm.showArchived ? rawList : rawList.filter { !$0.isArchived }
    }

    private var emptyStateView: some View {
        let hasHiddenArchived = !vm.showArchived && allRowsInActiveTab.contains(where: \.isArchived)
        let symbol: String = switch vm.activeTab {
        case .download: "tray.and.arrow.down"
        case .unpack:   "archivebox"
        case .patch, .launch, .settings: "puzzlepiece"
        }
        let title: String = {
            if hasHiddenArchived { return "暂无进行中项目" }
            switch vm.activeTab {
            case .download: return "暂无下载任务"
            case .unpack:   return "暂无解压任务"
            case .patch, .launch, .settings: return "暂无补丁任务"
            }
        }()
        let subtitle: String = {
            if hasHiddenArchived { return "已有 \(allRowsInActiveTab.count) 项归档记录，可随时切换查看" }
            switch vm.activeTab {
            case .download: return "按 ⌘V 粘贴链接，或直接拖入 .txt 下载列表"
            case .unpack:   return "拖入 .7z / .rar / .zip 压缩包，或点击右上角添加"
            case .patch, .launch, .settings: return "拖入游戏目录或 .exe，自动配置补丁与 CrossOver 容器"
            }
        }()

        return VStack(spacing: 8) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundColor(.t3TextMuted.opacity(0.65))
                .padding(.bottom, 2)
            Text(title)
                .font(ChrysaFont.navItemActive)
                .foregroundColor(.t3TextSub)
            Text(subtitle)
                .font(ChrysaFont.caption)
                .foregroundColor(.t3TextMuted)
                .multilineTextAlignment(.center)
            if hasHiddenArchived {
                Button(action: { vm.showArchived = true }) {
                    Text("显示已归档项目")
                        .font(ChrysaFont.control)
                        .foregroundColor(theme.accent)
                        .padding(.top, 2)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, ChrysaMetrics.canvasInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var taskListContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(currentRows) { row in
                TaskRowView(
                    vm: vm,
                    row: row,
                    isSnapshotMode: isSnapshotMode,
                    onRequestDelete: { pendingDeletion = $0 }
                )
            }
        }
        .padding(.horizontal, ChrysaMetrics.canvasInset)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }
}

private struct TaskRowView: View {
    @ObservedObject var vm: StudioViewModel
    let row: StudioTask
    let isSnapshotMode: Bool
    let onRequestDelete: (TaskListSectionView.PendingDeletion) -> Void
    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Button(action: { vm.archiveTask(row) }) {
                    T3StatusBox(status: row.isArchived ? .done : row.status)
                        .frame(width: 16, height: 16, alignment: .center)
                }
                .buttonStyle(.plain)
                .help(row.isArchived ? "取消归档" : "归档")

                Text(row.title)
                    .font(row.expanded ? ChrysaFont.rowTitleActive : ChrysaFont.rowTitle)
                    .strikethrough(row.isArchived, color: .t3TextMuted)
                    .foregroundColor(rowTitleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if row.isArchived {
                    T3OutlinedPill(text: "已归档", icon: "archivebox")
                } else if let pill = row.pill {
                    T3OutlinedPill(
                        text: pill,
                        icon: pill == "试密中" ? "key.fill" : nil
                    )
                }

                Spacer(minLength: 8)

                HStack(alignment: .center, spacing: 4) {
                    Text(rowRightText)
                        .font(ChrysaFont.caption.monospacedDigit())
                        .foregroundColor(.t3TextMuted)
                        .lineLimit(1)
                        .padding(.trailing, 4)

                    rowActionSlot
                        .frame(width: 24, height: 24, alignment: .center)

                    if !isSnapshotMode {
                        Menu {
                            taskMenuItems
                        } label: {
                            TaskRowMenuIconLabel(isRowHovered: isHovered)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("更多操作")
                    }
                }
            }
            .padding(.horizontal, ChrysaMetrics.rowInnerInset)
            .frame(minHeight: ChrysaMetrics.listRowHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                vm.toggleExpanded(row)
            }
            .contextMenu {
                taskMenuItems
            }

            if row.expanded {
                TaskExpandedDetailView(vm: vm, row: row)
            }
        }
        .background(
            Group {
                if row.expanded {
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous)
                        .fill(Color.t3CardBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous)
                                .stroke(Color.t3PillBorder, lineWidth: 1)
                        )
                } else if isHovered && !isSnapshotMode {
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                        .fill(Color.t3HoverBg)
                } else {
                    Color.clear
                }
            }
        )
        .onHover { isHovered = $0 }
    }

    private var rowRightText: String {
        if vm.activeTab == .patch && row.status == .done && row.rightText == "▶ 启动" {
            return "已入库"
        }
        return row.rightText
    }

    private var rowTitleColor: Color {
        if row.isArchived {
            return .t3TextMuted
        }
        if row.expanded {
            return .t3TextMain
        }
        if case .done = row.status {
            return .t3TextMuted
        }
        return .t3TextMain
    }

    @ViewBuilder
    private var rowActionSlot: some View {
        switch row.status {
        case .failed:
            TaskRowActionIconButton(
                systemName: "arrow.clockwise",
                tint: theme.accent,
                tooltip: "重试"
            ) {
                vm.retryTask(row)
            }
        case .paused:
            TaskRowActionIconButton(
                systemName: "play",
                tint: theme.accent,
                tooltip: "继续"
            ) {
                vm.resumeTask(row)
            }
        case .running:
            if vm.activeTab == .download {
                TaskRowActionIconButton(
                    systemName: "pause",
                    tint: .t3TextMain,
                    tooltip: "暂停"
                ) {
                    vm.pauseTask(row)
                }
            } else {
                TaskRowActionIconButton(
                    systemName: "stop",
                    tint: .t3TextMain,
                    tooltip: "停止"
                ) {
                    vm.stopTask(row)
                }
            }
        case .locked:
            TaskRowActionIconButton(
                systemName: "stop",
                tint: .t3TextMain,
                tooltip: "停止"
            ) {
                vm.stopTask(row)
            }
        case .done:
            if isHovered, !isSnapshotMode, let local = row.localPath, FileManager.default.fileExists(atPath: local) {
                TaskRowActionIconButton(
                    systemName: "folder",
                    tint: theme.accent,
                    tooltip: "在访达中显示"
                ) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: local)])
                }
            } else {
                Color.clear
            }
        case .queued:
            Color.clear
        }
    }

    @ViewBuilder
    private var taskMenuItems: some View {
        Button(action: { vm.beginEditTask(row) }) {
            Label("编辑...", systemImage: "pencil")
        }

        Button(action: { vm.retryTask(row) }) {
            Label("重新运行 / 重试", systemImage: "arrow.clockwise")
        }

        if case .running = row.status {
            if vm.activeTab == .download {
                Button(action: { vm.pauseTask(row) }) {
                    Label("暂停下载", systemImage: "pause.circle")
                }
            }
            Button(action: { vm.stopTask(row) }) {
                Label("取消并清理暂存", systemImage: "stop.circle")
            }
        } else if case .paused = row.status {
            Button(action: { vm.resumeTask(row) }) {
                Label("继续下载", systemImage: "play.circle")
            }
            Button(action: { vm.stopTask(row) }) {
                Label("取消并清理暂存", systemImage: "stop.circle")
            }
        } else if case .queued = row.status {
            Button(action: { vm.stopTask(row) }) {
                Label("取消排队", systemImage: "stop.circle")
            }
        } else if case .locked = row.status {
            Button(action: { vm.stopTask(row) }) {
                Label("停止当前任务", systemImage: "stop.circle")
            }
        }
        Button(action: { vm.archiveTask(row) }) {
            Label(row.isArchived ? "取消归档" : "归档项目", systemImage: "archivebox")
        }

        if let local = row.localPath, FileManager.default.fileExists(atPath: local) {
            Button(action: {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: local)])
            }) {
                Label("在 Finder 中显示", systemImage: "folder")
            }
        }

        if let src = row.sourceURL, !src.isEmpty {
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(src, forType: .string)
            }) {
                Label("复制源链接", systemImage: "doc.on.doc")
            }
        }

        Divider()

        Button(role: .destructive, action: {
            onRequestDelete(TaskListSectionView.PendingDeletion(task: row, deleteLocalFile: false))
        }) {
            Label("删除记录", systemImage: "trash")
        }

        if let local = row.localPath, FileManager.default.fileExists(atPath: local) {
            Button(role: .destructive, action: {
                onRequestDelete(TaskListSectionView.PendingDeletion(task: row, deleteLocalFile: true))
            }) {
                Label("删除记录及本地文件", systemImage: "trash.fill")
            }
        }
    }
}

struct TaskExpandedDetailView: View {
    @ObservedObject var vm: StudioViewModel
    let row: StudioTask
    @Environment(\.appTheme) private var theme
    @State private var showRawOutput = false
    @State private var copiedFeedback = false

    private var taskLogs: [LogEntry] {
        vm.logs(for: row.id)
    }

    private var rawErrorText: String? {
        vm.rawErrorOutput(for: row.id)
    }

    var body: some View {
        let parts = vm.downloadParts(for: row.id)
        let hasParts = !parts.isEmpty
        let hasChecklist = !row.checklist.isEmpty
        let hasLogs = !taskLogs.isEmpty
        let hasRaw = (rawErrorText != nil)

        if hasParts || hasChecklist || hasLogs || hasRaw {
            Rectangle()
                .fill(Color.t3Divider)
                .frame(height: 1)
                .padding(.leading, 38)
                .padding(.trailing, ChrysaMetrics.rowInnerInset)
                .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 8) {
                if hasParts {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(parts) { part in
                            HStack(alignment: .center, spacing: 8) {
                                partStatusIcon(part)
                                    .frame(width: 13, height: 13, alignment: .center)

                                Text(part.filename)
                                    .font(ChrysaFont.caption)
                                    .foregroundColor(part.status == .succeeded ? .t3TextMuted : .t3TextMain)
                                    .lineLimit(1)

                                if let msg = part.message, !msg.isEmpty {
                                    T3OutlinedPill(text: msg)
                                }

                                Spacer(minLength: 6)

                                Text(partRightText(part))
                                    .font(ChrysaFont.badge.monospacedDigit())
                                    .foregroundColor(.t3TextMuted)
                                    .lineLimit(1)

                                Group {
                                    if part.status == .failed || part.status == .cancelled {
                                        TaskRowActionIconButton(
                                            systemName: "arrow.clockwise",
                                            tint: theme.accent,
                                            tooltip: "重试分卷",
                                            size: 20,
                                            iconSize: 10.5
                                        ) {
                                            vm.retryDownloadPart(jobID: row.id, partID: part.id)
                                        }
                                    } else {
                                        Color.clear
                                    }
                                }
                                .frame(width: 20, height: 20, alignment: .center)
                            }
                        }
                    }
                }

                if hasChecklist {
                    if hasParts {
                        Rectangle()
                            .fill(Color.t3Divider.opacity(0.75))
                            .frame(height: 1)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(row.checklist) { item in
                            HStack(alignment: .center, spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(item.isChecked ? theme.accent : Color.t3CardBg)
                                        .frame(width: 12, height: 12)
                                    if !item.isChecked {
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .stroke(Color.t3CheckBorder, lineWidth: 1.3)
                                            .frame(width: 12, height: 12)
                                    } else {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 7.5, weight: .bold))
                                            .foregroundColor(theme.accentForeground)
                                    }
                                }
                                Text(item.title)
                                    .font(ChrysaFont.input)
                                    .foregroundColor(.t3TextMain)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                vm.toggleChecklistItem(taskID: row.id, itemID: item.id)
                            }
                        }
                    }
                }

                if hasLogs || hasRaw {
                    if hasParts || hasChecklist {
                        Rectangle()
                            .fill(Color.t3Divider.opacity(0.75))
                            .frame(height: 1)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center, spacing: 10) {
                            if hasRaw {
                                HStack(spacing: 8) {
                                    Button(action: { showRawOutput = false }) {
                                        Text("记录")
                                            .font(.system(size: 11, weight: !showRawOutput ? .semibold : .regular))
                                            .foregroundColor(!showRawOutput ? theme.accent : .t3TextMuted)
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: { showRawOutput = true }) {
                                        Text("原始输出")
                                            .font(.system(size: 11, weight: showRawOutput ? .semibold : .regular))
                                            .foregroundColor(showRawOutput ? theme.accent : .t3TextMuted)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            Spacer()

                            Button(action: {
                                vm.copyTaskLogs(taskID: row.id, includeRawOnly: showRawOutput)
                                copiedFeedback = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    copiedFeedback = false
                                }
                            }) {
                                Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(copiedFeedback ? theme.accent : .t3TextMuted)
                                    .frame(width: 18, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("复制日志")
                        }

                        if showRawOutput, let rawErrorText {
                            ScrollView(.vertical, showsIndicators: true) {
                                Text(rawErrorText)
                                    .font(ChrysaFont.monoSmall)
                                    .foregroundColor(.t3TextMain)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .padding(8)
                            }
                            .frame(maxHeight: 140)
                            .background(
                                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                                    .fill(Color.t3TopBoxBg)
                            )
                        } else {
                            ScrollView(.vertical, showsIndicators: true) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(taskLogs) { line in
                                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                                            Circle()
                                                .fill(logLevelColor(line.level))
                                                .frame(width: 5, height: 5)
                                                .offset(y: -1)
                                            Text(line.time)
                                                .font(ChrysaFont.monoSmall)
                                                .foregroundColor(.t3TextMuted)
                                            Text(line.message)
                                                .font(.system(size: 11, weight: line.level == .error ? .medium : .regular, design: .monospaced))
                                                .foregroundColor(logMessageColor(line.level))
                                                .fixedSize(horizontal: false, vertical: true)
                                                .textSelection(.enabled)
                                            Spacer(minLength: 0)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 130)
                        }
                    }
                }
            }
            .padding(.leading, 38)
            .padding(.trailing, ChrysaMetrics.rowInnerInset)
            .padding(.bottom, 10)
        } else {
            Rectangle()
                .fill(Color.t3Divider)
                .frame(height: 1)
                .padding(.leading, 38)
                .padding(.trailing, ChrysaMetrics.rowInnerInset)
                .padding(.vertical, 6)

            Text("暂无记录")
                .font(ChrysaFont.caption)
                .foregroundColor(.t3TextMuted)
                .padding(.leading, 38)
                .padding(.bottom, 10)
        }
    }

    private func logLevelColor(_ level: LogLevel) -> Color {
        switch level {
        case .info:    return Color.t3TextMuted.opacity(0.6)
        case .warning: return Color.t3Amber
        case .error:   return Color.t3ErrorText
        }
    }

    private func logMessageColor(_ level: LogLevel) -> Color {
        switch level {
        case .info:    return .t3TextSub
        case .warning: return .t3WarningText
        case .error:   return .t3ErrorText
        }
    }

    @ViewBuilder
    private func partStatusIcon(_ part: DownloadPart) -> some View {
        switch part.status {
        case .queued:
            T3StatusBox(status: .queued)
                .scaleEffect(0.85)
        case .running:
            T3PieRing(progress: max(0.03, part.progress), size: 12.5, color: theme.accent)
        case .paused:
            T3StatusBox(status: .paused(part.progress))
                .scaleEffect(0.85)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11.5))
                .foregroundColor(theme.accent)
        case .failed, .cancelled:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11.5))
                .foregroundColor(.t3ErrorText)
        }
    }

    private func partRightText(_ part: DownloadPart) -> String {
        if part.status == .succeeded {
            if let tot = part.totalBytes, tot > 0 {
                return ByteCountFormatter.string(fromByteCount: tot, countStyle: .file)
            }
            return "已完成"
        }
        if let tot = part.totalBytes, tot > 0 {
            if part.downloadedBytes > 0 {
                let d = ByteCountFormatter.string(fromByteCount: part.downloadedBytes, countStyle: .file)
                let t = ByteCountFormatter.string(fromByteCount: tot, countStyle: .file)
                return "\(d) / \(t)"
            }
            return ByteCountFormatter.string(fromByteCount: tot, countStyle: .file)
        }
        if part.downloadedBytes > 0 {
            return ByteCountFormatter.string(fromByteCount: part.downloadedBytes, countStyle: .file)
        }
        return part.status == .paused ? "已暂停" : "待下载"
    }
}

struct GlobalLogDrawerView: View {
    @ObservedObject var vm: StudioViewModel
    @Environment(\.appTheme) private var theme
    @FocusState private var isLogSearchFocused: Bool

    var body: some View {
        let entries = vm.filteredGlobalLogs

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                filterPill(title: "全部", isSelected: vm.logModuleFilter == nil && !vm.logErrorsOnly) {
                    vm.logModuleFilter = nil
                }
                ForEach(LogModule.allCases) { mod in
                    filterPill(title: mod.label, isSelected: vm.logModuleFilter == mod) {
                        vm.logModuleFilter = (vm.logModuleFilter == mod) ? nil : mod
                    }
                }

                Rectangle()
                    .fill(Color.t3Divider)
                    .frame(width: 1, height: 12)
                    .padding(.horizontal, 2)

                Button(action: { vm.logErrorsOnly.toggle() }) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.t3ErrorText)
                            .frame(width: 5, height: 5)
                        Text("仅错误")
                            .font(.system(size: 11, weight: vm.logErrorsOnly ? .semibold : .regular))
                            .foregroundColor(vm.logErrorsOnly ? .t3ErrorText : .t3TextSub)
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                            .fill(vm.logErrorsOnly ? Color.t3ErrorPillBg : Color.clear)
                    )
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundColor(.t3TextMuted)
                    TextField("搜索", text: $vm.logSearchQuery)
                        .textFieldStyle(.plain)
                        .font(ChrysaFont.monoSmall)
                        .foregroundColor(.t3TextMain)
                        .focused($isLogSearchFocused)
                        .frame(width: 110)
                    if !vm.logSearchQuery.isEmpty {
                        Button(action: { vm.logSearchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.t3TextMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                        .fill(Color.t3TopBoxBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                        .stroke(isLogSearchFocused ? theme.accent.opacity(0.45) : Color.t3TopBoxBorder, lineWidth: 0.8)
                )

                Button(action: { vm.clearLogs() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.t3TextMuted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("清空日志")

                Button(action: { vm.isLogDrawerPresented = false }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.t3TextMuted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("收起日志抽屉")
            }
            .padding(.horizontal, ChrysaMetrics.canvasInset)
            .frame(height: 34)
            .overlay(
                Rectangle()
                    .fill(Color.t3Divider)
                    .frame(height: 1),
                alignment: .bottom
            )

            if entries.isEmpty {
                HStack {
                    Spacer()
                    Text("无记录")
                        .font(ChrysaFont.caption)
                        .foregroundColor(.t3TextMuted)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(entries) { line in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Circle()
                                        .fill(drawerLevelColor(line.level))
                                        .frame(width: 5, height: 5)
                                        .offset(y: -1)
                                    Text(line.time)
                                        .font(ChrysaFont.monoSmall)
                                        .foregroundColor(.t3TextMuted)
                                    Text(line.module.label)
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundColor(.t3TextMuted)
                                    Text(line.message)
                                        .font(.system(size: 11, weight: line.level == .error ? .medium : .regular, design: .monospaced))
                                        .foregroundColor(drawerMessageColor(line.level))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                                if let raw = line.rawOutput, !raw.isEmpty {
                                    Text(raw)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundColor(.t3TextSub)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                        .padding(6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(
                                            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                                                .fill(Color.t3TopBoxBg)
                                        )
                                        .padding(.leading, 12)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, ChrysaMetrics.canvasInset)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color.t3CanvasBg)
        .onChange(of: vm.searchFocusNonce) { _, _ in
            if vm.isLogDrawerPresented && vm.activeTab != .launch {
                isLogSearchFocused = true
            }
        }
    }

    private func filterPill(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        let useAccent = isSelected && theme.mode != .monochrome
        return Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(useAccent ? theme.accentForeground : (isSelected ? .t3TextMain : .t3TextSub))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                        .fill(useAccent ? theme.accent : (isSelected ? Color.t3ControlSelectedFill : Color.clear))
                )
        }
        .buttonStyle(.plain)
    }

    private func drawerLevelColor(_ level: LogLevel) -> Color {
        switch level {
        case .info:    return Color.t3TextMuted.opacity(0.6)
        case .warning: return Color.t3Amber
        case .error:   return Color.t3ErrorText
        }
    }

    private func drawerMessageColor(_ level: LogLevel) -> Color {
        switch level {
        case .info:    return .t3TextSub
        case .warning: return .t3WarningText
        case .error:   return .t3ErrorText
        }
    }
}

private struct TaskRowActionIconButton: View {
    let systemName: String
    let tint: Color
    let tooltip: String
    var size: CGFloat = 24
    var iconSize: CGFloat = 12
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundColor(isHovered ? tint : .t3TextSub)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                        .fill(isHovered ? Color.t3HoverBg : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(tooltip)
    }
}

private struct TaskRowMenuIconLabel: View {
    var isRowHovered: Bool = false
    @State private var isHovered = false

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(isHovered ? .t3TextMain : (isRowHovered ? .t3TextSub : .t3TextMuted))
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                    .fill(isHovered ? Color.t3HoverBg : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
    }
}
