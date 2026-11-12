import ChrysaCore
import ChrysaApplication
import Foundation

package struct ProcessRunResult: Sendable {
    package let exitCode: Int32
    package let outputData: Data
    package let diagnosticData: Data

    package init(exitCode: Int32, outputData: Data, diagnosticData: Data = Data()) {
        self.exitCode = exitCode
        self.outputData = outputData
        self.diagnosticData = diagnosticData
    }

    package var outputString: String {
        String(data: outputData, encoding: .utf8) ?? String(decoding: outputData, as: UTF8.self)
    }

    package var diagnosticOutput: String {
        let source = diagnosticData.isEmpty ? outputData : diagnosticData
        return String(data: source, encoding: .utf8) ?? String(decoding: source, as: UTF8.self)
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

        let outPipe = Pipe()
        if captureOutput || onStreamChunk != nil {
            proc.standardOutput = outPipe
            proc.standardError = outPipe
        } else {
            proc.standardOutput = outPipe
            proc.standardError = outPipe
        }

        final class LockedBuffer: @unchecked Sendable {
            private static let diagnosticTailLimit = 24_576
            private let lock = NSLock()
            private let captureFull: Bool
            private var fullData = Data()
            private var tailData = Data()

            init(captureFull: Bool) {
                self.captureFull = captureFull
            }

            func append(_ chunk: Data) {
                lock.lock()
                if captureFull {
                    fullData.append(chunk)
                }
                tailData.append(chunk)
                if tailData.count > Self.diagnosticTailLimit {
                    tailData.removeFirst(tailData.count - Self.diagnosticTailLimit)
                }
                lock.unlock()
            }

            func snapshot() -> (full: Data, tail: Data) {
                lock.lock()
                defer { lock.unlock() }
                return (fullData, tailData)
            }
        }

        let buffer = LockedBuffer(captureFull: captureOutput)
        let fh = outPipe.fileHandleForReading
        fh.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)
            if let cb = onStreamChunk, let str = String(data: chunk, encoding: .utf8) {
                cb(str)
            }
        }

        register(proc, for: taskID)
        defer {
            outPipe.fileHandleForReading.readabilityHandler = nil
            unregister(proc, for: taskID)
        }

        let exitCode: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                proc.terminationHandler = { finishedProc in
                    let fh = outPipe.fileHandleForReading
                    fh.readabilityHandler = nil
                    let tail = fh.readDataToEndOfFile()
                    if !tail.isEmpty {
                        buffer.append(tail)
                        if let cb = onStreamChunk, let str = String(data: tail, encoding: .utf8) {
                            cb(str)
                        }
                    }
                    continuation.resume(returning: finishedProc.terminationStatus)
                }
                do {
                    try Task.checkCancellation()
                    try proc.run()
                } catch {
                    proc.terminationHandler = nil
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.terminate(proc) }
        }

        let snap = buffer.snapshot()
        return ProcessRunResult(exitCode: exitCode, outputData: snap.full, diagnosticData: snap.tail)
    }
}
