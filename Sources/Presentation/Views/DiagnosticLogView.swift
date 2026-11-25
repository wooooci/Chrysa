import ChrysaCore
import ChrysaApplication
import SwiftUI
import AppKit

// MARK: - Minimal Adaptive Log Palette (Native Chrysa Flat Hierarchy)
private enum LogTone {
    static let textPrimary     = Color.t3TextMain
    static let textSecondary   = Color.t3TextSub
    static let textMuted       = Color.t3TextMuted
    static let textDim         = Color.t3TextMuted.opacity(0.65)

    static let okAccent        = Color.t3Green
    static let warnText        = Color.t3WarningText
    static let warnAccent      = Color.t3Amber
    static let warnRowTint     = Color.t3Amber.opacity(0.055)
    static let errorText       = Color.t3ErrorText
    static let errorRowTint    = Color.t3ErrorPillBg.opacity(0.45)

    static func deltaColor(_ seconds: TimeInterval) -> Color {
        if seconds >= 60.0 { return warnText }
        if seconds >= 20.0 { return textSecondary }
        return textDim
    }
}

// MARK: - Global Diagnostic Log Drawer (Flat Two-Layer Tabular View)
struct GlobalLogDrawerView: View {
    @ObservedObject var vm: StudioViewModel
    var isSnapshotMode: Bool = false
    @Environment(\.appTheme) private var theme
    @FocusState private var isLogSearchFocused: Bool

    @State private var hoveredFilter: LogFilterID? = nil
    @State private var isErrorsFilterHovered = false
    @State private var dragStartHeight: CGFloat? = nil
    @State private var copiedAllFeedback = false
    @State private var hoveredRowID: UUID? = nil
    @State private var copiedRowID: UUID? = nil
    @State private var expandedRawIDs: Set<UUID> = []

    private static let minDrawerHeight: CGFloat = 170
    private static let maxDrawerHeight: CGFloat = 460
    private static let defaultDrawerHeight: CGFloat = 260

    private enum LogFilterID: Hashable {
        case all
        case module(LogModule)
    }

    private var activeLogFilter: LogFilterID? {
        if let mod = vm.logModuleFilter {
            return .module(mod)
        }
        return vm.logErrorsOnly ? nil : .all
    }

    private struct PreparedRow: Identifiable {
        let entry: LogEntry
        let index: Int
        let resolvedDate: Date?
        let dateHeader: String?
        let deltaSeconds: TimeInterval?
        let taskTitle: String?
        var id: UUID { entry.id }
    }

    private func prepareRows(from entries: [LogEntry]) -> [PreparedRow] {
        var result: [PreparedRow] = []
        result.reserveCapacity(entries.count)
        var lastDateStr: String? = nil
        var lastDate: Date? = nil

        for (idx, entry) in entries.enumerated() {
            let resolved = vm.resolvedTimestampDate(for: entry)
            let dateStr = vm.resolvedDateString(for: entry)
            let showDateHeader: String? = {
                guard let dateStr else { return nil }
                if let prev = lastDateStr, prev != dateStr {
                    return dateStr
                }
                return nil
            }()

            let delta: TimeInterval? = {
                guard let curr = resolved, let prev = lastDate else { return nil }
                let diff = curr.timeIntervalSince(prev)
                guard diff >= 0, diff < 86_400 else { return nil }
                return diff
            }()

            result.append(PreparedRow(
                entry: entry,
                index: idx,
                resolvedDate: resolved,
                dateHeader: showDateHeader,
                deltaSeconds: delta,
                taskTitle: vm.taskTitle(for: entry.taskID)
            ))
            lastDateStr = dateStr ?? lastDateStr
            lastDate = resolved ?? lastDate
        }
        return result
    }

    var body: some View {
        let entries = vm.filteredGlobalLogs
        let prepared = prepareRows(from: entries)
        let totalCount = vm.logs.count
        let errorCount = vm.logs.filter { $0.displayLevel == .error }.count

        VStack(alignment: .leading, spacing: 0) {
            // Layer 1: Single Unified Control Bar (top edge draggable to resize)
            toolbar(totalCount: totalCount, errorCount: errorCount)
                .overlay(alignment: .top) {
                    topEdgeResizeStrip
                }

            Rectangle()
                .fill(Color.t3Divider)
                .frame(height: 1)

            // Layer 2: Flat Full-Bleed Structured Log Table
            columnHeader(shownCount: entries.count, totalCount: totalCount)

            Rectangle()
                .fill(Color.t3Divider.opacity(0.75))
                .frame(height: 1)

            if prepared.isEmpty {
                emptyState(totalCount: totalCount)
            } else if isSnapshotMode {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.t3CanvasBg)
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(prepared) { row in
                                if let banner = row.dateHeader {
                                    dateSeparator(banner)
                                }
                                logRow(row)
                            }
                        }
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .bottomLeading)
                    }
                    .clipped()
                    .layoutPriority(1)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(prepared) { row in
                                if let banner = row.dateHeader {
                                    dateSeparator(banner)
                                }
                                logRow(row)
                                    .id(row.id)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                    .background(Color.t3CanvasBg)
                    .onAppear {
                        if vm.logAutoScrollEnabled, let lastID = prepared.last?.id {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                    .onChange(of: entries.last?.id) { _, newLastID in
                        guard vm.logAutoScrollEnabled, let newLastID else { return }
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(newLastID, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.t3CanvasBg)
        .clipped()
        .onChange(of: vm.searchFocusNonce) { _, _ in
            if vm.isLogDrawerPresented && vm.activeTab != .launch && !isSnapshotMode {
                isLogSearchFocused = true
            }
        }
    }

    // Invisible 5pt top edge for smooth vertical resizing without consuming layout height
    private var topEdgeResizeStrip: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 5)
            .contentShape(Rectangle())
            .onHover { hovering in
                guard !isSnapshotMode else { return }
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartHeight == nil {
                            dragStartHeight = vm.logDrawerHeight
                        }
                        let base = dragStartHeight ?? vm.logDrawerHeight
                        let proposed = base - value.translation.height
                        vm.logDrawerHeight = min(Self.maxDrawerHeight, max(Self.minDrawerHeight, proposed))
                    }
                    .onEnded { _ in
                        dragStartHeight = nil
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(ChrysaMotion.foldOpen) {
                    vm.logDrawerHeight = Self.defaultDrawerHeight
                }
            }
    }

    private func toolbar(totalCount: Int, errorCount: Int) -> some View {
        HStack(alignment: .center, spacing: 6) {
            HStack(alignment: .center, spacing: 3) {
                filterPill(id: .all, title: "全部", isSelected: activeLogFilter == .all) {
                    vm.logModuleFilter = nil
                    vm.logErrorsOnly = false
                    vm.logWarningsAndErrorsOnly = false
                }
                ForEach(LogModule.allCases) { mod in
                    let id = LogFilterID.module(mod)
                    filterPill(id: id, title: mod.label, isSelected: activeLogFilter == id) {
                        vm.logModuleFilter = (vm.logModuleFilter == mod) ? nil : mod
                    }
                }
            }
            .backgroundPreferenceValue(SelectionBoundsKey<LogFilterID>.self) { bounds in
                GeometryReader { proxy in
                    if let active = activeLogFilter, let anchor = bounds[active] {
                        let rect = proxy[anchor]
                        let useAccent = theme.mode != .monochrome
                        RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                            .fill(useAccent ? theme.accent : Color.t3ControlSelectedFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                                    .stroke(useAccent ? Color.clear : Color.t3ControlSelectedStroke, lineWidth: 0.75)
                            )
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .animation(isSnapshotMode ? nil : ChrysaMotion.tabGlide, value: activeLogFilter)
                    }
                }
            }

            Rectangle()
                .fill(Color.t3Divider)
                .frame(width: 1, height: 12)
                .padding(.horizontal, 1)

            // Single clean Error filter chip
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.t3ErrorText)
                    .frame(width: 5, height: 5)
                Text("仅错误")
                    .font(.system(size: 11, weight: vm.logErrorsOnly ? .semibold : .regular))
                    .foregroundColor(vm.logErrorsOnly ? .t3ErrorText : (isErrorsFilterHovered ? .t3TextMain : .t3TextSub))
                if errorCount > 0 {
                    Text("\(errorCount)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced).monospacedDigit())
                        .foregroundColor(vm.logErrorsOnly ? .t3ErrorText : .t3TextMuted)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                    .fill(vm.logErrorsOnly ? Color.t3ErrorPillBg : (isErrorsFilterHovered ? Color.t3HoverBg : Color.clear))
                    .animation(vm.logErrorsOnly ? ChrysaMotion.tabGlide : ChrysaMotion.hover(isErrorsFilterHovered), value: vm.logErrorsOnly)
            )
            .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous))
            .onHover { isErrorsFilterHovered = $0 }
            .onInstantPress {
                vm.logErrorsOnly.toggle()
                vm.logWarningsAndErrorsOnly = false
            }
            .help("仅查看错误日志")

            Spacer(minLength: 6)

            // Search box
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isLogSearchFocused ? theme.accent : .t3TextMuted)
                if !isSnapshotMode {
                    TextField("搜索", text: $vm.logSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.t3TextMain)
                        .focused($isLogSearchFocused)
                        .frame(width: 108)
                } else {
                    Text("搜索")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.t3TextMuted)
                        .frame(width: 108, alignment: .leading)
                }
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
            .frame(height: 23)
            .background(
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                    .fill(Color.t3TopBoxBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                    .stroke(isLogSearchFocused ? theme.accent.opacity(0.45) : Color.t3TopBoxBorder, lineWidth: 0.8)
            )

            // 3 Essential Actions: Copy, Clear, Close
            HStack(spacing: 2) {
                DrawerToolButton(
                    systemName: copiedAllFeedback ? "checkmark" : "doc.on.doc",
                    isActive: copiedAllFeedback,
                    tooltip: "复制当前日志"
                ) {
                    vm.copyGlobalLogs()
                    copiedAllFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copiedAllFeedback = false
                    }
                }

                DrawerToolButton(
                    systemName: "trash",
                    isActive: false,
                    tooltip: "清空日志"
                ) {
                    vm.clearLogs()
                }

                DrawerToolButton(
                    systemName: "chevron.down",
                    isActive: false,
                    tooltip: "收起日志 (⇧⌘L)"
                ) {
                    vm.isLogDrawerPresented = false
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 34)
        .background(Color.t3CanvasBg)
    }

    private func columnHeader(shownCount: Int, totalCount: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("时间戳")
                .frame(width: 158, alignment: .leading)
            Text("耗时")
                .frame(width: 46, alignment: .trailing)
            Text("模块")
                .frame(width: 46, alignment: .leading)
            Text("事件详情")
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(shownCount == totalCount ? "\(totalCount) 条" : "\(shownCount) / \(totalCount) 条")
                .font(.system(size: 10, weight: .regular, design: .monospaced).monospacedDigit())
                .foregroundColor(LogTone.textDim)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundColor(LogTone.textMuted)
        .padding(.horizontal, 20)
        .frame(height: 22)
        .background(Color.t3GroupedCardBg.opacity(0.65))
    }

    private func emptyState(totalCount: Int) -> some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            Text(totalCount == 0 ? "暂无日志记录" : "无匹配日志")
                .font(ChrysaFont.captionMedium)
                .foregroundColor(.t3TextSub)
            Text(totalCount == 0 ? "下载、解压、补丁与启动过程会按精确时间记录于此" : "尝试切换筛选或清空搜索关键词")
                .font(.system(size: 11))
                .foregroundColor(.t3TextMuted)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }

    private func dateSeparator(_ dateStr: String) -> some View {
        let today = LogEntry.formatDateString(date: Date())
        let label = (dateStr == today) ? "\(dateStr) · 今天" : dateStr
        return HStack(spacing: 8) {
            Rectangle()
                .fill(Color.t3Divider)
                .frame(width: 14, height: 1)
            Text(label)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced).monospacedDigit())
                .foregroundColor(LogTone.textMuted)
            Rectangle()
                .fill(Color.t3Divider)
                .frame(maxWidth: .infinity, maxHeight: 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
    }

    private func logRow(_ row: PreparedRow) -> some View {
        let entry = row.entry
        let level = entry.displayLevel
        let isHovered = (hoveredRowID == entry.id && !isSnapshotMode)
        let isCopied = (copiedRowID == entry.id)

        let rowBg: Color = {
            if isHovered { return Color.t3HoverBg }
            if level == .error { return LogTone.errorRowTint }
            if level == .warning { return LogTone.warnRowTint }
            return Color.clear
        }()

        let railColor: Color = {
            switch level {
            case .error:   return LogTone.errorText.opacity(0.85)
            case .warning: return LogTone.warnAccent.opacity(0.85)
            case .info:    return Color.clear
            }
        }()

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // 1. Concrete Timestamp (YYYY-MM-DD HH:mm:ss.SSS)
                timestampCell(entry: entry)
                    .frame(width: 158, alignment: .leading)

                // 2. Step Elapsed Delta
                Group {
                    if let delta = row.deltaSeconds {
                        Text(LogEntry.formatDelta(delta))
                            .foregroundColor(LogTone.deltaColor(delta))
                    } else {
                        Text("·")
                            .foregroundColor(LogTone.textDim.opacity(0.45))
                    }
                }
                .font(.system(size: 10, design: .monospaced).monospacedDigit())
                .frame(width: 46, alignment: .trailing)

                // 3. Combined Status Glyph + Module Label (clean, single column, zero double-pill noise)
                HStack(spacing: 5) {
                    LogLevelGlyph(entry: entry)
                        .frame(width: 10, alignment: .center)
                    Text(entry.module.label)
                        .font(.system(size: 10.5, weight: level == .error ? .semibold : .medium))
                        .foregroundColor(level == .error ? LogTone.errorText : (level == .warning ? LogTone.warnText : LogTone.textSecondary))
                }
                .frame(width: 46, alignment: .leading)

                // 4. Event Message (wide, airy, 1-line whenever possible)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    LogMessageText(entry: entry)
                        .lineSpacing(1.5)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if isHovered || isCopied {
                        Button(action: {
                            vm.copySingleLog(entry)
                            copiedRowID = entry.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                                if copiedRowID == entry.id { copiedRowID = nil }
                            }
                        }) {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(isCopied ? theme.accent : LogTone.textMuted)
                                .frame(width: 18, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("复制此行日志")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let raw = entry.rawOutput, !raw.isEmpty {
                rawOutputDisclosure(raw: raw, entryID: entry.id, level: level)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4.5)
        .background(rowBg)
        .overlay(alignment: .leading) {
            if railColor != .clear {
                Rectangle()
                    .fill(railColor)
                    .frame(width: 2)
            }
        }
        .help(row.taskTitle.map { "任务：\($0)" } ?? "")
        .onHover { hovering in
            guard !isSnapshotMode else { return }
            if hovering {
                hoveredRowID = entry.id
            } else if hoveredRowID == entry.id {
                hoveredRowID = nil
            }
        }
    }

    @ViewBuilder
    private func timestampCell(entry: LogEntry) -> some View {
        let dateStr = vm.resolvedDateString(for: entry)
        let msStr = entry.millisSuffixString

        let datePrefix: Text = dateStr.map {
            Text($0).foregroundColor(LogTone.textDim) + Text(" ")
        } ?? Text("")
        let timeBody = Text(entry.time).foregroundColor(LogTone.textSecondary)
        let msPart: Text = msStr.map { Text($0).foregroundColor(LogTone.textDim) } ?? Text("")

        (datePrefix + timeBody + msPart)
            .font(.system(size: 10.5, weight: .regular, design: .monospaced).monospacedDigit())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func rawOutputDisclosure(raw: String, entryID: UUID, level: LogLevel) -> some View {
        let isExpanded = expandedRawIDs.contains(entryID)
        let lineCount = raw.components(separatedBy: "\n").count
        let accentText = (level == .error) ? LogTone.errorText : LogTone.warnText

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: {
                    if isExpanded {
                        expandedRawIDs.remove(entryID)
                    } else {
                        expandedRawIDs.insert(entryID)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundColor(accentText)
                        Text("原始输出")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(accentText)
                        Text("(\(lineCount) 行)")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundColor(LogTone.textMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(raw, forType: .string)
                }) {
                    Text("复制")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(LogTone.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)

            if isExpanded {
                Rectangle().fill(Color.t3Divider).frame(height: 1)
                Text(raw)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(LogTone.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.t3PreviewWellBg)
        .clipShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                .stroke(Color.t3GroupedCardBorder, lineWidth: 0.75)
        )
        .padding(.leading, 214)
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    private func filterPill(id: LogFilterID, title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        let useAccent = isSelected && theme.mode != .monochrome
        let isHovered = (hoveredFilter == id && !isSelected)
        return Text(title)
            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            .foregroundColor(useAccent ? theme.accentForeground : (isSelected || isHovered ? .t3TextMain : .t3TextSub))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                    .fill(isHovered ? Color.t3HoverBg : Color.clear)
                    .animation(ChrysaMotion.hover(isHovered), value: isHovered)
            )
            .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous))
            .anchorPreference(key: SelectionBoundsKey<LogFilterID>.self, value: .bounds) { [id: $0] }
            .onHover { hovering in
                guard !isSnapshotMode else { return }
                if hovering {
                    hoveredFilter = id
                } else if hoveredFilter == id {
                    hoveredFilter = nil
                }
            }
            .onInstantPress(action)
            .animation(isSnapshotMode ? nil : ChrysaMotion.tabGlide, value: isSelected)
    }
}

// MARK: - Inline Per-Task Log Section (Compact, Flat, Adaptive)
struct TaskLogTerminalView: View {
    @ObservedObject var vm: StudioViewModel
    let taskID: UUID
    let taskLogs: [LogEntry]
    let rawErrorText: String?
    var isSnapshotMode: Bool = false
    @Environment(\.appTheme) private var theme
    @State private var showRawOutput = false
    @State private var copiedFeedback = false

    private var hasRaw: Bool {
        rawErrorText != nil && !(rawErrorText?.isEmpty ?? true)
    }

    private var headerDateLabel: String? {
        let dates = Set(taskLogs.compactMap { vm.resolvedDateString(for: $0) })
        return dates.count == 1 ? dates.first : nil
    }

    private var spansMultipleDays: Bool {
        Set(taskLogs.compactMap { vm.resolvedDateString(for: $0) }).count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text("运行日志")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(LogTone.textSecondary)

                if let day = headerDateLabel {
                    Text(day)
                        .font(.system(size: 10, design: .monospaced).monospacedDigit())
                        .foregroundColor(LogTone.textMuted)
                }

                Spacer(minLength: 6)

                if hasRaw {
                    HStack(spacing: 6) {
                        inlineModeButton("记录", active: !showRawOutput) { showRawOutput = false }
                        inlineModeButton("原始输出", active: showRawOutput) { showRawOutput = true }
                    }
                }

                Button(action: {
                    vm.copyTaskLogs(taskID: taskID, includeRawOnly: showRawOutput)
                    copiedFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                        copiedFeedback = false
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9.5, weight: .medium))
                        Text(copiedFeedback ? "已复制" : "复制")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(copiedFeedback ? theme.accent : LogTone.textMuted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("复制任务日志")
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.t3GroupedCardBg)

            Rectangle().fill(Color.t3Divider).frame(height: 1)

            if showRawOutput, let rawErrorText {
                if isSnapshotMode {
                    Text(rawErrorText)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(LogTone.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(Color.t3PreviewWellBg)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(rawErrorText)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(LogTone.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(9)
                    }
                    .frame(maxHeight: 155)
                    .background(Color.t3PreviewWellBg)
                }
            } else {
                let rowsStack = VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(taskLogs.enumerated()), id: \.element.id) { idx, line in
                        let currDate = vm.resolvedTimestampDate(for: line)
                        let prevDate = idx > 0 ? vm.resolvedTimestampDate(for: taskLogs[idx - 1]) : nil
                        let delta: TimeInterval? = {
                            guard let c = currDate, let p = prevDate else { return nil }
                            let d = c.timeIntervalSince(p)
                            return (d >= 0 && d < 86_400) ? d : nil
                        }()
                        inlineLogRow(line: line, delta: delta)
                    }
                }
                .padding(.vertical, 4)

                if isSnapshotMode {
                    rowsStack
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.t3CardBg)
                } else {
                    ViewThatFits(in: .vertical) {
                        rowsStack
                        ScrollView(.vertical, showsIndicators: true) {
                            rowsStack
                        }
                        .frame(height: 165)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.t3CardBg)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                .stroke(Color.t3GroupedCardBorder, lineWidth: 0.85)
        )
    }

    private func inlineModeButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: active ? .semibold : .regular))
                .foregroundColor(active ? theme.accent : LogTone.textMuted)
        }
        .buttonStyle(.plain)
    }

    private func inlineLogRow(line: LogEntry, delta: TimeInterval?) -> some View {
        let level = line.displayLevel
        let rowBg: Color = {
            if level == .error { return LogTone.errorRowTint }
            if level == .warning { return LogTone.warnRowTint }
            return Color.clear
        }()

        let shortDatePrefix: Text = {
            guard spansMultipleDays,
                  let shortDate = line.shortDatePartString ?? vm.resolvedTimestampDate(for: line).map({ LogEntry.formatShortDateString(date: $0) }) else {
                return Text("")
            }
            return Text(shortDate).foregroundColor(LogTone.textDim) + Text(" ")
        }()
        let timeMain = Text(line.time).foregroundColor(LogTone.textSecondary)
        let msPart: Text = line.millisSuffixString.map { Text($0).foregroundColor(LogTone.textDim) } ?? Text("")

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            (shortDatePrefix + timeMain + msPart)
                .font(.system(size: 10, design: .monospaced).monospacedDigit())
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: spansMultipleDays ? 116 : 80, alignment: .leading)
                .help(line.fullTimestampString)

            Group {
                if let delta {
                    Text(LogEntry.formatDelta(delta))
                        .foregroundColor(LogTone.deltaColor(delta))
                } else {
                    Text("·")
                        .foregroundColor(LogTone.textDim.opacity(0.45))
                }
            }
            .font(.system(size: 9.5, design: .monospaced).monospacedDigit())
            .frame(width: 46, alignment: .trailing)

            LogLevelGlyph(entry: line)
                .frame(width: 10, alignment: .center)

            LogMessageText(entry: line, fontSize: 10.5)
                .lineSpacing(1.5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3.5)
        .background(rowBg)
        .overlay(alignment: .leading) {
            if level == .error || level == .warning {
                Rectangle()
                    .fill(level == .error ? LogTone.errorText.opacity(0.85) : LogTone.warnAccent.opacity(0.85))
                    .frame(width: 2)
            }
        }
    }
}

// MARK: - Minimal Shared Glyphs & Typography
private struct LogLevelGlyph: View {
    let entry: LogEntry

    var body: some View {
        switch entry.displayLevel {
        case .error:
            Text("✗")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundColor(LogTone.errorText)
        case .warning:
            Text("▲")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(LogTone.warnText)
        case .info:
            if entry.isSuccessMilestone {
                Text("✓")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(LogTone.okAccent.opacity(0.9))
            } else {
                Text("·")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(LogTone.textDim)
            }
        }
    }
}

private struct LogMessageText: View {
    let entry: LogEntry
    var fontSize: CGFloat = 11

    var body: some View {
        let level = entry.displayLevel
        let bodyColor: Color = {
            switch level {
            case .error:   return LogTone.errorText
            case .warning: return LogTone.warnText
            case .info:    return LogTone.textPrimary
            }
        }()

        if let parsed = entry.parsedStagePrefix {
            let lowerTag = parsed.tag.lowercased()
            let hideRedundantLevelTag = (lowerTag == "error" && level == .error) || (lowerTag == "warn" && level == .warning)
            if hideRedundantLevelTag {
                Text(parsed.body)
                    .font(.system(size: fontSize, weight: level == .error ? .medium : .regular, design: .monospaced))
                    .foregroundColor(bodyColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                (
                    Text(parsed.tag)
                        .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                        .foregroundColor(LogTone.textSecondary)
                    + Text(" ▸ ")
                        .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                        .foregroundColor(LogTone.textDim)
                    + Text(parsed.body)
                        .font(.system(size: fontSize, weight: level == .error ? .medium : .regular, design: .monospaced))
                        .foregroundColor(bodyColor)
                )
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            }
        } else {
            Text(entry.message)
                .font(.system(size: fontSize, weight: level == .error ? .medium : .regular, design: .monospaced))
                .foregroundColor(bodyColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

private struct DrawerToolButton: View {
    let systemName: String
    let isActive: Bool
    let tooltip: String
    let action: () -> Void
    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10.5, weight: isActive ? .semibold : .medium))
                .foregroundColor(isActive ? theme.accent : (isHovered ? .t3TextMain : .t3TextMuted))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                        .fill(isActive ? theme.accent.opacity(theme.isDark ? 0.16 : 0.10) : (isHovered ? Color.t3HoverBg : Color.clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip)
    }
}
