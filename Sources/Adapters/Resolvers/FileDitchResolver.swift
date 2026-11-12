import ChrysaCore
import ChrysaApplication
import Foundation

package struct FileDitchResolver: HostResolver {
    package func canHandle(host: String, url: URL) -> Bool {
        host.contains("fileditch")
    }

    package func resolve(input: String, url: URL, passwords: [String]) async -> [ResolvedDownload] {
        let filename = url.lastPathComponent
        if let decoded = HostResolverRegistry.decodeBase64FilenameIfPossible(filename) {
            return [
                ResolvedDownload(
                    originalURL: input,
                    finalURL: input,
                    headers: [],
                    suggestedFilename: decoded
                )
            ]
        }

        if let mirrorURL = await Self.findMirrorUploadXInFirefoxHistory(filename: filename) {
            let items = await MirrorUploadXResolver.resolveMirrorUploadX(urlString: mirrorURL, passwords: passwords)
            if !items.isEmpty {
                return items
            }
        }

        return []
    }

    private static func findMirrorUploadXInFirefoxHistory(filename: String) async -> String? {
        guard !filename.isEmpty else { return nil }
        let ffRoot = ("~/Library/Application Support/Firefox/Profiles" as NSString).expandingTildeInPath
        guard let profiles = try? FileManager.default.contentsOfDirectory(atPath: ffRoot) else { return nil }
        let safeName = filename.replacingOccurrences(of: "'", with: "''")

        for prof in profiles {
            let dbPath = (ffRoot as NSString).appendingPathComponent("\(prof)/places.sqlite")
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }
            let tmpBase = "/tmp/chrysa_ff_places_\(UUID().uuidString).sqlite"
            try? FileManager.default.copyItem(atPath: dbPath, toPath: tmpBase)
            if FileManager.default.fileExists(atPath: dbPath + "-wal") {
                try? FileManager.default.copyItem(atPath: dbPath + "-wal", toPath: tmpBase + "-wal")
            }
            if FileManager.default.fileExists(atPath: dbPath + "-shm") {
                try? FileManager.default.copyItem(atPath: dbPath + "-shm", toPath: tmpBase + "-shm")
            }
            defer {
                try? FileManager.default.removeItem(atPath: tmpBase)
                try? FileManager.default.removeItem(atPath: tmpBase + "-wal")
                try? FileManager.default.removeItem(atPath: tmpBase + "-shm")
            }

            let sql = "SELECT url FROM moz_places WHERE url LIKE 'https://mirroruploadx.com/f/%' AND title LIKE '%\(safeName)%' ORDER BY last_visit_date DESC LIMIT 1;"
            if let res = try? await ProcessSupervisor.shared.run(
                executable: "/usr/bin/sqlite3",
                arguments: [tmpBase, sql],
                captureOutput: true
            ) {
                let out = res.outputString.trimmingCharacters(in: .whitespacesAndNewlines)
                if out.hasPrefix("https://mirroruploadx.com/f/") {
                    return out
                }
            }
        }
        return nil
    }
}
