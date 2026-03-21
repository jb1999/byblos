import AppKit
import SwiftUI

// MARK: - Model

struct TranscriptEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    let rawText: String
    let mode: String
    let date: Date
    let duration: Double
    let language: String
    let appContext: String?

    init(
        id: UUID = UUID(),
        text: String,
        rawText: String,
        mode: String,
        date: Date = Date(),
        duration: Double,
        language: String,
        appContext: String? = nil
    ) {
        self.id = id
        self.text = text
        self.rawText = rawText
        self.mode = mode
        self.date = date
        self.duration = duration
        self.language = language
        self.appContext = appContext
    }
}

// MARK: - Store

@MainActor
class TranscriptStore: ObservableObject {
    static let shared = TranscriptStore()

    @Published var entries: [TranscriptEntry] = []

    private let storageURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Byblos")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("transcripts.json")
    }()

    private init() {
        load()
    }

    func addEntry(_ entry: TranscriptEntry) {
        entries.insert(entry, at: 0)
        save()
    }

    func deleteEntry(_ entry: TranscriptEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func deleteEntries(at offsets: IndexSet, from filtered: [TranscriptEntry]) {
        let idsToRemove = offsets.map { filtered[$0].id }
        entries.removeAll { idsToRemove.contains($0.id) }
        save()
    }

    func updateText(for entryId: UUID, newText: String) {
        guard let index = entries.firstIndex(where: { $0.id == entryId }) else { return }
        entries[index].text = newText
        save()
    }

    func filteredEntries(search: String, modeFilter: String?) -> [TranscriptEntry] {
        var result = entries
        if let modeFilter, !modeFilter.isEmpty {
            result = result.filter { $0.mode == modeFilter }
        }
        if !search.isEmpty {
            result = result.filter {
                $0.text.localizedCaseInsensitiveContains(search)
            }
        }
        return result
    }

    func exportToClipboard(_ entries: [TranscriptEntry]) {
        let text = entries.map { $0.text }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            Log.error("Failed to save transcripts: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            entries = try JSONDecoder().decode([TranscriptEntry].self, from: data)
        } catch {
            Log.error("Failed to load transcripts: \(error)")
        }
    }
}

// MARK: - Date Grouping

enum TranscriptDateGroup: String, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case thisWeek = "This Week"
    case earlier = "Earlier"

    static func group(for date: Date) -> TranscriptDateGroup {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        if date >= weekAgo { return .thisWeek }
        return .earlier
    }
}

// MARK: - Transcript Window

class TranscriptWindow: NSWindow {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "Byblos \u{2014} Transcripts"
        minSize = NSSize(width: 500, height: 350)
        isReleasedWhenClosed = false
        setFrameAutosaveName("ByblosTranscripts")
        center()

        let rootView = TranscriptView()
            .environmentObject(TranscriptStore.shared)
        contentView = NSHostingView(rootView: rootView)
    }
}

// MARK: - Main View

struct TranscriptView: View {
    @EnvironmentObject var store: TranscriptStore

    @State private var searchText = ""
    @State private var modeFilter: String?
    @State private var selectedEntryId: UUID?
    @AppStorage("dictationMode") private var dictationMode = "clean"

    var filteredEntries: [TranscriptEntry] {
        store.filteredEntries(search: searchText, modeFilter: modeFilter)
    }

    var groupedEntries: [(TranscriptDateGroup, [TranscriptEntry])] {
        let grouped = Dictionary(grouping: filteredEntries) {
            TranscriptDateGroup.group(for: $0.date)
        }
        return TranscriptDateGroup.allCases.compactMap { group in
            guard let entries = grouped[group], !entries.isEmpty else { return nil }
            return (group, entries)
        }
    }

    var selectedEntry: TranscriptEntry? {
        guard let id = selectedEntryId else { return nil }
        return store.entries.first { $0.id == id }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
        } detail: {
            detailPanel
        }
        .searchable(text: $searchText, prompt: "Search transcripts")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                modeFilterPicker
            }
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        if filteredEntries.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "text.bubble")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No Transcripts")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Recordings will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(selection: $selectedEntryId) {
                ForEach(groupedEntries, id: \.0) { group, entries in
                    Section(group.rawValue) {
                        ForEach(entries) { entry in
                            TranscriptRow(entry: entry)
                                .tag(entry.id)
                                .contextMenu {
                                    Button("Copy") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(entry.text, forType: .string)
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) {
                                        store.deleteEntry(entry)
                                        if selectedEntryId == entry.id {
                                            selectedEntryId = nil
                                        }
                                    }
                                }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPanel: some View {
        if let entry = selectedEntry {
            TranscriptDetailView(entry: entry)
                .id(entry.id)
                .environmentObject(store)
        } else {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "sidebar.left")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Select a Transcript")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Choose a transcript from the sidebar to view details.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Mode Filter

    private var modeFilterPicker: some View {
        Menu {
            Button("All Modes") { modeFilter = nil }
            Divider()
            ForEach(DictationMode.allModes) { mode in
                Button {
                    modeFilter = mode.id
                } label: {
                    Label(mode.name, systemImage: mode.icon)
                }
            }
        } label: {
            Label(
                modeFilter.map { DictationMode.mode(forId: $0).name } ?? "All Modes",
                systemImage: "line.3.horizontal.decrease.circle"
            )
        }
    }
}

// MARK: - Row

struct TranscriptRow: View {
    let entry: TranscriptEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.text)
                .font(.body)
                .lineLimit(2)
                .truncationMode(.tail)

            HStack(spacing: 6) {
                Image(systemName: DictationMode.mode(forId: entry.mode).icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(Self.timeFormatter.string(from: entry.date))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if let app = entry.appContext {
                    Text(app)
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail View

struct TranscriptDetailView: View {
    let entry: TranscriptEntry
    @EnvironmentObject var store: TranscriptStore
    @State private var editedText: String = ""
    @State private var isEditing = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Metadata bar
            HStack(spacing: 12) {
                Label(DictationMode.mode(forId: entry.mode).name, systemImage: DictationMode.mode(forId: entry.mode).icon)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(Self.dateFormatter.string(from: entry.date))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(String(format: "%.1fs", entry.duration))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let app = entry.appContext {
                    Text(app)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            // Text content
            if isEditing {
                TextEditor(text: $editedText)
                    .font(.body)
                    .padding()
                    .scrollContentBackground(.hidden)
            } else {
                ScrollView {
                    Text(entry.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }

            Divider()

            // Action bar
            HStack(spacing: 12) {
                if isEditing {
                    Button("Save") {
                        store.updateText(for: entry.id, newText: editedText)
                        isEditing = false
                    }
                    .keyboardShortcut(.return, modifiers: .command)

                    Button("Cancel") {
                        isEditing = false
                    }
                    .keyboardShortcut(.cancelAction)
                } else {
                    Button {
                        editedText = entry.text
                        isEditing = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }

                    Button(role: .destructive) {
                        store.deleteEntry(entry)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }

                    Spacer()

                    Button {
                        // Placeholder for future LLM re-processing.
                    } label: {
                        Label("Re-process", systemImage: "arrow.clockwise")
                    }
                    .disabled(true)
                    .help("LLM re-processing coming soon")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .onAppear {
            editedText = entry.text
            isEditing = false
        }
    }
}
