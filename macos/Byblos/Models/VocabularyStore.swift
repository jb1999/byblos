import Foundation

/// Manages a custom word replacement dictionary that runs after transcription.
@MainActor
final class VocabularyStore: ObservableObject {
    static let shared = VocabularyStore()

    /// Map of source phrase (lowercased) to replacement text.
    @Published var entries: [String: String] = [:]

    private let storageURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Byblos")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vocabulary.json")
    }()

    private init() {
        load()
    }

    // MARK: - CRUD

    func addEntry(source: String, replacement: String) {
        let key = source.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        entries[key] = replacement
        save()
        Log.info("Vocabulary: added '\(key)' -> '\(replacement)'")
    }

    func removeEntry(source: String) {
        let key = source.lowercased()
        entries.removeValue(forKey: key)
        save()
        Log.info("Vocabulary: removed '\(key)'")
    }

    /// Sorted list of entries for display.
    var sortedEntries: [(source: String, replacement: String)] {
        entries.sorted { $0.key < $1.key }.map { (source: $0.key, replacement: $0.value) }
    }

    // MARK: - Apply

    /// Applies case-insensitive word boundary replacement to the given text.
    /// Must be called on the main actor.
    func apply(to text: String) -> String {
        guard !entries.isEmpty else { return text }

        var result = text
        for (source, replacement) in entries {
            let escaped = NSRegularExpression.escapedPattern(for: source)
            let pattern = "\\b\(escaped)\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
            )
        }
        return result
    }

    // MARK: - Import / Export

    func exportJSON() -> Data? {
        try? JSONEncoder().encode(entries)
    }

    func importJSON(from data: Data) {
        guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            Log.error("Vocabulary: failed to decode import JSON")
            return
        }
        for (key, value) in decoded {
            entries[key.lowercased()] = value
        }
        save()
        Log.info("Vocabulary: imported \(decoded.count) entries")
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            Log.error("Vocabulary: failed to save: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            entries = try JSONDecoder().decode([String: String].self, from: data)
            Log.info("Vocabulary: loaded \(entries.count) entries")
        } catch {
            Log.error("Vocabulary: failed to load: \(error)")
        }
    }
}
