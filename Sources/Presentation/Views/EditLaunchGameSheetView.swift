import ChrysaCore
import ChrysaApplication
import SwiftUI
import AppKit

struct EditLaunchGameSheetView: View {
    @ObservedObject var vm: StudioViewModel
    let game: LaunchGame
    @Environment(\.appTheme) private var theme

    @State private var titleInput: String
    @State private var appIDInput: String
    @State private var exePathInput: String
    @State private var gameDirectoryInput: String
    @State private var iconPreference: LaunchGameIconPreference
    @State private var customIconPath: String?
    @State private var createdCustomIconPaths: [String] = []
    @State private var previewImage: NSImage?
    @State private var isLookingUpAppID = false
    @State private var isLoadingPreview = false
    @State private var statusMessage: String?

    init(vm: StudioViewModel, game: LaunchGame) {
        self.vm = vm
        self.game = game
        _titleInput = State(initialValue: game.title)
        _appIDInput = State(initialValue: game.appID ?? "")
        _exePathInput = State(initialValue: game.exePath ?? "")
        _gameDirectoryInput = State(initialValue: game.gameDirectory ?? "")
        _iconPreference = State(initialValue: game.iconPreference)
        _customIconPath = State(initialValue: game.customIconPath)
        _previewImage = State(initialValue: vm.launchGameIcon(for: game))
    }

    private var draftGame: LaunchGame {
        let trimmedTitle = titleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAppID = appIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExe = exePathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDir = gameDirectoryInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return LaunchGame(
            id: game.id,
            title: trimmedTitle.isEmpty ? game.title : trimmedTitle,
            exePath: trimmedExe.isEmpty ? nil : trimmedExe,
            gameDirectory: trimmedDir.isEmpty ? nil : trimmedDir,
            bottleName: game.bottleName,
            appID: trimmedAppID.isEmpty ? nil : trimmedAppID,
            source: game.source,
            customIconPath: customIconPath,
            iconPreference: iconPreference,
            addedAt: game.addedAt,
            updatedAt: Date(),
            lastPlayedAt: game.lastPlayedAt
        )
    }

    private var previewSignature: String {
        StudioViewModel.launchGameIconSignature(for: draftGame)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("编辑游戏与图标")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.t3TextMain)
                Spacer()
                Button(action: cancelEditing) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.t3TextMuted)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                ZStack {
                    if let previewImage {
                        Image(nsImage: previewImage)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(Color.black.opacity(0.08), lineWidth: 0.6)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.t3TopBoxBg)
                            .frame(width: 44, height: 44)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(Color.t3Divider, lineWidth: 0.6)
                            )
                        Image(systemName: "gamecontroller")
                            .font(.system(size: 18, weight: .light))
                            .foregroundColor(.t3TextMuted)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(draftGame.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(.t3TextMain)
                        .lineLimit(1)

                    if isLoadingPreview {
                        Text("正在获取图标预览...")
                            .font(.system(size: 11.5))
                            .foregroundColor(.t3TextMuted)
                    } else if let statusMessage {
                        Text(statusMessage)
                            .font(.system(size: 11.5))
                            .foregroundColor(theme.accent)
                            .lineLimit(1)
                    } else {
                        Text("图标来源：\(iconPreference.label)")
                            .font(.system(size: 11.5))
                            .foregroundColor(.t3TextMuted)
                    }
                }

                Spacer()

                Button("选择图标文件...") {
                    Task {
                        if let savedPath = await vm.pickCustomIconFile(for: game.id) {
                            createdCustomIconPaths.append(savedPath)
                            customIconPath = savedPath
                            iconPreference = .custom
                            statusMessage = "已载入自定义图标"
                        }
                    }
                }
                .font(.system(size: 12))
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.t3TopBoxBg)
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("图标模式")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.t3TextSub)
                Picker("", selection: $iconPreference) {
                    ForEach(LaunchGameIconPreference.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("游戏名称")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.t3TextSub)
                TextField("输入游戏名称...", text: $titleInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Steam AppID（用于拉取官方方形图标）")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.t3TextSub)
                HStack(spacing: 6) {
                    TextField("例如 367520（可留空自动搜索）", text: $appIDInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5, design: .monospaced))
                    Button(isLookingUpAppID ? "匹配中..." : "自动匹配") {
                        Task {
                            isLookingUpAppID = true
                            defer { isLookingUpAppID = false }
                            let query = titleInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let matched = await vm.lookupSteamAppID(for: query.isEmpty ? game.title : query) {
                                appIDInput = matched
                                if iconPreference == .automatic || iconPreference == .executable {
                                    iconPreference = .steam
                                }
                                statusMessage = "已匹配 Steam AppID: \(matched)"
                            } else {
                                statusMessage = "未在 Steam 搜索到匹配项，可尝试修改游戏名"
                            }
                        }
                    }
                    .disabled(isLookingUpAppID)
                    .font(.system(size: 12))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("启动程序 / 应用路径")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.t3TextSub)
                HStack(spacing: 6) {
                    TextField("可选，.exe 或 .app 路径", text: $exePathInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button("浏览...") {
                        if let picked = vm.chooseLaunchExecutable(
                            initialPath: exePathInput.isEmpty ? gameDirectoryInput : exePathInput
                        ) {
                            if (picked as NSString).pathExtension.lowercased() == "app" {
                                gameDirectoryInput = picked
                                exePathInput = ""
                            } else {
                                exePathInput = picked
                                if gameDirectoryInput.isEmpty {
                                    gameDirectoryInput = (picked as NSString).deletingLastPathComponent
                                }
                            }
                        }
                    }
                    .font(.system(size: 12))
                }
            }

            HStack(spacing: 10) {
                Button("恢复默认图标") {
                    customIconPath = nil
                    iconPreference = .automatic
                    statusMessage = "已恢复自动匹配图标"
                }
                .font(.system(size: 12))
                .foregroundColor(.t3TextSub)
                .buttonStyle(.plain)

                Spacer()

                Button("取消") {
                    cancelEditing()
                }
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    saveEditing()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 480)
        .task(id: previewSignature) {
            isLoadingPreview = true
            let resolved = await vm.previewLaunchGameIcon(for: draftGame)
            if !Task.isCancelled {
                previewImage = resolved
                isLoadingPreview = false
            }
        }
    }

    private func cancelEditing() {
        let unused = createdCustomIconPaths
        vm.editingLaunchGame = nil
        if !unused.isEmpty {
            Task {
                for path in unused {
                    await vm.coordinator.removeCustomLaunchGameIcon(at: path)
                }
            }
        }
    }

    private func saveEditing() {
        let finalCustomPath = customIconPath
        let unused = createdCustomIconPaths.filter { $0 != finalCustomPath }
        let updated = draftGame
        vm.saveEditedLaunchGame(updated, previousCustomIconPath: game.customIconPath)
        if !unused.isEmpty {
            Task {
                for path in unused {
                    await vm.coordinator.removeCustomLaunchGameIcon(at: path)
                }
            }
        }
    }
}
