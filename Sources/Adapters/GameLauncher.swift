import ChrysaCore
import ChrysaApplication
import Foundation

package actor GameLauncher {
    private let bottleConfigurator: CrossOverBottleConfigurator
    private let supervisor: ProcessSupervisor
    private let openExecutable: String

    package init(
        bottleConfigurator: CrossOverBottleConfigurator = CrossOverBottleConfigurator(),
        supervisor: ProcessSupervisor = .shared,
        openExecutable: String = "/usr/bin/open"
    ) {
        self.bottleConfigurator = bottleConfigurator
        self.supervisor = supervisor
        self.openExecutable = openExecutable
    }

    package func launchGame(
        _ request: GameLaunchRequest,
        isCancelled: @escaping @Sendable () async -> Bool = { Task.isCancelled },
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async -> GameLaunchOutcome {
        let fm = FileManager.default
        let cxAppsDir = ("~/Applications/CrossOver" as NSString).expandingTildeInPath
        let shortcutApp = (cxAppsDir as NSString).appendingPathComponent("\(request.title).app")
        guard !Task.isCancelled, !(await isCancelled()) else { return .cancelled }

        do {
            // Prefer the dedicated CrossOver Menu Helper when available.
            if PathSafety.safeFilename(request.title) == request.title, fm.fileExists(atPath: shortcutApp) {
                onLog("crossover ▸ 正在通过容器快捷方式启动: \(request.title).app", true)
                try await open([shortcutApp], taskID: request.jobID)
                return .launched
            }

            if let exe = request.executablePath, fm.fileExists(atPath: exe) {
                let bottleName = try await bottleConfigurator.configure(
                    taskID: request.jobID,
                    gameTitle: request.title,
                    exePath: exe,
                    bottlesDirectory: request.bottlesDirectory,
                    hasD3D12: false,
                    hasWinHTTP: false,
                    isCancelled: isCancelled
                )
                guard !Task.isCancelled, !(await isCancelled()) else { return .cancelled }
                if let cxWine = ToolchainLocator.locateCrossOverBin("wine"), bottleName != "Default" {
                    onLog("wine ▸ 正在通过容器 [\(bottleName)] 直接静默启动: \((exe as NSString).lastPathComponent)", true)
                    // The game outlives this short launch stage. Completion means process creation succeeded.
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: cxWine)
                    process.currentDirectoryURL = URL(fileURLWithPath: (exe as NSString).deletingLastPathComponent)
                    process.arguments = ["--bottle", bottleName, "--check", "--wait-children", exe]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try Task.checkCancellation()
                    try process.run()
                } else {
                    onLog("crossover ▸ 正在通过 CrossOver 打开: \((exe as NSString).lastPathComponent)", true)
                    try await open(["-a", "/Applications/CrossOver.app", exe], taskID: request.jobID)
                }
                return .launched
            }

            var isDirectory: ObjCBool = false
            if let directory = request.gameDirectory,
               fm.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue {
                guard !Task.isCancelled, !(await isCancelled()) else { return .cancelled }
                try await open([directory], taskID: request.jobID)
                onLog("finder ▸ 已在访达中打开游戏目录: \(request.title)", false)
                return .openedDirectory
            }
            let message = "未找到可执行路径: \(request.title)"
            onLog("crossover ▸ \(message)", true)
            return .failed(message)
        } catch {
            if error is CancellationError || Task.isCancelled { return .cancelled }
            if await isCancelled() { return .cancelled }
            let message = "游戏启动失败，\(error.localizedDescription)"
            onLog("error ▸ \(message)", true)
            return .failed(message)
        }
    }

    private func open(_ arguments: [String], taskID: UUID) async throws {
        let result = try await supervisor.run(executable: openExecutable, arguments: arguments, taskID: taskID)
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "系统打开命令退出码 \(result.exitCode)"])
        }
    }
}
