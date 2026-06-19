import XCTest
@testable import CodeIsland

final class DiagnosticsManifestTests: XCTestCase {
    func testEntriesUseRelativePathsAndSkipManifestFile() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let sessionFile = stateDir.appendingPathComponent("sessions.json")
        try Data("{}".utf8).write(to: sessionFile)
        try Data("old manifest".utf8).write(to: root.appendingPathComponent("manifest.txt"))

        let entries = DiagnosticsManifest.entries(root: root, fm: fm)

        XCTAssertTrue(entries.contains { $0.path == "state" && $0.kind == "directory" })
        let sessionEntry = try XCTUnwrap(entries.first { $0.path == "state/sessions.json" })
        XCTAssertEqual(sessionEntry.kind, "file")
        XCTAssertEqual(sessionEntry.size, 2)
        XCTAssertFalse(entries.contains { $0.path == "manifest.txt" })
    }

    func testManifestTextIncludesHeaderAndFileRows() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data("abc".utf8).write(to: root.appendingPathComponent("metadata.json"))

        let text = DiagnosticsManifest.manifestText(
            root: root,
            generatedAt: Date(timeIntervalSince1970: 0),
            fm: fm
        )

        XCTAssertTrue(text.contains("CodeIsland diagnostics manifest"))
        XCTAssertTrue(text.contains("fileCount: 1"))
        XCTAssertTrue(text.contains("metadata.json\tfile\t3\t"))
    }
}
