import Foundation

public struct ProjectFolder: Identifiable, Equatable, Sendable {
    public let path: String
    public let name: String
    public var id: String { path }
}

public enum ProjectFolders {
    /// An existing directory lists its children; a partial path filters its parent.
    public static func list(_ input: String) throws -> [ProjectFolder] {
        let path = NSString(string: input).expandingTildeInPath
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
        let base = exists && directory.boolValue ? path : (path as NSString).deletingLastPathComponent
        let prefix = exists && directory.boolValue ? "" : (path as NSString).lastPathComponent
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: base),
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  url.lastPathComponent.localizedStandardContains(prefix) || prefix.isEmpty else { return nil }
            return ProjectFolder(path: url.path, name: url.lastPathComponent)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
