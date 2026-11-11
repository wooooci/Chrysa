import Foundation

struct ProcessRunResult: Sendable {
    let exitCode: Int32
    let outputData: Data
    var outputString: String {
        String(data: outputData, encoding: .utf8) ?? ""
    }
}

actor ProcessSupervisor {
    static let shared = ProcessSupervisor()

    private var activeProcesses: [UUID: [ObjectIdentifier: Process]] = [:]
    private var cancelledTaskIDs: Set<UUID> = []

    func clearCancellation(for taskID: UUID) {
        cancelledTaskIDs.remove(taskID)
    }

    func isCancelled(_ taskID: UUID) -> Bool {
        cancelledTaskIDs.contains(taskID)
    }

    func cancel(taskID: UUID) {
        cancelledTaskIDs.insert(taskID)
        if let map = activeProcesses.removeValue(forKey: taskID) {
            for (_, proc) in map where proc.isRunning {
                proc.terminate()
            }
        }
    }

    func terminateAll() {
        let allMaps = activeProcesses.values
        activeProcesses.removeAll()
        for map in allMaps {
            for (_, proc) in map where proc.isRunning {
                proc.terminate()
            }
        }
    }

    private func register(_ proc: Process, for taskID: UUID?) {
        guard let tid = taskID else { return }
        var map = activeProcesses[tid] ?? [:]
        map[ObjectIdentifier(proc)] = proc
        activeProcesses[tid] = map
    }

    private func unregister(_ proc: Process, for taskID: UUID?) {
        guard let tid = taskID else { return }
        activeProcesses[tid]?.removeValue(forKey: ObjectIdentifier(proc))
        if activeProcesses[tid]?.isEmpty == true {
            activeProcesses.removeValue(forKey: tid)
        }
    }

    /// Runs an external process asynchronously using `terminationHandler` without blocking Swift concurrency threads.
    func run(
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil,
        taskID: UUID? = nil,
        captureOutput: Bool = false,
        mergeStderr: Bool = false,
        onStreamChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessRunResult {
        if let tid = taskID, cancelledTaskIDs.contains(tid) {
            return ProcessRunResult(exitCode: -15, outputData: Data())
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        if let cwd = currentDirectory {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let outPipe: Pipe? = (captureOutput || onStreamChunk != nil) ? Pipe() : nil
        if let pipe = outPipe {
            proc.standardOutput = pipe
            proc.standardError = mergeStderr ? pipe : FileHandle.nullDevice
        } else {
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
        }

        final class LockedBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            func append(_ chunk: Data) {
                lock.lock()
                data.append(chunk)
                lock.unlock()
            }
            func snapshot() -> Data {
                lock.lock()
                defer { lock.unlock() }
                return data
            }
        }

        let buffer = LockedBuffer()
        if let pipe = outPipe {
            let fh = pipe.fileHandleForReading
            fh.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                if captureOutput {
                    buffer.append(chunk)
                }
                if let cb = onStreamChunk, let str = String(data: chunk, encoding: .utf8) {
                    cb(str)
                }
            }
        }

        register(proc, for: taskID)
        defer {
            outPipe?.fileHandleForReading.readabilityHandler = nil
            unregister(proc, for: taskID)
        }

        let exitCode: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                proc.terminationHandler = { finishedProc in
                    if let pipe = outPipe {
                        let fh = pipe.fileHandleForReading
                        fh.readabilityHandler = nil
                        let tail = fh.readDataToEndOfFile()
                        if !tail.isEmpty {
                            if captureOutput {
                                buffer.append(tail)
                            }
                            if let cb = onStreamChunk, let str = String(data: tail, encoding: .utf8) {
                                cb(str)
                            }
                        }
                    }
                    continuation.resume(returning: finishedProc.terminationStatus)
                }

                do {
                    try proc.run()
                } catch {
                    proc.terminationHandler = nil
                    outPipe?.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if proc.isRunning {
                proc.terminate()
            }
        }

        return ProcessRunResult(exitCode: exitCode, outputData: buffer.snapshot())
    }
}
