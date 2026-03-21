import Foundation

/// Searches local files using Spotlight (mdfind) and basic file operations.
struct FileSearch {

    /// Search for files matching a query using Spotlight.
    static func search(query: String, limit: Int = 10) -> [FileResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-name", trimmed]

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.error("[FileSearch] mdfind failed: \(error)")
            return []
        }

        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            Log.error("[FileSearch] mdfind error: \(errStr)")
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { path in
                let url = URL(fileURLWithPath: path)
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                return FileResult(
                    path: path,
                    name: url.lastPathComponent,
                    size: attrs?[.size] as? Int64 ?? 0,
                    modified: attrs?[.modificationDate] as? Date
                )
            }
    }

    /// Search for files by content (full-text search).
    static func searchContent(query: String, limit: Int = 10) -> [FileResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = [trimmed]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch { return [] }

        guard process.terminationStatus == 0 else { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { path in
                FileResult(
                    path: path,
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    size: 0,
                    modified: nil
                )
            }
    }

    /// Read the first N characters of a text file.
    static func readFile(at path: String, maxChars: Int = 4000) -> String? {
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expandedPath),
              let content = String(data: data, encoding: .utf8)
        else { return nil }

        if content.count > maxChars {
            return String(content.prefix(maxChars)) + "\n...(truncated)"
        }
        return content
    }

    /// List recent files modified in the last N hours.
    static func recentFiles(hours: Int = 24, limit: Int = 10) -> [FileResult] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = [
            "kMDItemFSContentChangeDate >= $time.now(-\(hours * 3600))",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch { return [] }

        guard process.terminationStatus == 0 else { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { path in
                FileResult(
                    path: path,
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    size: 0,
                    modified: nil
                )
            }
    }
}

struct FileResult {
    let path: String
    let name: String
    let size: Int64
    let modified: Date?

    var description: String {
        var parts = [name]
        if size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let mod = modified {
            let fmt = RelativeDateTimeFormatter()
            parts.append(fmt.localizedString(for: mod, relativeTo: Date()))
        }
        parts.append(path)
        return parts.joined(separator: " | ")
    }
}
