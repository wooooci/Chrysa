import Foundation

package enum LaunchGameSource: String, Codable, Equatable, Sendable {
    case patchPipeline
    case crossoverScan
    case manualImport
}

package enum LaunchSortOrder: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case lastPlayed
    case name

    package var id: String { rawValue }

    package var label: String {
        switch self {
        case .lastPlayed: return "最近游玩"
        case .name: return "名称"
        }
    }
}

package enum LaunchGameIconPreference: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case automatic
    case steam
    case executable
    case custom

    package var id: String { rawValue }

    package var label: String {
        switch self {
        case .automatic: return "自动"
        case .steam: return "Steam 方形"
        case .executable: return "程序自带"
        case .custom: return "自定义"
        }
    }
}

/// A persistent, ready-to-launch game entry stored independently from transient patch jobs.
package struct LaunchGame: Identifiable, Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id, title, exePath, gameDirectory, bottleName, appID, source, customIconPath, iconPreference, launchArguments, addedAt, updatedAt, lastPlayedAt
    }

    package let id: UUID
    package var title: String
    package var exePath: String?
    package var gameDirectory: String?
    package var bottleName: String?
    package var appID: String?
    package var source: LaunchGameSource
    package var customIconPath: String?
    package var iconPreference: LaunchGameIconPreference
    package var launchArguments: String?
    package let addedAt: Date
    package var updatedAt: Date
    package var lastPlayedAt: Date?

    package init(
        id: UUID = UUID(),
        title: String,
        exePath: String? = nil,
        gameDirectory: String? = nil,
        bottleName: String? = nil,
        appID: String? = nil,
        source: LaunchGameSource = .manualImport,
        customIconPath: String? = nil,
        iconPreference: LaunchGameIconPreference = .automatic,
        launchArguments: String? = nil,
        addedAt: Date = Date(),
        updatedAt: Date? = nil,
        lastPlayedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.exePath = exePath
        self.gameDirectory = gameDirectory
        self.bottleName = bottleName
        self.appID = appID
        self.source = source
        self.customIconPath = customIconPath
        self.iconPreference = iconPreference
        let trimmedArgs = launchArguments?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.launchArguments = (trimmedArgs?.isEmpty == false) ? trimmedArgs : nil
        self.addedAt = addedAt
        self.updatedAt = updatedAt ?? addedAt
        self.lastPlayedAt = lastPlayedAt
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            exePath: try container.decodeIfPresent(String.self, forKey: .exePath),
            gameDirectory: try container.decodeIfPresent(String.self, forKey: .gameDirectory),
            bottleName: try container.decodeIfPresent(String.self, forKey: .bottleName),
            appID: try container.decodeIfPresent(String.self, forKey: .appID),
            source: (try? container.decodeIfPresent(LaunchGameSource.self, forKey: .source)) ?? .manualImport,
            customIconPath: try container.decodeIfPresent(String.self, forKey: .customIconPath),
            iconPreference: (try? container.decodeIfPresent(LaunchGameIconPreference.self, forKey: .iconPreference)) ?? .automatic,
            launchArguments: try container.decodeIfPresent(String.self, forKey: .launchArguments),
            addedAt: addedAt,
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? addedAt,
            lastPlayedAt: try container.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        )
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(exePath, forKey: .exePath)
        try container.encodeIfPresent(gameDirectory, forKey: .gameDirectory)
        try container.encodeIfPresent(bottleName, forKey: .bottleName)
        try container.encodeIfPresent(appID, forKey: .appID)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(customIconPath, forKey: .customIconPath)
        if iconPreference != .automatic {
            try container.encode(iconPreference, forKey: .iconPreference)
        }
        try container.encodeIfPresent(launchArguments, forKey: .launchArguments)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastPlayedAt, forKey: .lastPlayedAt)
    }

    package static func parseLaunchArguments(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var args: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        for ch in trimmed {
            if escaping {
                current.append(ch)
                escaping = false
                continue
            }
            if ch == "\\" && quote != "'" {
                escaping = true
                continue
            }
            if let q = quote {
                if ch == q {
                    quote = nil
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch.isWhitespace {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            args.append(current)
        }
        return args
    }

    package func appendingLaunchArgument(_ flag: String) -> String? {
        let trimmedFlag = flag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFlag.isEmpty else { return launchArguments }
        let existing = (launchArguments ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if existing.isEmpty { return trimmedFlag }
        let tokens = Self.parseLaunchArguments(existing)
        if tokens.contains(where: { $0.caseInsensitiveCompare(trimmedFlag) == .orderedSame }) {
            return existing
        }
        return "\(existing) \(trimmedFlag)"
    }

    package static func relativeSubpath(of childPath: String, inside parentDirectory: String) -> String? {
        guard let canonicalChild = canonicalPath(childPath),
              let canonicalParent = canonicalPath(parentDirectory) else {
            return nil
        }
        let prefix = canonicalParent.hasSuffix("/") ? canonicalParent : canonicalParent + "/"
        guard canonicalChild.hasPrefix(prefix) else { return nil }
        let rel = String(canonicalChild.dropFirst(prefix.count))
        return rel.isEmpty ? nil : rel
    }

    package static func normalizedIdentityTitle(_ raw: String) -> String {
        Job.normalizedPatchIdentityTitle(raw)
    }

    package static func isAntiCheatHelperExecutable(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        let normalized = path.lowercased().replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/").map(String.init)
        let dirComponents = components.dropLast()
        let lower = components.last ?? (path as NSString).lastPathComponent.lowercased()
        let isInAntiCheatDirectory = dirComponents.contains { component in
            component == "easyanticheat"
                || component == "easyanticheat_eos"
                || component == "battleye"
                || component == "eaanticheat"
        }
        return isInAntiCheatDirectory
            || lower == "start_protected_game.exe"
            || lower.contains("easyanticheat")
            || lower.hasSuffix("_be.exe")
            || (lower.hasPrefix("beservice") && lower.hasSuffix(".exe"))
            || lower == "beclient.exe"
            || lower == "beclient_x64.exe"
            || (lower.hasPrefix("eaanticheat") && lower.hasSuffix(".exe"))
    }

    package static func isIgnoredHelperExecutable(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        if isAntiCheatHelperExecutable(path) {
            return true
        }
        let normalized = path.lowercased().replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/").map(String.init)
        let dirComponents = components.dropLast()
        let lower = components.last ?? (path as NSString).lastPathComponent.lowercased()
        let isInRedistDirectory = normalized.contains("__redist")
            || normalized.contains("_commonredist")
            || dirComponents.contains { component in
                component == "redist"
                    || component == "_commonredist"
                    || component == "__redist"
                    || component == "commonredist"
                    || component == "redistributables"
                    || component == "directx"
            }
        return isInRedistDirectory
            || lower.contains("scriptinterpreter")
            || lower.contains("unitycrashhandler")
            || lower.contains("unins")
            || lower.contains("vc_redist")
            || lower.contains("vcredist")
            || lower.contains("dxsetup")
            || lower.contains("dxwebsetup")
            || lower.contains("physx")
            || lower.contains("crashreport")
            || lower.contains("crs-handler")
            || lower.contains("goggalaxy")
            || lower.contains("dosbox")
            || lower.hasPrefix("setup_")
    }

    package static func canonicalPath(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
    }

    package var suppressionKey: String {
        if let bottle = bottleName?.trimmingCharacters(in: .whitespacesAndNewlines), !bottle.isEmpty {
            let normBottle = Self.normalizedIdentityTitle(bottle)
            if !normBottle.isEmpty { return "bottle:\(normBottle)" }
        }
        if let exe = Self.canonicalPath(exePath) {
            return "exe:\(exe.lowercased())"
        }
        if let dir = Self.canonicalPath(gameDirectory) {
            return "dir:\(dir.lowercased())"
        }
        return "title:\(Self.normalizedIdentityTitle(title))"
    }

    package var allSuppressionKeys: [String] {
        var keys = [suppressionKey]
        let normTitle = Self.normalizedIdentityTitle(title)
        if !normTitle.isEmpty {
            let titleKey = "title:\(normTitle)"
            if !keys.contains(titleKey) { keys.append(titleKey) }
        }
        if let bottle = bottleName?.trimmingCharacters(in: .whitespacesAndNewlines), !bottle.isEmpty {
            let normBottle = Self.normalizedIdentityTitle(bottle)
            if !normBottle.isEmpty {
                let bottleKey = "bottle:\(normBottle)"
                if !keys.contains(bottleKey) { keys.append(bottleKey) }
            }
        }
        return keys
    }

    package func matches(_ other: LaunchGame) -> Bool {
        if id == other.id { return true }

        let lhsExe = Self.canonicalPath(exePath)
        let rhsExe = Self.canonicalPath(other.exePath)
        if let lhsExe, let rhsExe, lhsExe == rhsExe {
            return true
        }

        let lhsTitle = Self.normalizedIdentityTitle(title)
        let rhsTitle = Self.normalizedIdentityTitle(other.title)
        if !lhsTitle.isEmpty, lhsTitle == rhsTitle {
            return true
        }

        if let a = appID, let b = other.appID, !a.isEmpty, a != "480", a == b {
            return true
        }

        if let b1 = bottleName, let b2 = other.bottleName {
            let nb1 = Self.normalizedIdentityTitle(b1)
            let nb2 = Self.normalizedIdentityTitle(b2)
            if !nb1.isEmpty, nb1 == nb2 {
                return true
            }
        }

        // Only match by directory when executables are not distinct files inside a shared folder (e.g. ~/Downloads).
        if let d1 = Self.canonicalPath(gameDirectory),
           let d2 = Self.canonicalPath(other.gameDirectory) {
            let distinctExecutables: Bool = {
                guard let lhsExe, let rhsExe else { return false }
                let n1 = (lhsExe as NSString).lastPathComponent.lowercased()
                let n2 = (rhsExe as NSString).lastPathComponent.lowercased()
                return n1 != n2
            }()
            if !distinctExecutables {
                if d1 == d2 || d2.hasPrefix(d1 + "/") || d1.hasPrefix(d2 + "/") {
                    return true
                }
            }
        }

        return false
    }

    package func merged(with incoming: LaunchGame, preferIncomingMetadata: Bool) -> LaunchGame {
        let mergedLastPlayed = [lastPlayedAt, incoming.lastPlayedAt].compactMap { $0 }.max()
        let mergedAddedAt = min(addedAt, incoming.addedAt)

        let mergedSource: LaunchGameSource = {
            if preferIncomingMetadata && incoming.source != .crossoverScan {
                return incoming.source
            }
            if source == .crossoverScan && incoming.source != .crossoverScan {
                return incoming.source
            }
            return source
        }()

        let resolvedTitle: String = {
            if preferIncomingMetadata && !incoming.title.isEmpty {
                return incoming.title
            }
            return title.isEmpty ? incoming.title : title
        }()

        let resolvedExe: String? = preferIncomingMetadata
            ? (incoming.exePath ?? exePath)
            : (exePath ?? incoming.exePath)

        let resolvedDir: String? = preferIncomingMetadata
            ? (incoming.gameDirectory ?? gameDirectory)
            : (gameDirectory ?? incoming.gameDirectory)

        let resolvedBottle: String? = {
            let cleanIncoming = incoming.bottleName?.isEmpty == true ? nil : incoming.bottleName
            let cleanExisting = bottleName?.isEmpty == true ? nil : bottleName
            return preferIncomingMetadata ? (cleanIncoming ?? cleanExisting) : (cleanExisting ?? cleanIncoming)
        }()

        let resolvedAppID: String? = {
            let a1 = appID?.isEmpty == true ? nil : appID
            let a2 = incoming.appID?.isEmpty == true ? nil : incoming.appID
            if preferIncomingMetadata {
                if let a2, a2 != "480" { return a2 }
                if let a1, a1 != "480" { return a1 }
                return a2 ?? a1
            } else {
                if let a1, a1 != "480" { return a1 }
                if let a2, a2 != "480" { return a2 }
                return a1 ?? a2
            }
        }()
        let resolvedCustomIconPath: String? = {
            let c1 = customIconPath?.isEmpty == true ? nil : customIconPath
            let c2 = incoming.customIconPath?.isEmpty == true ? nil : incoming.customIconPath
            return preferIncomingMetadata ? (c2 ?? c1) : (c1 ?? c2)
        }()
        let resolvedIconPreference: LaunchGameIconPreference = {
            if preferIncomingMetadata {
                return incoming.iconPreference != .automatic ? incoming.iconPreference : iconPreference
            } else {
                return iconPreference != .automatic ? iconPreference : incoming.iconPreference
            }
        }()
        let resolvedLaunchArguments: String? = {
            let l1 = launchArguments?.trimmingCharacters(in: .whitespacesAndNewlines)
            let l2 = incoming.launchArguments?.trimmingCharacters(in: .whitespacesAndNewlines)
            let nonEmpty1 = (l1?.isEmpty == false) ? l1 : nil
            let nonEmpty2 = (l2?.isEmpty == false) ? l2 : nil
            return preferIncomingMetadata ? (nonEmpty2 ?? nonEmpty1) : (nonEmpty1 ?? nonEmpty2)
        }()

        return LaunchGame(
            id: id,
            title: resolvedTitle,
            exePath: resolvedExe,
            gameDirectory: resolvedDir,
            bottleName: resolvedBottle,
            appID: resolvedAppID,
            source: mergedSource,
            customIconPath: resolvedCustomIconPath,
            iconPreference: resolvedIconPreference,
            launchArguments: resolvedLaunchArguments,
            addedAt: mergedAddedAt,
            updatedAt: max(updatedAt, incoming.updatedAt),
            lastPlayedAt: mergedLastPlayed
        )
    }

    package static func deduplicate(_ games: [LaunchGame]) -> [LaunchGame] {
        var result: [LaunchGame] = []
        result.reserveCapacity(games.count)
        for candidate in games {
            if let idx = result.firstIndex(where: { $0.matches(candidate) }) {
                let existing = result[idx]
                let preferIncoming = (existing.source == .crossoverScan && candidate.source != .crossoverScan)
                result[idx] = existing.merged(with: candidate, preferIncomingMetadata: preferIncoming)
            } else {
                result.append(candidate)
            }
        }
        return result
    }

    package static func sorted(_ games: [LaunchGame], by order: LaunchSortOrder) -> [LaunchGame] {
        switch order {
        case .lastPlayed:
            return games.sorted { lhs, rhs in
                switch (lhs.lastPlayedAt, rhs.lastPlayedAt) {
                case let (l?, r?):
                    if l != r { return l > r }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        case .name:
            return games.sorted { lhs, rhs in
                let cmp = lhs.title.localizedStandardCompare(rhs.title)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }

    package func lastPlayedDisplayText(relativeTo now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date = lastPlayedAt else {
            return "未游玩"
        }
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 && elapsed >= -60 {
            return "刚刚"
        }
        if elapsed >= 60 && elapsed < 3600 {
            return "\(Int(elapsed / 60)) 分钟前"
        }

        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let hhmm = String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)

        if calendar.isDate(date, inSameDayAs: now) {
            return "今天 \(hhmm)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(hhmm)"
        }

        let startOfDate = calendar.startOfDay(for: date)
        let startOfNow = calendar.startOfDay(for: now)
        let dayDiff = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? 0
        if dayDiff > 0 && dayDiff < 7 {
            return "\(dayDiff) 天前"
        }

        let yearNow = calendar.component(.year, from: now)
        if let year = comps.year, year == yearNow {
            return "\(comps.month ?? 1)月\(comps.day ?? 1)日"
        }
        return "\(comps.year ?? 2025)/\(comps.month ?? 1)/\(comps.day ?? 1)"
    }
}
