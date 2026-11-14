import Foundation
import IOKit.pwr_mgt

/// Silenty holds a macOS user-idle sleep assertion while downloads or unpack operations are running.
package final class IdleSleepAssertionManager: @unchecked Sendable {
    package static let shared = IdleSleepAssertionManager()

    private let lock = NSLock()
    private var assertionID: IOPMAssertionID?
    private var activeCount: Int = 0

    package init() {}

    deinit {
        releaseAssertionLockedIfNeeded()
    }

    package var isAsserted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return assertionID != nil
    }

    package func setActive(_ active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if active {
            guard assertionID == nil else { return }
            var id: IOPMAssertionID = 0
            let reason = "Chrysa active download or unpack" as CFString
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &id
            )
            if status == kIOReturnSuccess {
                assertionID = id
                activeCount += 1
            }
        } else {
            releaseAssertionLockedIfNeeded()
        }
    }

    private func releaseAssertionLockedIfNeeded() {
        if let id = assertionID {
            IOPMAssertionRelease(id)
            assertionID = nil
        }
    }
}

package enum DiskSpaceHelper {
    /// Returns free bytes available for user data on the volume backing `directoryPath` (walking up to the nearest existing ancestor).
    package static func availableBytes(atDirectory directoryPath: String) -> Int64? {
        let expanded = (directoryPath as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        var probeURL = URL(fileURLWithPath: expanded, isDirectory: true)
        let fm = FileManager.default

        while !fm.fileExists(atPath: probeURL.path) {
            let parent = probeURL.deletingLastPathComponent()
            if parent.path == probeURL.path || parent.path.isEmpty { break }
            probeURL = parent
        }

        if let values = try? probeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = values.volumeAvailableCapacityForImportantUsage,
           cap > 0 {
            return cap
        }
        if let values = try? probeURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let cap = values.volumeAvailableCapacity {
            return Int64(cap)
        }
        if let attrs = try? fm.attributesOfFileSystem(forPath: probeURL.path),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return nil
    }

    /// Formats byte count cleanly in GiB / MB for concise log lines.
    package static func formatBytes(_ bytes: Int64) -> String {
        let b = Double(max(0, bytes))
        if b >= 1_073_741_824 {
            return String(format: "%.2f GB", b / 1_073_741_824)
        }
        return String(format: "%.0f MB", b / 1_048_576)
    }
}
