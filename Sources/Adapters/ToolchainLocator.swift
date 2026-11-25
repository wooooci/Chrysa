import ChrysaCore
import ChrysaApplication
import Foundation

package enum ToolchainLocator {
    package static func locateBundledOrSystemBinary(
        bundledName: String,
        bundlePath: String = Bundle.main.bundlePath,
        installedAppPath: String = ("~/Applications/Chrysa.app" as NSString).expandingTildeInPath,
        systemCandidates: [String]
    ) -> String? {
        let fm = FileManager.default
        let candidates = [
            (bundlePath as NSString).appendingPathComponent("Contents/MacOS/\(bundledName)"),
            (installedAppPath as NSString).appendingPathComponent("Contents/MacOS/\(bundledName)")
        ] + systemCandidates
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    package static func locateDownloadEngineBinary() -> String? {
        locateBundledOrSystemBinary(
            bundledName: "sf-dl",
            systemCandidates: ["/opt/homebrew/bin/aria2c", "/usr/local/bin/aria2c"]
        )
    }

    package static func locateSevenZip() -> String? {
        locateBundledOrSystemBinary(
            bundledName: "7zz",
            systemCandidates: ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz"]
        )
    }

    package static func locateUnrar() -> String? {
        locateBundledOrSystemBinary(
            bundledName: "unrar",
            systemCandidates: [
                "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/unrar",
                "/opt/homebrew/bin/unrar",
                "/usr/local/bin/unrar"
            ]
        )
    }

    package static func locateUnar() -> String? {
        locateBundledOrSystemBinary(
            bundledName: "unar",
            systemCandidates: ["/opt/homebrew/bin/unar", "/usr/local/bin/unar"]
        )
    }

    package static func locateInnoextract() -> String? {
        locateBundledOrSystemBinary(
            bundledName: "innoextract",
            systemCandidates: ["/opt/homebrew/bin/innoextract", "/usr/local/bin/innoextract"]
        )
    }

    package static func locateGbeDLL(is64Bit: Bool) -> String? {
        let sub = is64Bit ? "x64/steam_api64.dll" : "x86/steam_api.dll"
        let fm = FileManager.default
        if let resPath = Bundle.main.resourcePath {
            let bundled = (resPath as NSString).appendingPathComponent("gbe_fork/\(sub)")
            if fm.fileExists(atPath: bundled) { return bundled }
        }
        let appBundled = ("~/Applications/Chrysa.app/Contents/Resources/gbe_fork/\(sub)" as NSString).expandingTildeInPath
        if fm.fileExists(atPath: appBundled) { return appBundled }

        let appSupport = ("~/Library/Application Support/Chrysa/gbe_fork/\(sub)" as NSString).expandingTildeInPath
        if fm.fileExists(atPath: appSupport) { return appSupport }

        let repoBundled = (fm.currentDirectoryPath as NSString).appendingPathComponent("packaging/Resources/gbe_fork/\(sub)")
        if fm.fileExists(atPath: repoBundled) { return repoBundled }
        return nil
    }

    package static func locateCrossOverBin(_ tool: String) -> String? {
        let path = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/\(tool)"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    package static func detectSystemProxy() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        proc.arguments = ["--proxy"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        var httpEnabled = false
        var httpHost: String?
        var httpPort: String?
        var httpsEnabled = false
        var httpsHost: String?
        var httpsPort: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("HTTPEnable :") && line.hasSuffix("1") {
                httpEnabled = true
            } else if line.hasPrefix("HTTPProxy :") {
                httpHost = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line.hasPrefix("HTTPPort :") {
                httpPort = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line.hasPrefix("HTTPSEnable :") && line.hasSuffix("1") {
                httpsEnabled = true
            } else if line.hasPrefix("HTTPSProxy :") {
                httpsHost = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line.hasPrefix("HTTPSPort :") {
                httpsPort = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if httpEnabled, let h = httpHost, let p = httpPort, !h.isEmpty, !p.isEmpty {
            return "http://\(h):\(p)"
        }
        if httpsEnabled, let h = httpsHost, let p = httpsPort, !h.isEmpty, !p.isEmpty {
            return "http://\(h):\(p)"
        }
        return nil
    }

    package static func hostNeedsProxy(_ urlString: String) -> Bool {
        HostResolverRegistry.proxyNeeds(for: urlString)
    }
}
