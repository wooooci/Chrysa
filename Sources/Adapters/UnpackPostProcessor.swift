import Foundation
import ChrysaCore
import ChrysaApplication

package protocol UnpackPostProcessor: Sendable {
    func process(outDir: String, parentURL: URL) async throws
}

package struct MacOSPermissionFixer: UnpackPostProcessor {
    private let supervisor: ProcessSupervisor
    package init(supervisor: ProcessSupervisor = .shared) { self.supervisor = supervisor }

    package func process(outDir: String, parentURL: URL) async throws {
        let output = URL(fileURLWithPath: outDir, isDirectory: true)
        guard let target = PathSafety.containedURL(output, in: parentURL),
              target.path == output.standardizedFileURL.path,
              target.path != parentURL.resolvingSymlinksInPath().standardizedFileURL.path,
              target.path != "/",
              (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
        
        _ = try? await supervisor.run(executable: "/bin/chmod", arguments: ["-R", "u+rwX", target.path])
        _ = try? await supervisor.run(executable: "/usr/bin/xattr", arguments: ["-cr", target.path])
    }
}
