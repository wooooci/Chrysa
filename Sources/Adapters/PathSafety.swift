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
              !value.allSatisfy({ $0 == "." }) else { return nil }
        let sanitized = value.replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty, !sanitized.allSatisfy({ $0 == "." }) else { return nil }
        return sanitized
    }

    package static func safeRelativeDirectory(_ raw: String?) -> String? {
        guard let raw = raw, !raw.isEmpty,
              !raw.hasPrefix("/"), !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let components = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty else { return nil }
        var sanitizedComponents: [String] = []
        for component in components {
            guard let clean = safeFilename(component) else { return nil }
            sanitizedComponents.append(clean)
        }
        return sanitizedComponents.joined(separator: "/")
    }

    package static func canonicalDirectory(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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
        let base = safeFilename(proposedName) ?? "Unpacked"
        for attempt in 0..<64 {
            let name: String
            if attempt == 0 {
                name = base
            } else if attempt < 63 {
                name = "\(base) (\(attempt + 1))"
            } else {
                name = "\(base)-\(UUID().uuidString.prefix(8))"
            }
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

    package static func publishFile(from temporaryURL: URL, toDirectory directory: URL, filename: String) throws -> (url: URL, name: String) {
        guard let safeName = safeFilename(filename),
              containedURL(temporaryURL, in: directory) != nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        for attempt in 0..<64 {
            let name: String
            if attempt == 0 {
                name = safeName
            } else {
                let suffix = attempt < 63 ? " (\(attempt + 1))" : "-\(UUID().uuidString.prefix(8))"
                let (stem, ext) = splitArchiveStemAndExtension(safeName)
                name = ext.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(ext)"
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

    private static func splitArchiveStemAndExtension(_ filename: String) -> (String, String) {
        let lower = filename.lowercased()
        for compound in ["tar.zst", "tar.xz", "tar.gz"] where lower.hasSuffix("." + compound) {
            let stemEnd = filename.index(filename.endIndex, offsetBy: -(compound.count + 1))
            let stem = String(filename[..<stemEnd])
            if !stem.isEmpty { return (stem, compound) }
        }
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        return base.isEmpty ? (filename, "") : (base, ext)
    }
}
