import ChrysaCore
import ChrysaApplication
import Foundation

package actor CrossOverBottleConfigurator {
    private let supervisor: ProcessSupervisor

    package init(supervisor: ProcessSupervisor = .shared) {
        self.supervisor = supervisor
    }

    package func configure(
        taskID: UUID? = nil,
        gameTitle: String,
        exePath: String?,
        bottlesDirectory: String,
        hasD3D12: Bool,
        hasWinHTTP: Bool,
        isCancelled: @escaping @Sendable () async -> Bool = { Task.isCancelled }
    ) async throws -> String {
        let fm = FileManager.default
        let bottlesRoot = (bottlesDirectory as NSString).expandingTildeInPath
        func checkCancellation() async throws {
            try Task.checkCancellation()
            if await isCancelled() { throw CancellationError() }
        }
        try await checkCancellation()
        guard fm.fileExists(atPath: bottlesRoot) else { return "Default" }

        let normalizedTitle: String = {
            let trimmed = gameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == trimmed.lowercased() {
                return trimmed.capitalized
            }
            return trimmed
        }()

        guard PathSafety.safeFilename(normalizedTitle) == normalizedTitle else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        // 1. If exePath is already inside a CrossOver Bottle, use that bottle
        var targetBottleName: String? = nil
        if let exe = exePath, exe.hasPrefix(bottlesRoot + "/") {
            let rel = String(exe.dropFirst((bottlesRoot + "/").count))
            targetBottleName = rel.components(separatedBy: "/").first
        }

        // 2. Check if a matching bottle exists (exact or condensed name), or create a dedicated Win10_64 bottle
        if targetBottleName == nil {
            let condensedTarget = normalizedTitle.replacingOccurrences(of: " ", with: "").lowercased()
            if let existingBottles = try? fm.contentsOfDirectory(atPath: bottlesRoot),
               let match = existingBottles.first(where: {
                   $0.caseInsensitiveCompare(normalizedTitle) == .orderedSame
                       || $0.replacingOccurrences(of: " ", with: "").lowercased() == condensedTarget
               }) {
                targetBottleName = match
            } else if let cxBottleBin = ToolchainLocator.locateCrossOverBin("cxbottle") {
                try await checkCancellation()
                let creation = try await supervisor.run(
                    executable: cxBottleBin,
                    arguments: [
                        "--bottle", normalizedTitle,
                        "--create",
                        "--template", "win10_64",
                        "--description", normalizedTitle
                    ],
                    taskID: taskID
                )
                try await checkCancellation()
                guard creation.exitCode == 0 else {
                    throw PatchError.bottleCommandFailed("cxbottle", creation.exitCode, creation.diagnosticOutput)
                }
                let createdPath = (bottlesRoot as NSString).appendingPathComponent(normalizedTitle)
                if fm.fileExists(atPath: createdPath) {
                    targetBottleName = normalizedTitle
                }
            }
        }

        guard let bottleName = targetBottleName else { return normalizedTitle }
        let bottlePath = (bottlesRoot as NSString).appendingPathComponent(bottleName)
        guard fm.fileExists(atPath: bottlePath) else { return bottleName }
        let confPath = (bottlePath as NSString).appendingPathComponent("cxbottle.conf")

        // 3. Symlink external game folder into bottle's drive_c/<bottleName>
        if let exe = exePath, !exe.hasPrefix(bottlesRoot) {
            try await checkCancellation()
            let exeDir = (exe as NSString).deletingLastPathComponent
            let driveCDir = (bottlePath as NSString).appendingPathComponent("drive_c")
            let linkPath = (driveCDir as NSString).appendingPathComponent(bottleName)
            if fm.fileExists(atPath: driveCDir) {
                if let dest = try? fm.destinationOfSymbolicLink(atPath: linkPath), dest != exeDir {
                    try fm.removeItem(atPath: linkPath)
                }
                if !fm.fileExists(atPath: linkPath) {
                    try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: exeDir)
                }
            }

            // 4. Register Start Menu shortcut (.lnk) + sync CrossOver menu
            let cxMenuConf = (bottlePath as NSString).appendingPathComponent("cxmenu.conf")
            let existingMenu = (try? String(contentsOfFile: cxMenuConf, encoding: .utf8)) ?? ""
            if !existingMenu.localizedCaseInsensitiveContains(bottleName),
               let cxWine = ToolchainLocator.locateCrossOverBin("wine"),
               let cxMenu = ToolchainLocator.locateCrossOverBin("cxmenu") {
                try await checkCancellation()
                let exeFileName = (exe as NSString).lastPathComponent
                let vbsURL = fm.temporaryDirectory.appendingPathComponent("chrysa_lnk_\(UUID().uuidString).vbs")
                let vbsPath = vbsURL.path
                let vbsContent = """
                Set oWS = WScript.CreateObject("WScript.Shell")
                Set oLink = oWS.CreateShortcut("C:\\users\\crossover\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\\(bottleName).lnk")
                oLink.TargetPath = "C:\\\(bottleName)\\\(exeFileName)"
                oLink.WorkingDirectory = "C:\\\(bottleName)"
                oLink.Description = "\(bottleName)"
                oLink.Save
                """
                try vbsContent.write(toFile: vbsPath, atomically: true, encoding: .utf8)
                defer { try? fm.removeItem(atPath: vbsPath) }

                _ = try? await supervisor.run(
                    executable: cxWine,
                    arguments: ["--bottle", bottleName, "cscript.exe", "//NoLogo", "Z:\\" + vbsPath.replacingOccurrences(of: "/", with: "\\")],
                    taskID: taskID
                )
                for args in [["--bottle", bottleName, "--sync", "--mode", "install"], ["--bottle", bottleName, "--install"]] {
                    try await checkCancellation()
                    _ = try? await supervisor.run(executable: cxMenu, arguments: args, taskID: taskID)
                }
                // Never force-quit or restart CrossOver behind the user's back.
                // The menu sync applies where possible; otherwise the user can restart it manually.
            }
        }

        // 5. Ensure [EnvironmentVariables] in cxbottle.conf has WINEMSYNC=1 (+ d3dmetal / winhttp if detected)
        try await checkCancellation()
        var confText = try String(contentsOfFile: confPath, encoding: .utf8)
        var changed = false
        if !confText.contains("\"WINEMSYNC\"") {
            confText += "\n\"WINEMSYNC\" = \"1\"\n"
            changed = true
        }
        if hasD3D12 && !confText.contains("\"d3dmetal\"") {
            confText += "\"CX_GRAPHICS_BACKEND\" = \"d3dmetal\"\n"
            changed = true
        }
        if hasWinHTTP && !confText.contains("winhttp=n,b") {
            confText += "\"WINEDLLOVERRIDES\" = \"winhttp=n,b\"\n"
            changed = true
        }
        if changed {
            try confText.write(toFile: confPath, atomically: true, encoding: .utf8)
        }

        return bottleName
    }

}
