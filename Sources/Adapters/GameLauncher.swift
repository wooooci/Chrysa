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

    private struct LaunchProcessError: LocalizedError {
        let message: String
        let rawOutput: String?
        var errorDescription: String? { message }
    }

    package func launchGame(
        _ request: GameLaunchRequest,
        isCancelled: @escaping @Sendable () async -> Bool = { Task.isCancelled },
        onLog: @escaping @Sendable (String, Bool) -> Void,
        onDiagnostic: @escaping @Sendable (StageLog) -> Void = { _ in }
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
                    try await spawnDetachedWine(executable: cxWine, bottleName: bottleName, gameEXE: exe)
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
            onDiagnostic(StageLog("error ▸ \(message)", level: .error))
            return .failed(message)
        } catch {
            if error is CancellationError || Task.isCancelled { return .cancelled }
            if await isCancelled() { return .cancelled }
            let message = "游戏启动失败，\(error.localizedDescription)"
            let rawDiag = (error as? LaunchProcessError)?.rawOutput ?? (error as? PatchError)?.rawDiagnostic
            onDiagnostic(StageLog("error ▸ \(message)", level: .error, rawOutput: rawDiag))
            return .failed(message)
        }
    }

    private func spawnDetachedWine(executable: String, bottleName: String, gameEXE: String) async throws {
        final class RollingPipeSink: @unchecked Sendable {
            private let lock = NSLock()
            private var tail = Data()
            private var keepCapturing = true
            func append(_ chunk: Data) {
                lock.lock()
                if keepCapturing {
                    tail.append(chunk)
                    if tail.count > 16_384 {
                        tail.removeFirst(tail.count - 16_384)
                    }
                }
                lock.unlock()
            }
            func detach() -> String {
                lock.lock()
                defer { lock.unlock() }
                keepCapturing = false
                return String(data: tail, encoding: .utf8) ?? String(decoding: tail, as: UTF8.self)
            }
        }

        let pipe = Pipe()
        let sink = RollingPipeSink()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                sink.append(chunk)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = URL(fileURLWithPath: (gameEXE as NSString).deletingLastPathComponent)
        process.arguments = ["--bottle", bottleName, "--check", "--wait-children", gameEXE]
        process.standardOutput = pipe
        process.standardError = pipe
        try Task.checkCancellation()
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        // Briefly observe early startup so immediate loader/bottle crashes surface real Wine diagnostics.
        try? await Task.sleep(nanoseconds: 120_000_000)
        let earlyOutput = sink.detach()
        if !process.isRunning && process.terminationStatus != 0 {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw LaunchProcessError(
                message: "Wine 进程启动异常退出 (退出码 \(process.terminationStatus))",
                rawOutput: LogEntry.sanitizeRawOutput(earlyOutput)
            )
        }
    }

    private func open(_ arguments: [String], taskID: UUID) async throws {
        let result = try await supervisor.run(executable: openExecutable, arguments: arguments, taskID: taskID)
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            throw LaunchProcessError(
                message: "系统打开命令退出码 \(result.exitCode)",
                rawOutput: LogEntry.sanitizeRawOutput(result.diagnosticOutput)
            )
        }
    }
}
