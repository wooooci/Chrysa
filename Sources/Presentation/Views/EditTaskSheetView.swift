import ChrysaCore
import ChrysaApplication
import SwiftUI
import AppKit

struct EditTaskSheetView: View {
    @ObservedObject var vm: StudioViewModel
    let task: StudioTask
    @Environment(\.appTheme) private var theme
    @FocusState private var focusedField: Field?

    private enum Field {
        case title
        case source
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("编辑项目")
                    .font(ChrysaFont.sheetTitle)
                    .foregroundColor(.t3TextMain)
                Spacer()
                Button(action: { vm.editingTask = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.t3TextMuted)
                }
                .buttonStyle(.plain)
                .help("关闭 (Esc)")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("项目名称")
                    .font(ChrysaFont.sectionHeader)
                    .foregroundColor(.t3TextSub)
                TextField("名称...", text: $vm.editTitleInput)
                    .textFieldStyle(.plain)
                    .font(ChrysaFont.input)
                    .foregroundColor(.t3TextMain)
                    .focused($focusedField, equals: .title)
                    .padding(.horizontal, 10)
                    .frame(height: ChrysaMetrics.sheetFieldHeight)
                    .background(
                        RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                            .fill(focusedField == .title ? Color.t3CardBg : Color.t3TopBoxBg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                            .stroke(focusedField == .title ? theme.accent.opacity(0.55) : Color.t3TopBoxBorder, lineWidth: focusedField == .title ? 1.3 : 1)
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(vm.activeTab == .download ? "下载链接 / 镜像地址" : "本地文件或目录路径")
                    .font(ChrysaFont.sectionHeader)
                    .foregroundColor(.t3TextSub)
                HStack(spacing: 8) {
                    TextField("链接或路径...", text: $vm.editPathOrURLInput)
                        .textFieldStyle(.plain)
                        .font(ChrysaFont.mono)
                        .foregroundColor(.t3TextMain)
                        .focused($focusedField, equals: .source)
                        .padding(.horizontal, 10)
                        .frame(height: ChrysaMetrics.sheetFieldHeight)
                        .background(
                            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                                .fill(focusedField == .source ? Color.t3CardBg : Color.t3TopBoxBg)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                                .stroke(focusedField == .source ? theme.accent.opacity(0.55) : Color.t3TopBoxBorder, lineWidth: focusedField == .source ? 1.3 : 1)
                        )

                    Button("粘贴") {
                        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !clip.isEmpty {
                            vm.editPathOrURLInput = clip
                        }
                    }
                    .font(ChrysaFont.control)
                    .controlSize(.regular)
                }
            }

            Rectangle()
                .fill(Color.t3Divider)
                .frame(height: 1)

            HStack(spacing: 12) {
                Button(role: .destructive, action: {
                    vm.editingTask = nil
                    vm.deleteTask(task, deleteLocalFile: false)
                }) {
                    Label("删除项目", systemImage: "trash")
                        .font(ChrysaFont.control)
                        .foregroundColor(.t3ErrorText)
                }
                .buttonStyle(.plain)

                Button(action: {
                    vm.editingTask = nil
                    vm.archiveTask(task)
                }) {
                    Label(task.isArchived ? "取消归档" : "归档项目", systemImage: "archivebox")
                        .font(ChrysaFont.control)
                        .foregroundColor(.t3TextSub)
                }
                .buttonStyle(.plain)

                Spacer()

                Button("取消") {
                    vm.editingTask = nil
                }
                .keyboardShortcut(.cancelAction)

                Button("仅保存") {
                    vm.saveEditedTask(andRetry: false)
                }

                Button("保存并重试") {
                    vm.saveEditedTask(andRetry: true)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Color.t3CanvasBg)
    }
}
