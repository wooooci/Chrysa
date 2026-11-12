import ChrysaCore
import ChrysaApplication
import Foundation

package struct ProcessRunResult: Sendable {
    package let exitCode: Int32
    package let outputData: Data
    package var outputString: String {
        String(data: outputData, encoding: .utf8) ?? ""
    }
}

package actor ProcessSupervisor {
    package static let shared = ProcessSupervisor()

    private var activeProcesses: [UUID: [ObjectIdentifier: Process]] = [:]
    private var cancelledTaskIDs: Set<UUID> = []

    package func clearCancellation(for taskID: UUID) {
        cancelledTaskIDs.remove(taskID)
    }

    package func isCancelled(
        _ taskID: UUID,
        checking cancellation: @Sendable () async -> Bool = { Task.isCancelled }
    ) async -> Bool {
        if Task.isCancelled || cancelledTaskIDs.contains(taskID) { return true }
        return await cancellation()
    }

    package func cancel(taskID: UUID) {
        cancelledTaskIDs.insert(taskID)
        if let map = activeProcesses.removeValue(forKey: taskID) {
            for (_, proc) in map where proc.isRunning {
                proc.terminate()
            }
        }
    }

    package func terminateAll() {
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

    private func terminate(_ proc: Process) {
        if proc.isRunning { proc.terminate() }
    }

    /// Runs an external process asynchronously using `terminationHandler` without blocking Swift concurrency threads.
    package func run(
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil,
        taskID: UUID? = nil,
        captureOutput: Bool = false,
        mergeStderr: Bool = false,
        onStreamChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessRunResult {
        try Task.checkCancellation()
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
                    try Task.checkCancellation()
                    try proc.run()
                } catch {
                    proc.terminationHandler = nil
                    outPipe?.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            // Serialize with process startup so cancellation between the last check and run() is delivered.
            Task { await self.terminate(proc) }
        }

        return ProcessRunResult(exitCode: exitCode, outputData: buffer.snapshot())
    }
}
