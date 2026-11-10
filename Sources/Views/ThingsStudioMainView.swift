import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Main Interactive Things 3 Studio View
struct ThingsStudioMainView: View {
    @ObservedObject var vm: StudioViewModel
    var isSnapshotMode: Bool = false

    // Magpie-style tab follower state:
    // - Immediate pointer-down pre-glide (`onpointerdown` -> glide to pressed tab; drag out -> spring back)
    // - `navlamp.js` continuous pointer torch on hovered sidebar rows
    @State private var pressingSidebarTab: StudioTab? = nil
    @State private var hoveredSidebarTab: StudioTab? = nil
    @State private var hoverSidebarX: CGFloat = 45

    @State private var pressingSettingsCategory: SettingsCategory? = nil
    @State private var hoveredSettingsCategory: SettingsCategory? = nil

    private var effectiveSidebarTab: StudioTab {
        pressingSidebarTab ?? vm.activeTab
    }

    private var effectiveSettingsCategory: SettingsCategory {
        pressingSettingsCategory ?? vm.settingsCategory
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebarView
                .frame(width: 186)

            Rectangle()
                .fill(Color.t3SidebarBorder)
                .frame(width: 1)

            mainCanvasView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Color.white)
        .onDrop(of: [.fileURL, .plainText, .url], isTargeted: nil) { providers in
            vm.handleDroppedProviders(providers)
        }
        .sheet(item: $vm.editingTask) { task in
            editTaskSheetView(for: task)
        }
    }

    private func editTaskSheetView(for task: StudioTask) -> some View {
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

    private var topBarHeight: CGFloat {
        isSnapshotMode ? 38 : 10
    }

    // MARK: Sidebar
    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .leading) {
                if isSnapshotMode {
                    HStack(spacing: 8) {
                        Circle().fill(Color(red: 1.0, green: 0.373, blue: 0.341)).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                        Circle().fill(Color(red: 1.0, green: 0.741, blue: 0.180)).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                        Circle().fill(Color(red: 0.153, green: 0.788, blue: 0.247)).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                    }
                    .padding(.leading, 18)
                }
            }
            .frame(height: topBarHeight)

            // Magpie `.nav-top-hl` follower container:
            // One persistent shape sliding from row to row on NAV_SPRING (response: 0.42, damping: 0.84)
            VStack(spacing: 2) {
                sidebarRow(tab: .download, title: "下载", count: "\(vm.downloadTasks.filter { !$0.isArchived }.count)")
                sidebarRow(tab: .unpack,   title: "解压", count: "\(vm.unpackTasks.filter { !$0.isArchived }.count)")
                sidebarRow(tab: .patch,    title: "补丁", count: "\(vm.patchTasks.filter { !$0.isArchived }.count)")

                Rectangle()
                    .fill(Color.t3SidebarBorder)
                    .frame(height: 1)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)

                sidebarRow(tab: .settings, title: "设置", count: "")
            }
            .padding(.horizontal, 10)
            .backgroundPreferenceValue(SidebarTabBoundsKey.self) { bounds in
                GeometryReader { proxy in
                    if let anchor = bounds[effectiveSidebarTab] {
                        let rect = proxy[anchor]
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.t3SidebarActive)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .animation(.spring(response: 0.42, dampingFraction: 0.84), value: effectiveSidebarTab)
                    }
                }
            }

            Spacer()

            Rectangle()
                .fill(Color.t3SidebarBorder)
                .frame(height: 1)

            Button(action: {
                vm.autoRelay.toggle()
                vm.appendLog("config ▸ 自动流转: \(vm.autoRelay ? "开启" : "关闭")", highlight: false)
            }) {
                HStack(alignment: .center, spacing: 0) {
                    Text("自动流转")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.t3TextSub)
                    Spacer()
                    T3ToggleSwitch(isOn: vm.autoRelay)
                }
                .padding(.horizontal, 18)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Color.t3SidebarBg)
    }

    private func sidebarRow(tab: StudioTab, title: String, count: String) -> some View {
        let isHighlighted = (effectiveSidebarTab == tab)
        let isHovered = (hoveredSidebarTab == tab && !isHighlighted)

        return HStack(alignment: .center, spacing: 9) {
            T3SidebarIcon(tab: tab, size: 17)
                .frame(width: 18, height: 18, alignment: .center)

            Text(title)
                .font(.system(size: 14.5, weight: isHighlighted ? .semibold : .medium))
                .foregroundStyle(
                    isHovered
                        ? AnyShapeStyle(
                            RadialGradient(
                                colors: [Color.black, Color.t3TextMain.opacity(0.88)],
                                center: UnitPoint(x: min(max((hoverSidebarX - 35) / 60, 0), 1), y: 0.5),
                                startRadius: 2,
                                endRadius: 42
                            )
                        )
                        : AnyShapeStyle(isHighlighted ? Color.t3TextMain : Color.t3TextMain.opacity(0.86))
                )

            Spacer(minLength: 0)

            Text(count)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundColor(isHighlighted ? .t3TextMain.opacity(0.75) : .t3TextSub)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .contentShape(Rectangle())
        .anchorPreference(key: SidebarTabBoundsKey.self, value: .bounds) { [tab: $0] }
        .onContinuousHover { phase in
            switch phase {
            case .active(let loc):
                hoveredSidebarTab = tab
                withAnimation(.linear(duration: 0.08)) {
                    hoverSidebarX = loc.x
                }
            case .ended:
                if hoveredSidebarTab == tab {
                    hoveredSidebarTab = nil
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let rowBounds = CGRect(x: -4, y: -4, width: 174, height: 38)
                    if rowBounds.contains(value.location) {
                        if pressingSidebarTab != tab {
                            pressingSidebarTab = tab
                        }
                    } else if pressingSidebarTab == tab {
                        pressingSidebarTab = nil
                    }
                }
                .onEnded { value in
                    let rowBounds = CGRect(x: -4, y: -4, width: 174, height: 38)
                    if rowBounds.contains(value.location) {
                        vm.activeTab = tab
                    }
                    pressingSidebarTab = nil
                }
        )
        .animation(.easeOut(duration: 0.18), value: isHighlighted)
        .animation(.easeOut(duration: 0.18), value: isHovered)
    }

    // MARK: Main Canvas
    private var mainCanvasView: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: topBarHeight)

                pageHeader
                    .frame(height: 30)
                    .padding(.bottom, 12)

                Group {
                    if vm.activeTab == .settings {
                        settingsSectionView
                    } else {
                        topDropZone
                            .padding(.bottom, 16)

                        taskListView
                    }
                }
                .id(vm.activeTab)
                .transition(.opacity.animation(.easeOut(duration: 0.16)))

                Spacer(minLength: 10)

                // Bottom Log Section (hidden on Settings tab)
                if vm.activeTab != .settings {
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

                        logBoxView
                    }
                }
            }
            .padding(.horizontal, 34)
            .padding(.bottom, 14)

            Rectangle()
                .fill(Color.t3Divider)
                .frame(height: 1)

            HStack(spacing: 62) {
                Button(action: { vm.pickFileForActiveTab() }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)

                Button(action: {
                    vm.activeTab = .settings
                    vm.settingsCategory = .unpack
                }) {
                    Image(systemName: "tag")
                        .foregroundColor(vm.activeTab == .settings && vm.settingsCategory == .unpack ? .t3Blue : .t3TextSub)
                }
                .buttonStyle(.plain)

                Button(action: {
                    let dl = ("~/Downloads" as NSString).expandingTildeInPath
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dl)
                }) {
                    Image(systemName: "arrow.right")
                }
                .buttonStyle(.plain)

                Button(action: {
                    let bottles = ("~/Library/Application Support/CrossOver/Bottles" as NSString).expandingTildeInPath
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: bottles)
                }) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.plain)

                Button(action: {
                    vm.activeTab = .settings
                }) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundColor(vm.activeTab == .settings ? .t3Blue : .t3TextSub)
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 13.5, weight: .medium))
            .foregroundColor(.t3TextSub)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
        }
    }

    private var settingsSectionView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Secondary Category Menu Bar with Magpie `.seg > .thumb` shared gliding capsule
            HStack(spacing: 6) {
                ForEach(SettingsCategory.allCases) { cat in
                    settingsCategoryPill(cat)
                }
                Spacer()
            }
            .backgroundPreferenceValue(SettingsCategoryBoundsKey.self) { bounds in
                GeometryReader { proxy in
                    if let anchor = bounds[effectiveSettingsCategory] {
                        let rect = proxy[anchor]
                        Capsule(style: .continuous)
                            .fill(Color(red: 0.675, green: 0.706, blue: 0.753))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .animation(.spring(response: 0.30, dampingFraction: 0.86), value: effectiveSettingsCategory)
                    }
                }
            }
            .padding(.bottom, 12)
            .overlay(
                Rectangle()
                    .fill(Color.t3Divider)
                    .frame(height: 1),
                alignment: .bottom
            )
            .padding(.bottom, 16)

            Group {
                switch vm.settingsCategory {
                case .appearance:
                    settingsAppearanceView
                case .download:
                    settingsDownloadView
                case .unpack:
                    settingsUnpackPasswordView
                case .patch:
                    settingsPatchView
                }
            }
            .id(vm.settingsCategory)
            .transition(.opacity.animation(.easeOut(duration: 0.14)))
        }
    }

    private func settingsCategoryPill(_ cat: SettingsCategory) -> some View {
        let isHighlighted = (effectiveSettingsCategory == cat)
        let isHovered = (hoveredSettingsCategory == cat && !isHighlighted)

        return Text(cat.rawValue)
            .font(.system(size: 12, weight: isHighlighted ? .semibold : .medium))
            .foregroundColor(
                isHighlighted
                    ? .white
                    : (isHovered ? .t3TextMain : .t3TextSub)
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 3.5)
            .contentShape(Rectangle())
            .anchorPreference(key: SettingsCategoryBoundsKey.self, value: .bounds) { [cat: $0] }
            .onHover { hovering in
                if hovering {
                    hoveredSettingsCategory = cat
                } else if hoveredSettingsCategory == cat {
                    hoveredSettingsCategory = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let pillBounds = CGRect(x: -4, y: -4, width: 64, height: 32)
                        if pillBounds.contains(value.location) {
                            if pressingSettingsCategory != cat {
                                pressingSettingsCategory = cat
                            }
                        } else if pressingSettingsCategory == cat {
                            pressingSettingsCategory = nil
                        }
                    }
                    .onEnded { value in
                        let pillBounds = CGRect(x: -4, y: -4, width: 64, height: 32)
                        if pillBounds.contains(value.location) {
                            vm.settingsCategory = cat
                        }
                        pressingSettingsCategory = nil
                    }
            )
            .animation(.easeOut(duration: 0.16), value: isHighlighted)
            .animation(.easeOut(duration: 0.16), value: isHovered)
    }

    private var settingsAppearanceView: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)

        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(vm.iconOptions) { opt in
                let isSelected = (vm.selectedIconID == opt.id)
                Button(action: {
                    vm.applyAppIcon(id: opt.id, variant: vm.selectedIconVariant)
                }) {
                    ZStack {
                        if let nsImg = NSImage(contentsOfFile: vm.iconPreviewPath(id: opt.id, variant: vm.selectedIconVariant)) {
                            Image(nsImage: nsImg)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 58, height: 58)
                        } else {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Color.t3TopBoxBg)
                                .frame(width: 58, height: 58)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 80)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? Color.t3Blue.opacity(0.06) : Color.t3TopBoxBg.opacity(0.65))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(isSelected ? Color.t3Blue : Color.t3Divider, lineWidth: isSelected ? 1.8 : 1)
                            )
                    )
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            ZStack {
                                Circle()
                                    .fill(Color.t3Blue)
                                    .frame(width: 16, height: 16)
                                    .shadow(color: Color.black.opacity(0.15), radius: 2, x: 0, y: 1)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .padding(5)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var settingsDownloadView: some View {
        VStack(alignment: .leading, spacing: 0) {
            t3SettingRow(title: "下载目录") {
                Button(action: {
                    let dl = ("~/Downloads" as NSString).expandingTildeInPath
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dl)
                }) {
                    T3OutlinedPill(text: "~/Downloads", icon: "folder")
                }
                .buttonStyle(.plain)
            }
            t3SettingRow(title: "并发连接") {
                T3OutlinedPill(text: "16")
            }
        }
    }

    private var settingsUnpackPasswordView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                if !isSnapshotMode {
                    TextField("添加解压密码...", text: $vm.newPasswordInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundColor(.t3TextMain)
                        .onSubmit { vm.addPassword() }

                    if !vm.newPasswordInput.isEmpty {
                        Button(action: { vm.newPasswordInput = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.t3TextMuted)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("添加解压密码...")
                        .font(.system(size: 12.5))
                        .foregroundColor(.t3TextSub)
                    Spacer()
                }

                Button(action: { vm.addPassword() }) {
                    Text("+ 添加")
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

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(vm.passwords.enumerated()), id: \.offset) { idx, pwd in
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.t3TextMuted)
                            .frame(width: 16, alignment: .center)

                        Text(pwd)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.t3TextMain)

                        Spacer()

                        Button(action: { vm.removePassword(at: idx) }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.t3TextMuted)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .overlay(
                        Rectangle()
                            .fill(Color.t3Divider)
                            .frame(height: 1),
                        alignment: .bottom
                    )
                }
            }
        }
    }

    private var settingsPatchView: some View {
        VStack(alignment: .leading, spacing: 0) {
            t3SettingRow(title: "容器目录") {
                Button(action: {
                    let bottles = ("~/Library/Application Support/CrossOver/Bottles" as NSString).expandingTildeInPath
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: bottles)
                }) {
                    T3OutlinedPill(text: "CrossOver Bottles", icon: "folder")
                }
                .buttonStyle(.plain)
            }
            t3SettingRow(title: "默认语言") {
                T3OutlinedPill(text: "schinese")
            }
            t3SettingRow(title: "自动流转") {
                Button(action: {
                    vm.autoRelay.toggle()
                }) {
                    T3ToggleSwitch(isOn: vm.autoRelay)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func t3SettingRow<Trailing: View>(title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundColor(.t3TextMain)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .overlay(
            Rectangle()
                .fill(Color.t3Divider)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            T3SidebarIcon(tab: vm.activeTab, size: 23)
                .frame(width: 24, height: 24, alignment: .center)

            switch vm.activeTab {
            case .download:
                Text("下载")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.t3TextMain)
            case .unpack:
                Text("解压")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.t3TextMain)
            case .patch:
                Text("补丁")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.t3TextMain)
            case .settings:
                Text("设置")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.t3TextMain)
            }

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

    private func headerProgress(for list: [StudioTask]) -> Double {
        guard !list.isEmpty else { return 0.0 }
        var total = 0.0
        for item in list {
            switch item.status {
            case .queued, .failed: total += 0.0
            case .running(let p), .locked(let p): total += p
            case .done: total += 1.0
            }
        }
        return max(0.05, total / Double(list.count))
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

    private var activeTabColor: Color {
        switch vm.activeTab {
        case .download: return .t3Blue
        case .unpack:   return .t3Amber
        case .patch:    return .t3Green
        case .settings: return Color(red: 0.388, green: 0.400, blue: 0.945)
        }
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
        let rawList: [StudioTask] = {
            switch vm.activeTab {
            case .download: return vm.downloadTasks
            case .unpack:   return vm.unpackTasks
            case .patch, .settings: return vm.patchTasks
            }
        }()
        if vm.showArchived {
            return rawList
        }
        return rawList.filter { !$0.isArchived }
    }

    @ViewBuilder
    private var taskListView: some View {
        if isSnapshotMode {
            taskListContent
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                taskListContent
            }
        }
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
                            .foregroundColor(
                                {
                                    if row.isArchived {
                                        return Color.t3TextMuted
                                    }
                                    if case .done = row.status, vm.activeTab != .patch {
                                        return Color.t3TextMuted
                                    }
                                    return Color.t3TextMain
                                }()
                            )
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
                        }

                        if vm.activeTab == .patch {
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
                        if vm.activeTab == .patch,
                           let idx = vm.patchTasks.firstIndex(where: { $0.id == row.id }) {
                            vm.patchTasks[idx].expanded.toggle()
                        }
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
                            ForEach(Array(row.checklist.enumerated()), id: \.element.id) { cIdx, item in
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
                                    if let pIdx = vm.patchTasks.firstIndex(where: { $0.id == row.id }) {
                                        vm.patchTasks[pIdx].checklist[cIdx].isChecked.toggle()
                                    }
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

        Button(role: .destructive, action: { vm.deleteTask(row, deleteLocalFile: false) }) {
            Label("删除记录", systemImage: "trash")
        }

        if let local = row.localPath, FileManager.default.fileExists(atPath: local) {
            Button(role: .destructive, action: { vm.deleteTask(row, deleteLocalFile: true) }) {
                Label("删除记录及本地文件", systemImage: "trash.fill")
            }
        }
    }

    private var logBoxView: some View {
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
