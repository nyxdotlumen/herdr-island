import Foundation
import IslandCore

final class ProjectFoldersTests {
    func testFolderBrowserFiltersAndExcludesFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("island-folders-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Alpha Project", "beta", ".hidden"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("file.txt"))
        let all = try ProjectFolders.list(root.path)
        expectEqual(all.map(\.name), ["Alpha Project", "beta"])
        let partial = try ProjectFolders.list(root.appendingPathComponent("alp").path)
        expectEqual(partial.map(\.name), ["Alpha Project"])
        expectEqual(partial.first.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }, root.appendingPathComponent("Alpha Project").resolvingSymlinksInPath().path)
        let empty = try ProjectFolders.list(root.appendingPathComponent("beta").path)
        expect(empty.isEmpty)
        expectThrows(try ProjectFolders.list(root.appendingPathComponent("missing/subfolder").path))
    }
}
