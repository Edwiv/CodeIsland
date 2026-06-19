import Foundation

struct DiagnosticsManifestEntry: Equatable {
    let path: String
    let kind: String
    let size: Int64
    let modifiedAt: String?
}

struct DiagnosticsManifest {
    static func write(root: URL, generatedAt: Date = Date(), fm: FileManager = .default) {
        let text = manifestText(root: root, generatedAt: generatedAt, fm: fm)
        let url = root.appendingPathComponent("manifest.txt")
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func manifestText(root: URL, generatedAt: Date = Date(), fm: FileManager = .default) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows = entries(root: root, fm: fm)
        var lines: [String] = [
            "CodeIsland diagnostics manifest",
            "generatedAt: \(iso.string(from: generatedAt))",
            "fileCount: \(rows.count)",
            "",
            "path\tkind\tsize\tmodifiedAt",
        ]
        lines.append(contentsOf: rows.map { entry in
            "\(entry.path)\t\(entry.kind)\t\(entry.size)\t\(entry.modifiedAt ?? "")"
        })
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func entries(root: URL, fm: FileManager = .default) -> [DiagnosticsManifestEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return []
        }

        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var rows: [DiagnosticsManifestEntry] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent != "manifest.txt" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let standardized = url.standardizedFileURL.path
            let relative = standardized.hasPrefix(prefix)
                ? String(standardized.dropFirst(prefix.count))
                : url.lastPathComponent
            rows.append(DiagnosticsManifestEntry(
                path: relative,
                kind: isDirectory ? "directory" : "file",
                size: isDirectory ? 0 : Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate.map { iso.string(from: $0) }
            ))
        }
        return rows.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
