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
    @State private var launchArgumentsInput: String
    @State private var iconPreference: LaunchGameIconPreference
    @State private var customIconPath: String?
    @State private var createdCustomIconPaths: [String] = []
    @State private var candidateEXEs: [String] = []
    @State private var previewImage: NSImage?
    @State private var isLookingUpAppID = false
    @State private var isLoadingPreview = false
    @State private var statusMessage: String?
    @State private var bottleOptionsAvailable = false
    @State private var initialBottleOptions: CrossOverBottleRuntimeOptions?
    @State private var graphicsBackend: CrossOverGraphicsBackend = .automatic
    @State private var retinaModeEnabled = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case title
        case appID
        case exePath
        case launchArgs
    }

    init(vm: StudioViewModel, game: LaunchGame) {
        self.vm = vm
        self.game = game
        _titleInput = State(initialValue: game.title)
        _appIDInput = State(initialValue: game.appID ?? "")
        _exePathInput = State(initialValue: game.exePath ?? "")
        _gameDirectoryInput = State(initialValue: game.gameDirectory ?? "")
        _launchArgumentsInput = State(initialValue: game.launchArguments ?? "")
        _iconPreference = State(initialValue: game.iconPreference)
        _customIconPath = State(initialValue: game.customIconPath)
        _previewImage = State(initialValue: vm.launchGameIcon(for: game))
    }

    private var draftGame: LaunchGame {
        let trimmedTitle = titleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAppID = appIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExe = exePathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDir = gameDirectoryInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArgs = launchArgumentsInput.trimmingCharacters(in: .whitespacesAndNewlines)
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
            launchArguments: trimmedArgs.isEmpty ? nil : trimmedArgs,
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
                    .font(ChrysaFont.sheetTitle)
                    .foregroundColor(.t3TextMain)
                Spacer()
                Button(action: cancelEditing) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.t3TextMuted)
                }
                .buttonStyle(.plain)
                .help("关闭 (Esc)")
            }

            // Icon Preview Header Card
            HStack(spacing: 12) {
                ZStack {
                    if let previewImage {
                        Image(nsImage: previewImage)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                                    .stroke(Color.t3CardBorder, lineWidth: 0.6)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                            .fill(Color.t3CardBg)
                            .frame(width: 44, height: 44)
                            .overlay(
                                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                                    .stroke(Color.t3TopBoxBorder, lineWidth: 0.8)
                            )
                        Image(systemName: "gamecontroller")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundColor(.t3TextMuted)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(draftGame.title)
                        .font(ChrysaFont.rowTitleActive)
                        .foregroundColor(.t3TextMain)
                        .lineLimit(1)

                    if isLoadingPreview {
                        Text("正在获取图标预览...")
                            .font(ChrysaFont.caption)
                            .foregroundColor(.t3TextMuted)
                    } else if let statusMessage {
                        Text(statusMessage)
                            .font(ChrysaFont.caption)
                            .foregroundColor(theme.accent)
                            .lineLimit(1)
                    } else {
                        Text("图标来源：\(iconPreference.label)")
                            .font(ChrysaFont.caption)
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
                .font(ChrysaFont.control)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous)
                    .fill(Color.t3TopBoxBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous)
                    .stroke(Color.t3TopBoxBorder, lineWidth: 0.8)
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("图标模式")
                    .font(ChrysaFont.sectionHeader)
                    .foregroundColor(.t3TextSub)
                HStack(spacing: 2) {
                    ForEach(LaunchGameIconPreference.allCases) { mode in
                        let selected = (iconPreference == mode)
                        Button(action: { iconPreference = mode }) {
                            Text(mode.label)
                                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                .foregroundColor(selected ? .t3TextMain : .t3TextSub)
                                .frame(maxWidth: .infinity)
                                .frame(height: ChrysaMetrics.controlHeight - 4)
                                .background(
                                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                                        .fill(selected ? Color.t3ControlSelectedFill : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                                        .stroke(selected ? Color.t3ControlSelectedStroke : Color.clear, lineWidth: 0.8)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .frame(height: ChrysaMetrics.controlHeight)
                .background(
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                        .fill(Color.t3ControlTrackBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                        .stroke(Color.t3GroupedCardBorder, lineWidth: 0.8)
                )
            }

            Rectangle()
                .fill(Color.t3Divider)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 11) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("游戏名称")
                        .font(ChrysaFont.sectionHeader)
                        .foregroundColor(.t3TextSub)
                    styledField("输入游戏名称...", text: $titleInput, field: .title, isMono: false)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Steam AppID（用于拉取官方方形图标）")
                        .font(ChrysaFont.sectionHeader)
                        .foregroundColor(.t3TextSub)
                    HStack(spacing: 8) {
                        styledField("例如 367520（可留空自动搜索）", text: $appIDInput, field: .appID, isMono: true)
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
                        .font(ChrysaFont.control)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("启动程序 / 应用路径")
                        .font(ChrysaFont.sectionHeader)
                        .foregroundColor(.t3TextSub)
                    HStack(spacing: 8) {
                        styledField("可选，.exe 或 .app 路径", text: $exePathInput, field: .exePath, isMono: true)
                        let effectiveDir = gameDirectoryInput.isEmpty ? game.gameDirectory : gameDirectoryInput
                        if candidateEXEs.count > 1 || (!candidateEXEs.isEmpty && candidateEXEs.first != exePathInput) {
                            Menu("切换") {
                                ForEach(candidateEXEs, id: \.self) { candidate in
                                    let label: String = {
                                        if let effectiveDir,
                                           let rel = LaunchGame.relativeSubpath(of: candidate, inside: effectiveDir) {
                                            return rel
                                        }
                                        return (candidate as NSString).lastPathComponent
                                    }()
                                    Button(action: {
                                        exePathInput = candidate
                                        statusMessage = "已切换启动程序: \((candidate as NSString).lastPathComponent)"
                                    }) {
                                        if candidate == exePathInput {
                                            Label(label, systemImage: "checkmark")
                                        } else {
                                            Text(label)
                                        }
                                    }
                                }
                            }
                            .font(ChrysaFont.control)
                            .fixedSize()
                        }
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
                        .font(ChrysaFont.control)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("附加启动参数")
                        .font(ChrysaFont.sectionHeader)
                        .foregroundColor(.t3TextSub)
                    styledField("可选，例如 -fileopenlog -dx11", text: $launchArgumentsInput, field: .launchArgs, isMono: true)
                }
            }

            if bottleOptionsAvailable {
                Rectangle()
                    .fill(Color.t3Divider)
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("图形后端")
                            .font(ChrysaFont.sectionHeader)
                            .foregroundColor(.t3TextSub)
                        HStack(spacing: 2) {
                            ForEach(CrossOverGraphicsBackend.allCases) { backend in
                                let selected = (graphicsBackend == backend)
                                Button(action: { graphicsBackend = backend }) {
                                    Text(backend.displayName)
                                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                        .foregroundColor(selected ? .t3TextMain : .t3TextSub)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: ChrysaMetrics.controlHeight - 4)
                                        .background(
                                            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                                                .fill(selected ? Color.t3ControlSelectedFill : Color.clear)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                                                .stroke(selected ? Color.t3ControlSelectedStroke : Color.clear, lineWidth: 0.8)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(2)
                        .frame(height: ChrysaMetrics.controlHeight)
                        .background(
                            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                                .fill(Color.t3ControlTrackBg)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                                .stroke(Color.t3GroupedCardBorder, lineWidth: 0.8)
                        )
                    }

                    HStack {
                        Text("Retina 高分屏")
                            .font(ChrysaFont.settingLabel)
                            .foregroundColor(.t3TextMain)
                        Spacer()
                        T3ToggleSwitch(isOn: retinaModeEnabled)
                    }
                    .frame(height: ChrysaMetrics.controlHeight)
                    .contentShape(Rectangle())
                    .onInstantPress {
                        retinaModeEnabled.toggle()
                    }
                }
            }

            Rectangle()
                .fill(Color.t3Divider)
                .frame(height: 1)

            HStack(spacing: 10) {
                Button("恢复默认图标") {
                    customIconPath = nil
                    iconPreference = .automatic
                    statusMessage = "已恢复自动匹配图标"
                }
                .font(ChrysaFont.control)
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
        }
        .padding(20)
        .frame(width: 492)
        .background(Color.t3CanvasBg)
        .task(id: gameDirectoryInput) {
            let effectiveDir = gameDirectoryInput.isEmpty ? game.gameDirectory : gameDirectoryInput
            candidateEXEs = vm.candidateExecutables(in: effectiveDir)
        }
        .task(id: previewSignature) {
            isLoadingPreview = true
            let resolved = await vm.previewLaunchGameIcon(for: draftGame)
            if !Task.isCancelled {
                previewImage = resolved
                isLoadingPreview = false
            }
        }
        .task(id: "\(game.bottleName ?? "")|\(exePathInput)|\(titleInput)") {
            let loaded = await vm.loadBottleRuntimeOptions(for: draftGame)
            if !Task.isCancelled {
                if let loaded {
                    let shouldPopulateControls = !bottleOptionsAvailable || initialBottleOptions == CrossOverBottleRuntimeOptions(
                        graphicsBackend: graphicsBackend,
                        retinaMode: retinaModeEnabled
                    )
                    bottleOptionsAvailable = true
                    initialBottleOptions = loaded
                    if shouldPopulateControls {
                        graphicsBackend = loaded.graphicsBackend
                        retinaModeEnabled = loaded.retinaMode
                    }
                } else {
                    bottleOptionsAvailable = false
                    initialBottleOptions = nil
                }
            }
        }
    }

    private func styledField(_ placeholder: String, text: Binding<String>, field: Field, isMono: Bool) -> some View {
        let isFocused = (focusedField == field)
        return TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(isMono ? ChrysaFont.mono : ChrysaFont.input)
            .foregroundColor(.t3TextMain)
            .focused($focusedField, equals: field)
            .padding(.horizontal, 10)
            .frame(height: ChrysaMetrics.sheetFieldHeight)
            .background(
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                    .fill(isFocused ? Color.t3CardBg : Color.t3TopBoxBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                    .stroke(isFocused ? theme.accent.opacity(0.55) : Color.t3TopBoxBorder, lineWidth: isFocused ? 1.3 : 1)
            )
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
        let currentBottleOptions = CrossOverBottleRuntimeOptions(
            graphicsBackend: graphicsBackend,
            retinaMode: retinaModeEnabled
        )
        let changedBottleOptions: CrossOverBottleRuntimeOptions? = {
            guard bottleOptionsAvailable, currentBottleOptions != initialBottleOptions else {
                return nil
            }
            return currentBottleOptions
        }()
        vm.saveEditedLaunchGame(
            updated,
            previousCustomIconPath: game.customIconPath,
            bottleRuntimeOptions: changedBottleOptions
        )
        if !unused.isEmpty {
            Task {
                for path in unused {
                    await vm.coordinator.removeCustomLaunchGameIcon(at: path)
                }
            }
        }
    }
}
