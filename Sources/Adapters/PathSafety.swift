import ChrysaCore
import ChrysaApplication
import Foundation

package enum PathSafety {
    package static func safeFilename(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.contains("/"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              value != ".", value != ".." else { return nil }
        let name = value.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return name
    }

    package static func safeRelativeDirectory(_ raw: String?) -> String? {
        guard let raw = raw, !raw.isEmpty,
              !raw.hasPrefix("/"), !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let components = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") }) else { return nil }
        return components.joined(separator: "/")
    }

    package static func canonicalDirectory(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    package static func existingCanonicalDirectory(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    package static func containedURL(_ candidate: URL, in root: URL, allowRoot: Bool = false) -> URL? {
        let rootURL = root.resolvingSymlinksInPath().standardizedFileURL
        let candidateURL = candidate.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        if allowRoot && candidateURL.path == rootURL.path { return candidateURL }
        guard candidateURL.path.hasPrefix(rootPath) else { return nil }
        return candidateURL
    }

    package static func uniqueChildDirectory(parent: URL, proposedName: String?) throws -> (url: URL, name: String) {
        let base = safeFilename(proposedName) ?? "Unpacked-\(UUID().uuidString)"
        for attempt in 0..<8 {
            let name = attempt == 0 ? base : "\(base)-\(UUID().uuidString)"
            let candidate = parent.appendingPathComponent(name, isDirectory: true).standardizedFileURL
            guard containedURL(candidate, in: parent) != nil else { continue }
            do {
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
                return (candidate, name)
            } catch {
                if FileManager.default.fileExists(atPath: candidate.path) { continue }
                throw error
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    package static func publishFile(
        from temporaryURL: URL,
        toDirectory directory: URL,
        filename: String,
        allowedSourceRoot: URL? = nil
    ) throws -> (url: URL, name: String) {
        let sourceRoot = allowedSourceRoot ?? directory
        guard let safeName = safeFilename(filename),
              containedURL(temporaryURL, in: sourceRoot) != nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        for attempt in 0..<8 {
            let name: String
            if attempt == 0 {
                name = safeName
            } else {
                let base = (safeName as NSString).deletingPathExtension
                let ext = (safeName as NSString).pathExtension
                name = ext.isEmpty ? "\(base)-\(UUID().uuidString)" : "\(base)-\(UUID().uuidString).\(ext)"
            }
            let destination = directory.appendingPathComponent(name).standardizedFileURL
            guard containedURL(destination, in: directory) != nil else { continue }
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                return (destination, name)
            } catch {
                if FileManager.default.fileExists(atPath: destination.path) { continue }
                throw error
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// 查找 INI / Wine `.reg` 节 `[Header]`（含可选后缀如 Wine 时间戳）在行数组中的 `[start, end)` 范围
    package static func findSectionRange(
        in lines: [String],
        header: String,
        caseSensitive: Bool = false
    ) -> (start: Int, end: Int)? {
        var foundStart: Int?
        for (idx, line) in lines.enumerated() {
            let trimmed = line
                .replacingOccurrences(of: "\u{FEFF}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.first == "[" else { continue }
            if let start = foundStart {
                return (start, idx)
            }
            guard let closeIdx = trimmed.firstIndex(of: "]") else { continue }
            let sectionToken = String(trimmed[...closeIdx])
            let matches = caseSensitive
                ? (sectionToken == header)
                : (sectionToken.caseInsensitiveCompare(header) == .orderedSame)
            if matches {
                foundStart = idx
            }
        }
        if let start = foundStart {
            return (start, lines.count)
        }
        return nil
    }

    /// 安全遍历目录树，校验所有路径边界并防止符号链接逃逸到 `root` 之外
    package static func walkDirectory(
        at root: URL,
        includingPropertiesForKeys extraKeys: [URLResourceKey] = [],
        options: FileManager.DirectoryEnumerationOptions = [],
        includeSymlinks: Bool = true,
        handler: (_ itemURL: URL, _ relativePath: String, _ resourceValues: URLResourceValues) throws -> Void
    ) throws {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        var keySet: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        for key in extraKeys {
            keySet.insert(key)
        }
        let keys = Array(keySet)
        guard let enumerator = FileManager.default.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return
        }
        while let itemURL = enumerator.nextObject() as? URL {
            let values = try itemURL.resourceValues(forKeys: keySet)
            let parentDir = itemURL.deletingLastPathComponent()
            guard let containedParent = containedURL(parentDir, in: canonicalRoot, allowRoot: true) else {
                enumerator.skipDescendants()
                continue
            }
            let logicalItemURL = containedParent.appendingPathComponent(
                itemURL.lastPathComponent,
                isDirectory: values.isDirectory == true
            )
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                guard includeSymlinks else { continue }
            } else {
                guard containedURL(itemURL, in: canonicalRoot, allowRoot: false) != nil else {
                    enumerator.skipDescendants()
                    continue
                }
            }
            guard logicalItemURL.path.hasPrefix(rootPrefix) else { continue }
            let relativePath = String(logicalItemURL.path.dropFirst(rootPrefix.count))
            guard !relativePath.isEmpty else { continue }
            try handler(logicalItemURL, relativePath, values)
        }
    }

    /// 流式 / APFS CoW 原子替换目标文件，避免大文件整块读入内存
    package static func replaceFileSafely(
        from sourceURL: URL,
        to destinationURL: URL,
        copyInsteadOfMove: Bool = true
    ) throws {
        let fm = FileManager.default
        let parentDir = destinationURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let stagingURL = parentDir.appendingPathComponent(
            ".chrysa-tmp-\(UUID().uuidString)-\(destinationURL.lastPathComponent)"
        )
        var stagingOwned = false
        defer {
            if stagingOwned {
                try? fm.removeItem(at: stagingURL)
            }
        }

        if copyInsteadOfMove {
            try fm.copyItem(at: sourceURL, to: stagingURL)
        } else {
            try fm.moveItem(at: sourceURL, to: stagingURL)
        }
        stagingOwned = true

        var destStat = stat()
        if lstat(destinationURL.path, &destStat) == 0 {
            if (destStat.st_mode & S_IFMT) == S_IFLNK {
                try fm.removeItem(at: destinationURL)
                try fm.moveItem(at: stagingURL, to: destinationURL)
            } else {
                _ = try fm.replaceItemAt(
                    destinationURL,
                    withItemAt: stagingURL,
                    backupItemName: nil,
                    options: []
                )
            }
        } else {
            try fm.moveItem(at: stagingURL, to: destinationURL)
        }
        stagingOwned = false
    }
}
