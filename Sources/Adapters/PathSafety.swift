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

    package static func publishFile(from temporaryURL: URL, toDirectory directory: URL, filename: String) throws -> (url: URL, name: String) {
        guard let safeName = safeFilename(filename),
              containedURL(temporaryURL, in: directory) != nil else {
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
}
