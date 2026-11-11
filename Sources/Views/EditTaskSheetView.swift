import SwiftUI
import AppKit

struct EditTaskSheetView: View {
    @ObservedObject var vm: StudioViewModel
    let task: StudioTask

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("编辑项目")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.t3TextMain)
                Spacer()
                Button(action: { vm.editingTask = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.t3TextMuted)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("项目名称")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.t3TextSub)
                TextField("输入项目名称...", text: $vm.editTitleInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(vm.activeTab == .download ? "下载链接 / 镜像地址" : "本地文件或目录路径")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.t3TextSub)
                HStack(spacing: 6) {
                    TextField("输入链接或本地路径...", text: $vm.editPathOrURLInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5, design: .monospaced))
                    Button("粘贴") {
                        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !clip.isEmpty {
                            vm.editPathOrURLInput = clip
                        }
                    }
                    .font(.system(size: 12))
                }
            }

            HStack(spacing: 10) {
                Button(role: .destructive, action: {
                    vm.editingTask = nil
                    vm.deleteTask(task, deleteLocalFile: false)
                }) {
                    Label("删除项目", systemImage: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)

                Button(action: {
                    vm.editingTask = nil
                    vm.archiveTask(task)
                }) {
                    Label(task.isArchived ? "取消归档" : "归档项目", systemImage: "archivebox")
                        .font(.system(size: 12))
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
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 480)
    }
}
