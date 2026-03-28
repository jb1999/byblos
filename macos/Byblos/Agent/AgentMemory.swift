import Foundation

/// Persistent key-value memory store for the agent.
/// Stores facts the agent learns about the user across sessions.
@MainActor
class AgentMemory: ObservableObject {
    static let shared = AgentMemory()

    @Published private var store: [String: String] = [:]

    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let byblosDir = appSupport.appendingPathComponent("Byblos", isDirectory: true)

        // Ensure directory exists.
        try? FileManager.default.createDirectory(at: byblosDir, withIntermediateDirectories: true)

        fileURL = byblosDir.appendingPathComponent("agent-memory.json")
        load()
    }

    /// Store a fact about the user.
    func remember(key: String, value: String) {
        let normalizedKey = key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        store[normalizedKey] = value
        Log.info("[AgentMemory] Stored: \(normalizedKey) = \(value)")
        save()
    }

    /// Retrieve a fact by key.
    func recall(key: String) -> String? {
        let normalizedKey = key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return store[normalizedKey]
    }

    /// Retrieve all stored memories.
    func recallAll() -> [String: String] {
        store
    }

    /// Remove a specific memory.
    func forget(key: String) {
        let normalizedKey = key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        store.removeValue(forKey: normalizedKey)
        Log.info("[AgentMemory] Forgot: \(normalizedKey)")
        save()
    }

    /// Format all memories as a string suitable for LLM context.
    func contextString() -> String {
        guard !store.isEmpty else { return "" }
        let items = store.map { "- \($0.key): \($0.value)" }.sorted().joined(separator: "\n")
        return "User memories:\n\(items)"
    }

    /// Persist the store to disk as JSON.
    func save() {
        do {
            let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("[AgentMemory] Save failed: \(error)")
        }
    }

    /// Load the store from disk.
    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            if let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] {
                store = dict
                Log.info("[AgentMemory] Loaded \(dict.count) memories")
            }
        } catch {
            Log.error("[AgentMemory] Load failed: \(error)")
        }
    }
}
