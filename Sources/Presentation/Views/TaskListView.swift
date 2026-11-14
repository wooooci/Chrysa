import ChrysaCore
import ChrysaApplication
import SwiftUI
import AppKit

struct PageHeaderView: View {
    @ObservedObject var vm: StudioViewModel
    let isSnapshotMode: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            T3SidebarIcon(tab: vm.activeTab, placement: .pageHeader)

            Text(tabTitle)
                .font(.system(size: 24, weight: .bold))
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
                        Label(vm.showArchived ? "隐藏已归档项目" : "显示已归档项目", systemImage: vm.showArchived ? "eye.slash" : "eye")
                    }
                    Divider()
                    Button(role: .destructive, action: { vm.clearAllInActiveTab() }) {
                        Label("清空当前列表", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.t3TextMuted)
                        .padding(.leading, 4)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else if vm.activeTab != .settings && vm.activeTab != .launch {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.t3TextMuted)
                    .padding(.leading, 4)
            }

            Spacer()

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
                    .fixedSize()
                }
            } else if vm.activeTab != .settings {
                Button(action: { vm.showArchived.toggle() }) {
                    Text(vm.showArchived ? "含已归档" : "进行中")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(vm.showArchived ? .white : .t3TextSub)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule().fill(
                                vm.showArchived
                                    ? theme.accent
                                    : Color.t3TopBoxBg
                            )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var launchSortLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 10, weight: .medium))
            Text(vm.launchSortOrder.label)
                .font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundColor(.t3TextSub)
        .padding(.horizontal, 10)
        .padding(.vertical, 2.5)
        .background(
            Capsule().fill(Color.t3TopBoxBg)
        )
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
            topDropZone
                .padding(.bottom, 16)

            if isSnapshotMode {
                taskListContent
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    taskListContent
                }
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
        HStack(spacing: 10) {
            if vm.activeTab == .download && !isSnapshotMode {
                TextField("粘贴链接或拖入 .txt 列表...", text: $vm.urlInput, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundColor(.t3TextMain)
                    .onSubmit { vm.startDownloadFromInputOrClipboard() }

                if !vm.urlInput.isEmpty {
                    Button(action: { vm.urlInput = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.t3TextMuted)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text(activeTabPlaceholder)
                    .font(.system(size: 12.5))
                    .foregroundColor(.t3TextSub)
                Spacer()
            }

            Button(action: {
                if vm.activeTab == .download {
                    vm.startDownloadFromInputOrClipboard()
                } else {
                    vm.pickFileForActiveTab()
                }
            }) {
                Text(activeTabActionTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.t3TopBoxBg)
        )
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

    private var currentRows: [StudioTask] {
        let kind: JobKind = switch vm.activeTab {
        case .download: .download
        case .unpack: .unpack
        case .patch, .launch, .settings: .patch
        }
        let rawList = vm.tasks(for: kind)
        return vm.showArchived ? rawList : rawList.filter { !$0.isArchived }
    }

    private var taskListContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(currentRows) { row in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 10) {
                        Button(action: { vm.archiveTask(row) }) {
                            T3StatusBox(status: row.isArchived ? .done : row.status)
                                .frame(width: 16, height: 16, alignment: .center)
                        }
                        .buttonStyle(.plain)
                        .help(row.isArchived ? "取消归档" : "归档")

                        Text(row.title)
                            .font(.system(size: 13.5, weight: row.expanded ? .semibold : .regular))
                            .strikethrough(row.isArchived, color: .t3TextMuted)
                            .foregroundColor(rowTitleColor(row))
                            .lineLimit(1)

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
                            Text(rowRightText(row))
                                .font(.system(size: 11.5, weight: .regular))
                                .monospacedDigit()
                                .foregroundColor(.t3TextMuted)
                                .lineLimit(1)
                                .padding(.trailing, 4)

                            rowActionSlot(for: row)
                                .frame(width: 24, height: 24, alignment: .center)

                            if !isSnapshotMode {
                                Menu {
                                    taskMenuItems(for: row)
                                } label: {
                                    TaskRowMenuIconLabel()
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("更多操作")
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        vm.toggleExpanded(row)
                    }
                    .contextMenu {
                        taskMenuItems(for: row)
                    }

                    if row.expanded {
                        TaskExpandedDetailView(vm: vm, row: row)
                    }
                }
                .background(
                    Group {
                        if row.expanded {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white)
                                .shadow(color: Color.black.opacity(0.07), radius: 12, x: 0, y: 3)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                                )
                        } else {
                            Color.clear
                        }
                    }
                )
            }
        }
    }

    private func rowRightText(_ row: StudioTask) -> String {
        if vm.activeTab == .patch && row.status == .done && row.rightText == "▶ 启动" {
            return "已入库"
        }
        return row.rightText
    }

    @ViewBuilder
    private func rowActionSlot(for row: StudioTask) -> some View {
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
        default:
            Color.clear
        }
    }

    private func rowTitleColor(_ row: StudioTask) -> Color {
        if row.isArchived {
            return .t3TextMuted
        }
        if case .done = row.status {
            return .t3TextMuted
        }
        return .t3TextMain
    }

    @ViewBuilder
    private func taskMenuItems(for row: StudioTask) -> some View {
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
            pendingDeletion = PendingDeletion(task: row, deleteLocalFile: false)
        }) {
            Label("删除记录", systemImage: "trash")
        }

        if let local = row.localPath, FileManager.default.fileExists(atPath: local) {
            Button(role: .destructive, action: {
                pendingDeletion = PendingDeletion(task: row, deleteLocalFile: true)
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
                .padding(.trailing, 12)
                .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 8) {
                if hasParts {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(parts) { part in
                            HStack(alignment: .center, spacing: 8) {
                                partStatusIcon(part)
                                    .frame(width: 13, height: 13, alignment: .center)

                                Text(part.filename)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(part.status == .succeeded ? .t3TextMuted : .t3TextMain)
                                    .lineLimit(1)

                                if let msg = part.message, !msg.isEmpty {
                                    T3OutlinedPill(text: msg)
                                }

                                Spacer(minLength: 6)

                                Text(partRightText(part))
                                    .font(.system(size: 11))
                                    .monospacedDigit()
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
                                        .fill(item.isChecked ? theme.accent : Color.white)
                                        .frame(width: 12, height: 12)
                                    if !item.isChecked {
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .stroke(Color.t3CheckBorder, lineWidth: 1.3)
                                            .frame(width: 12, height: 12)
                                    } else {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 7.5, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                }
                                Text(item.title)
                                    .font(.system(size: 12.5))
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
                        }

                        if showRawOutput, let rawErrorText {
                            ScrollView(.vertical, showsIndicators: true) {
                                Text(rawErrorText)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.t3TextMain)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .padding(8)
                            }
                            .frame(maxHeight: 140)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
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
                                                .font(.system(size: 11, design: .monospaced))
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
            .padding(.trailing, 12)
            .padding(.bottom, 8)
        } else {
            Rectangle()
                .fill(Color.t3Divider)
                .frame(height: 1)
                .padding(.leading, 38)
                .padding(.trailing, 12)
                .padding(.vertical, 6)

            Text("暂无记录")
                .font(.system(size: 11.5))
                .foregroundColor(.t3TextMuted)
                .padding(.leading, 38)
                .padding(.bottom, 8)
        }
    }

    private func logLevelColor(_ level: LogLevel) -> Color {
        switch level {
        case .info:    return Color.t3TextMuted.opacity(0.55)
        case .warning: return Color.t3Amber
        case .error:   return Color.red.opacity(0.85)
        }
    }

    private func logMessageColor(_ level: LogLevel) -> Color {
        switch level {
        case .info:    return .t3TextSub
        case .warning: return Color(red: 0.72, green: 0.48, blue: 0.06)
        case .error:   return Color.red.opacity(0.88)
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
                .foregroundColor(Color.red.opacity(0.85))
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
                            .fill(Color.red.opacity(0.85))
                            .frame(width: 5, height: 5)
                        Text("仅错误")
                            .font(.system(size: 11, weight: vm.logErrorsOnly ? .semibold : .regular))
                            .foregroundColor(vm.logErrorsOnly ? Color.red.opacity(0.88) : .t3TextSub)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(vm.logErrorsOnly ? Color.red.opacity(0.10) : Color.clear)
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
                        .font(.system(size: 11))
                        .foregroundColor(.t3TextMain)
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
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.t3TopBoxBg)
                )

                Button(action: { vm.clearLogs() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.t3TextMuted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: { vm.isLogDrawerPresented = false }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.t3TextMuted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 34)
            .frame(height: 32)
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
                        .font(.system(size: 11.5))
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
                                        .font(.system(size: 11, design: .monospaced))
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
                                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                .fill(Color.t3TopBoxBg)
                                        )
                                        .padding(.leading, 12)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 34)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color.white)
    }

    private func filterPill(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .t3TextSub)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? theme.accent : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func drawerLevelColor(_ level: LogLevel) -> Color {
        switch level {
        case .info:    return Color.t3TextMuted.opacity(0.55)
        case .warning: return Color.t3Amber
        case .error:   return Color.red.opacity(0.85)
        }
    }

    private func drawerMessageColor(_ level: LogLevel) -> Color {
        switch level {
        case .info:    return .t3TextSub
        case .warning: return Color(red: 0.72, green: 0.48, blue: 0.06)
        case .error:   return Color.red.opacity(0.88)
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
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovered ? Color.t3TopBoxBg : Color.clear)
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
    @State private var isHovered = false

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(isHovered ? .t3TextMain : .t3TextMuted)
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? Color.t3TopBoxBg : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
    }
}
