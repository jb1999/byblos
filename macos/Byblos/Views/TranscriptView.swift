import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

/// Observable state for the record button in TranscriptView.
@MainActor
class TranscriptRecordingState: ObservableObject {
    static let shared = TranscriptRecordingState()
    @Published var isRecording = false
    @Published var partialText = ""
}

struct TranscriptView: View {
    @EnvironmentObject var store: TranscriptStore
    @StateObject private var recordingState = TranscriptRecordingState.shared

    @State private var searchText = ""
    @State private var modeFilter: String?
    @State private var selectedEntryId: UUID?
    @State private var isTranscribingFile = false
    @State private var isDropTargeted = false
    @AppStorage("dictationMode") private var dictationMode = "clean"

    /// Supported audio/video file extensions for drag-and-drop import.
    private static let supportedExtensions: Set<String> = [
        "wav", "mp3", "m4a", "flac", "ogg", "mp4", "mov", "mkv",
    ]

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
        VStack(spacing: 0) {
            // Action bar at top — avoids toolbar/title overlap.
            HStack {
                modeFilterPicker
                Spacer()
                exportMenu
                Button {
                    importAudioFile()
                } label: {
                    Label("Import Audio", systemImage: "doc.badge.plus")
                }
                .disabled(isTranscribingFile)
                .help("Import an audio or video file for transcription")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
            } detail: {
                detailPanel
            }
            .searchable(text: $searchText, prompt: "Search transcripts")

            Divider()

            // Bottom record bar
            recordBar
        }
        .overlay {
            if isTranscribingFile {
                ZStack {
                    Color.black.opacity(0.3)
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Transcribing file...")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .ignoresSafeArea()
            }
            if isDropTargeted {
                ZStack {
                    Color.accentColor.opacity(0.15)
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("Drop audio/video file to transcribe")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers)
        }
    }

    // MARK: - File Import

    private func importAudioFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .wav, .mp3, .mpeg4Audio,
            .mpeg4Movie, .quickTimeMovie,
            .audio,
        ]
        panel.message = "Select an audio or video file to transcribe"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        transcribeFileAt(url)
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            let ext = url.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else {
                DispatchQueue.main.async {
                    Log.error("Unsupported file type: \(ext)")
                }
                return
            }
            DispatchQueue.main.async {
                self.transcribeFileAt(url)
            }
        }
        return true
    }

    private func transcribeFileAt(_ url: URL) {
        guard !isTranscribingFile else { return }
        isTranscribingFile = true
        let fileName = url.lastPathComponent
        Log.info("Transcribing file: \(fileName)")

        Task.detached {
            let wavPath: String
            let tempURL: URL?

            // Convert non-WAV files to WAV using afconvert.
            if url.pathExtension.lowercased() != "wav" {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("wav")
                tempURL = tmp

                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
                task.arguments = [url.path, tmp.path, "-d", "LEF32", "-f", "WAVE", "-r", "16000"]
                do {
                    try task.run()
                    task.waitUntilExit()
                    guard task.terminationStatus == 0 else {
                        await MainActor.run {
                            Log.error("afconvert failed with status \(task.terminationStatus) for: \(fileName)")
                            self.isTranscribingFile = false
                        }
                        return
                    }
                } catch {
                    await MainActor.run {
                        Log.error("Failed to convert file: \(error)")
                        self.isTranscribingFile = false
                    }
                    return
                }
                wavPath = tmp.path
            } else {
                wavPath = url.path
                tempURL = nil
            }

            // Create a temporary engine for file transcription.
            guard let modelPath = ByblosEngine.defaultModelPath() else {
                await MainActor.run {
                    Log.error("No model found for file transcription")
                    self.isTranscribingFile = false
                }
                return
            }
            let language = UserDefaults.standard.string(forKey: "language") ?? "en"
            guard let fileEngine = ByblosEngine(modelPath: modelPath, language: language) else {
                await MainActor.run {
                    Log.error("Failed to create engine for file transcription")
                    self.isTranscribingFile = false
                }
                return
            }

            let result = fileEngine.transcribeFile(path: wavPath)

            // Clean up temp file.
            if let tmp = tempURL {
                try? FileManager.default.removeItem(at: tmp)
            }

            await MainActor.run {
                self.isTranscribingFile = false
                guard let text = result, !text.isEmpty else {
                    Log.info("File transcription returned empty result for: \(fileName)")
                    return
                }

                let entry = TranscriptEntry(
                    text: text,
                    rawText: text,
                    mode: "raw",
                    duration: 0,
                    language: language,
                    appContext: "File: \(fileName)"
                )
                self.store.addEntry(entry)
                self.selectedEntryId = entry.id
                Log.info("File transcription complete: \(fileName) (\(text.count) chars)")
            }
        }
    }

    // MARK: - Record Bar

    private var recordBar: some View {
        HStack(spacing: 12) {
            Button {
                NotificationCenter.default.post(
                    name: Notification.Name("ByblosToggleRecording"),
                    object: nil
                )
            } label: {
                ZStack {
                    if recordingState.isRecording {
                        // Pulsing red background
                        Circle()
                            .fill(Color.red.opacity(0.2))
                            .frame(width: 44, height: 44)

                        // Stop square icon
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.red)
                            .frame(width: 16, height: 16)
                    } else {
                        // Red record circle
                        Circle()
                            .fill(Color.red)
                            .frame(width: 20, height: 20)
                    }
                }
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .stroke(Color.red.opacity(0.3), lineWidth: 2)
                )
            }
            .buttonStyle(.plain)
            .help(recordingState.isRecording ? "Stop Recording" : "Start Recording")

            if recordingState.isRecording {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording...")
                        .font(.caption)
                        .foregroundStyle(.red)
                    if !recordingState.partialText.isEmpty {
                        Text(recordingState.partialText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            } else {
                Text("Click to record")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
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

    // MARK: - Export

    private var exportMenu: some View {
        Menu {
            Button("Export as Markdown (.md)") {
                exportTranscripts(format: .markdown)
            }
            Button("Export as Plain Text (.txt)") {
                exportTranscripts(format: .plainText)
            }
            Button("Export as JSON (.json)") {
                exportTranscripts(format: .json)
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(store.entries.isEmpty)
        .help("Export transcripts to a file")
    }

    private enum ExportFormat {
        case markdown, plainText, json
    }

    private static let exportDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func exportTranscripts(format: ExportFormat) {
        // Use selected entry if one is selected, otherwise export all filtered entries.
        let entriesToExport: [TranscriptEntry]
        if let selected = selectedEntry {
            entriesToExport = [selected]
        } else {
            entriesToExport = filteredEntries.isEmpty ? store.entries : filteredEntries
        }

        guard !entriesToExport.isEmpty else { return }

        let panel = NSSavePanel()
        let defaultName: String
        let contentType: UTType

        switch format {
        case .markdown:
            defaultName = "transcripts.md"
            contentType = UTType(filenameExtension: "md") ?? .plainText
        case .plainText:
            defaultName = "transcripts.txt"
            contentType = .plainText
        case .json:
            defaultName = "transcripts.json"
            contentType = .json
        }

        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = defaultName

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let content: String
        switch format {
        case .markdown:
            content = entriesToExport.map { entry in
                var md = "## \(Self.exportDateFormatter.string(from: entry.date))\n\n"
                md += entry.text + "\n\n"
                md += "- **Mode:** \(DictationMode.mode(forId: entry.mode).name)\n"
                md += "- **Duration:** \(String(format: "%.1f", entry.duration))s\n"
                if let app = entry.appContext {
                    md += "- **App:** \(app)\n"
                }
                md += "\n---\n"
                return md
            }.joined(separator: "\n")

        case .plainText:
            content = entriesToExport.map { entry in
                "\(Self.exportDateFormatter.string(from: entry.date))\n\(entry.text)\n"
            }.joined(separator: "\n---\n\n")

        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(entriesToExport),
               let jsonStr = String(data: data, encoding: .utf8) {
                content = jsonStr
            } else {
                Log.error("Failed to encode transcripts to JSON")
                return
            }
        }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            Log.info("Exported \(entriesToExport.count) transcripts to \(url.lastPathComponent)")
        } catch {
            Log.error("Failed to export transcripts: \(error)")
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
