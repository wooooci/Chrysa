import ChrysaCore
import ChrysaApplication
import SwiftUI
import AppKit

struct PageHeaderView: View {
    @ObservedObject var vm: StudioViewModel
    let isSnapshotMode: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            T3SidebarIcon(tab: vm.activeTab, size: 23)
                .frame(width: 24, height: 24, alignment: .center)

            Text(tabTitle)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.t3TextMain)

            if vm.activeTab != .settings && !isSnapshotMode {
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
            } else if vm.activeTab != .settings {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.t3TextMuted)
                    .padding(.leading, 4)
            }

            Spacer()

            if vm.activeTab != .settings {
                Button(action: { vm.showArchived.toggle() }) {
                    Text(vm.showArchived ? "含已归档" : "进行中")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(vm.showArchived ? .white : .t3TextSub)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule().fill(
                                vm.showArchived
                                    ? Color.t3Blue
                                    : Color.t3TopBoxBg
                            )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var tabTitle: String {
        switch vm.activeTab {
        case .download: return "下载"
        case .unpack:   return "解压"
        case .patch:    return "补丁"
        case .settings: return "设置"
        }
    }
}

struct TaskListSectionView: View {
    @ObservedObject var vm: StudioViewModel
    let isSnapshotMode: Bool
    @State private var pendingDeletion: PendingDeletion?

    private struct PendingDeletion: Identifiable {
        let id = UUID()
        let task: StudioTask
        let deleteLocalFile: Bool
    }

    var body: some View {
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
        .alert(item: $pendingDeletion) { pending in
            Alert(
                title: Text(pending.deleteLocalFile ? "删除记录及本地文件？" : "删除记录？"),
                message: Text(pending.deleteLocalFile
                    ? "仅允许删除下载目录内的普通文件；游戏目录、容器和目录不会被删除。"
                    : "这只会移除任务记录，不会删除本地文件。"),
                primaryButton: .destructive(Text("删除")) {
                    vm.deleteTask(pending.task, deleteLocalFile: pending.deleteLocalFile)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var topDropZone: some View {
        HStack(spacing: 10) {
            if vm.activeTab == .download && !isSnapshotMode {
                TextField("粘贴 Gofile / MirrorUploadX / FileDitch / Pixeldrain / 直链，或拖入种子...", text: $vm.urlInput)
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
                    .foregroundColor(.t3Blue)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.t3TopBoxBg)
        )
    }

    private var activeTabPlaceholder: String {
        switch vm.activeTab {
        case .download: return "粘贴下载链接，或将种子文件拖入此处..."
        case .unpack:   return "拖入 .7z / .rar / .zip 压缩包，或点击选择文件..."
        case .patch, .settings: return "拖入游戏文件夹 / .exe，或点击选择本地目录..."
        }
    }

    private var activeTabActionTitle: String {
        switch vm.activeTab {
        case .download: return "+ 新建"
        case .unpack:   return "+ 添加文件"
        case .patch, .settings: return "+ 选择目录"
        }
    }

    private var currentRows: [StudioTask] {
        let kind: JobKind = switch vm.activeTab {
        case .download: .download
        case .unpack: .unpack
        case .patch, .settings: .patch
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
                        .help(row.isArchived ? "点击取消归档" : "点击归档该项目")

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

                        Spacer()

                        if case .failed = row.status {
                            Button(action: { vm.retryTask(row) }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("重试")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundColor(.t3Blue)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(Color.t3Blue.opacity(0.10))
                                )
                            }
                            .buttonStyle(.plain)
                        } else if case .running = row.status {
                            Button(action: { vm.stopTask(row) }) {
                                Image(systemName: "stop.circle")
                                    .font(.system(size: 13))
                                    .foregroundColor(.t3TextMuted)
                            }
                            .buttonStyle(.plain)
                            .help("停止任务")
                        } else if case .locked = row.status {
                            Button(action: { vm.stopTask(row) }) {
                                Image(systemName: "stop.circle")
                                    .font(.system(size: 13))
                                    .foregroundColor(.t3TextMuted)
                            }
                            .buttonStyle(.plain)
                            .help("停止任务")
                        }

                        if vm.activeTab == .patch, row.status == .done {
                            Button(action: { vm.launchGame(row) }) {
                                Text(row.rightText)
                                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.t3Blue)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(row.rightText)
                                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                                .foregroundColor(.t3TextMuted)
                        }

                        if !isSnapshotMode {
                            Menu {
                                taskMenuItems(for: row)
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.t3TextMuted)
                                    .frame(width: 20, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if vm.activeTab == .patch { vm.toggleExpanded(row) }
                    }
                    .contextMenu {
                        taskMenuItems(for: row)
                    }

                    if row.expanded && !row.checklist.isEmpty {
                        Rectangle()
                            .fill(Color.t3Divider)
                            .frame(height: 1)
                            .padding(.leading, 38)
                            .padding(.vertical, 6)

                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(row.checklist) { item in
                                HStack(alignment: .center, spacing: 8) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(item.isChecked ? Color.t3Blue : Color.white)
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
                        .padding(.leading, 38)
                        .padding(.bottom, 8)
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

    private func rowTitleColor(_ row: StudioTask) -> Color {
        if row.isArchived {
            return .t3TextMuted
        }
        if case .done = row.status, vm.activeTab != .patch {
            return .t3TextMuted
        }
        return .t3TextMain
    }

    @ViewBuilder
    private func taskMenuItems(for row: StudioTask) -> some View {
        Button(action: { vm.beginEditTask(row) }) {
            Label("编辑项目 (名称 / 链接)...", systemImage: "pencil")
        }

        Button(action: { vm.retryTask(row) }) {
            Label("重新运行 / 重试", systemImage: "arrow.clockwise")
        }

        if case .running = row.status {
            Button(action: { vm.stopTask(row) }) {
                Label("停止当前任务", systemImage: "stop.circle")
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
                vm.appendLog("clipboard ▸ 已复制源链接: \(src)", highlight: false)
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

struct LogBoxSectionView: View {
    @ObservedObject var vm: StudioViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text("日志")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.t3Blue)
                Spacer()
                Button(action: { vm.clearLogs() }) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.t3TextMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .overlay(
                Rectangle()
                    .fill(Color.t3Divider)
                    .frame(height: 1),
                alignment: .bottom
            )

            VStack(alignment: .leading, spacing: 4) {
                ForEach(vm.logs.suffix(4)) { line in
                    HStack(spacing: 10) {
                        Text(line.time)
                            .foregroundColor(.t3TextMuted)
                        Text(line.message)
                            .foregroundColor(line.highlight ? .t3Blue : .t3TextSub)
                            .lineLimit(1)
                        Spacer()
                    }
                    .font(.system(size: 11, weight: line.highlight ? .medium : .regular, design: .monospaced))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.t3TopBoxBg)
            )
        }
    }
}
