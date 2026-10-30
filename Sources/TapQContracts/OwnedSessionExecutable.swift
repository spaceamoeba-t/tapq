import Foundation

/// Where an agent CLI is, decided once by TapQ from an environment it can see.
public enum OwnedSessionExecutable {
    /// The absolute path of `name` on `PATH`, or `nil`.
    ///
    /// The same scan `CodexCLIProcessRunner` performs, and for the same reason: TapQ decides
    /// which executable it is starting, once, rather than handing a bare name to the
    /// process machinery and finding out afterwards.
    public static func resolve(
        named name: String,
        environment: [String: String],
        workingDirectoryPath: String
    ) -> String? {
        guard let path = environment["PATH"] else { return nil }
        for component in path.split(separator: ":", omittingEmptySubsequences: false) {
            let directory = component.isEmpty
                ? URL(fileURLWithPath: workingDirectoryPath, isDirectory: true)
                : URL(fileURLWithPath: String(component), isDirectory: true)
            let candidate = directory.appendingPathComponent(name).standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    /// Whether `path` is a directory a session can be started in.
    public static func isUsableDirectory(_ path: String) -> Bool {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }
}
