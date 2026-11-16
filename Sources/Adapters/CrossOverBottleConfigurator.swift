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
        gameDirectory: String? = nil,
        bottlesDirectory: String,
        hasD3D12: Bool,
        hasWinHTTP: Bool,
        proxyDLLStems: [String] = [],
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

        // 1 & 2. Reuse matching existing bottle, or create a dedicated Win10_64 bottle
        var targetBottleName = CrossOverRegistryHelper.resolveExistingBottleName(
            explicitBottleName: nil,
            gameTitle: normalizedTitle,
            exePath: exePath,
            bottlesDirectory: bottlesRoot
        )

        if targetBottleName == nil, let cxBottleBin = ToolchainLocator.locateCrossOverBin("cxbottle") {
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

        guard let bottleName = targetBottleName else { return normalizedTitle }
        let bottlePath = (bottlesRoot as NSString).appendingPathComponent(bottleName)
        guard fm.fileExists(atPath: bottlePath) else { return bottleName }

        // 3. Force-refresh drive_c/<bottleName> symlink and Start Menu / cxmenu shortcuts
        if let exe = exePath, !exe.hasPrefix(bottlesRoot) {
            try await checkCancellation()
            let linkTarget = CrossOverRegistryHelper.preferredDriveCLinkTarget(
                executablePath: exe,
                gameDirectory: gameDirectory
            )
            _ = try CrossOverRegistryHelper.ensureBottleDriveCSymlink(
                bottlePath: bottlePath,
                bottleName: bottleName,
                targetDirectory: linkTarget
            )

            // 4. Refresh Start Menu shortcut (.lnk) + sync CrossOver menu even when reusing an existing bottle
            if let cxWine = ToolchainLocator.locateCrossOverBin("wine"),
               let cxMenu = ToolchainLocator.locateCrossOverBin("cxmenu") {
                try await checkCancellation()
                let relSubpath = (LaunchGame.relativeSubpath(of: exe, inside: linkTarget) ?? (exe as NSString).lastPathComponent)
                    .replacingOccurrences(of: "/", with: "\\")
                let relDir = (relSubpath as NSString).deletingLastPathComponent
                let winWorkDir = (relDir.isEmpty || relDir == ".") ? "C:\\\(bottleName)" : "C:\\\(bottleName)\\\(relDir)"
                let escVBS: (String) -> String = { $0.replacingOccurrences(of: "\"", with: "\"\"") }
                let vbsURL = fm.temporaryDirectory.appendingPathComponent("chrysa_lnk_\(UUID().uuidString).vbs")
                let vbsPath = vbsURL.path
                let vbsContent = """
                Set oWS = WScript.CreateObject("WScript.Shell")\r
                Set oLink = oWS.CreateShortcut("C:\\users\\crossover\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\\(escVBS(bottleName)).lnk")\r
                oLink.TargetPath = "C:\\\(escVBS(bottleName))\\\(escVBS(relSubpath))"\r
                oLink.WorkingDirectory = "\(escVBS(winWorkDir))"\r
                oLink.Description = "\(escVBS(bottleName))"\r
                oLink.Save\r
                """
                var vbsData = Data([0xFF, 0xFE])
                if let utf16 = vbsContent.data(using: .utf16LittleEndian) {
                    vbsData.append(utf16)
                }
                try vbsData.write(to: vbsURL, options: .atomic)
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
            }
        }

        // 5. Ensure Chinese CJK font symlinks + registry FontSubstitutes
        try await checkCancellation()
        try? CrossOverRegistryHelper.ensureChineseFontsConfigured(bottlePath: bottlePath)

        // 6. Synchronize cxbottle.conf environment + WINEDLLOVERRIDES + user.reg DllOverrides
        try await checkCancellation()
        var mergedStems = Set(proxyDLLStems.map { $0.lowercased() })
        if hasWinHTTP {
            mergedStems.insert("winhttp")
        }
        for stem in PEBinaryInspector.detectProxyHookDLLs(nearExecutable: exePath, gameDirectory: gameDirectory) {
            mergedStems.insert(stem.lowercased())
        }
        try CrossOverRegistryHelper.syncProxyDLLOverrides(
            inBottlePath: bottlePath,
            ensuring: mergedStems.sorted(),
            hasD3D12: hasD3D12
        )

        return bottleName
    }

    /// Runs lightweight pre-launch checks right before spawning a game (including CrossOver .app shortcut launches):
    /// synchronizes detected whitelist proxy DLL overrides into `cxbottle.conf` & `user.reg`, ensures Chinese font mapping,
    /// and refreshes `drive_c/<bottleName>` symlink when an external directory is present.
    package static func syncPreLaunchEnvironment(
        gameTitle: String,
        bottleName explicitBottleName: String?,
        executablePath: String?,
        gameDirectory: String?,
        bottlesDirectory: String
    ) -> (bottleName: String, bottlePath: String, detectedProxyStems: [String])? {
        let bottlesRoot = (bottlesDirectory as NSString).expandingTildeInPath
        guard let resolved = CrossOverRegistryHelper.resolveExistingBottle(
            explicitBottleName: explicitBottleName,
            gameTitle: gameTitle,
            exePath: executablePath,
            bottlesDirectory: bottlesRoot
        ) else {
            return nil
        }

        let resolvedBottle = resolved.name
        let bottlePath = resolved.path
        if let exe = executablePath, !exe.hasPrefix(bottlesRoot) {
            let linkTarget = CrossOverRegistryHelper.preferredDriveCLinkTarget(
                executablePath: exe,
                gameDirectory: gameDirectory
            )
            _ = try? CrossOverRegistryHelper.ensureBottleDriveCSymlink(
                bottlePath: bottlePath,
                bottleName: resolvedBottle,
                targetDirectory: linkTarget
            )
        }

        try? CrossOverRegistryHelper.ensureChineseFontsConfigured(bottlePath: bottlePath)
        let proxyStems = PEBinaryInspector.detectProxyHookDLLs(
            nearExecutable: executablePath,
            gameDirectory: gameDirectory
        )
        if !proxyStems.isEmpty {
            try? CrossOverRegistryHelper.syncProxyDLLOverrides(
                inBottlePath: bottlePath,
                ensuring: proxyStems
            )
        }
        return (resolvedBottle, bottlePath, proxyStems)
    }

}
