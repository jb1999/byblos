import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("selectedModel") private var selectedModel = "whisper-base"
    @AppStorage("hotkeyModifier") private var hotkeyModifier = "option"
    @AppStorage("denoiseEnabled") private var denoiseEnabled = true
    @AppStorage("vadEnabled") private var vadEnabled = true
    @AppStorage("voiceCommands") private var voiceCommands = true
    @AppStorage("autoCapitalize") private var autoCapitalize = true
    @AppStorage("language") private var language = "en"
    @AppStorage("outputMode") private var outputMode = "type"
    @AppStorage("inputDevice") private var inputDevice = ""
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("autoStopEnabled") private var autoStopEnabled = true
    @AppStorage("autoStopDelay") private var autoStopDelay: Double = 3.0
    @AppStorage("appAwareMode") private var appAwareMode = true

    @StateObject private var audioService = AudioService()

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case models = "Models"
        case audio = "Audio"
        case vocabulary = "Vocabulary"
        case about = "About"

        var icon: String {
            switch self {
            case .general: "gear"
            case .models: "cpu"
            case .audio: "mic"
            case .vocabulary: "character.book.closed"
            case .about: "info.circle"
            }
        }
    }

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 180)
        } detail: {
            Group {
                switch selectedTab {
                case .general: generalTab
                case .models: modelsTab
                case .audio: audioTab
                case .vocabulary: vocabularyTab
                case .about: aboutTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 600, height: 440)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Picker("Hold key to record", selection: $hotkeyModifier) {
                Text("⌥ Option").tag("option")
                Text("⌃ Control").tag("control")
                Text("fn Function").tag("fn")
            }

            Picker("Output mode", selection: $outputMode) {
                Text("Type into active app").tag("type")
                Text("Copy to clipboard").tag("clipboard")
            }

            Toggle("Voice commands", isOn: $voiceCommands)
            Toggle("Auto-capitalize", isOn: $autoCapitalize)
            Toggle("Auto-select mode based on app", isOn: $appAwareMode)

            Toggle("Launch at Login", isOn: Binding(
                get: {
                    SMAppService.mainApp.status == .enabled
                },
                set: { newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                            Log.info("Registered launch at login via Settings")
                        } else {
                            try SMAppService.mainApp.unregister()
                            Log.info("Unregistered launch at login via Settings")
                        }
                        launchAtLogin = newValue
                    } catch {
                        Log.error("Failed to toggle launch at login: \(error)")
                    }
                }
            ))

            Picker("Language", selection: $language) {
                Text("Auto-detect").tag("auto")
                Text("English").tag("en")
                Text("Spanish").tag("es")
                Text("French").tag("fr")
                Text("German").tag("de")
                Text("Italian").tag("it")
                Text("Portuguese").tag("pt")
                Text("Japanese").tag("ja")
                Text("Chinese").tag("zh")
                Text("Korean").tag("ko")
                Text("Russian").tag("ru")
                Text("Arabic").tag("ar")
                Text("Hindi").tag("hi")
                Text("Dutch").tag("nl")
                Text("Polish").tag("pl")
                Text("Turkish").tag("tr")
                Text("Ukrainian").tag("uk")
                Text("Swedish").tag("sv")
            }

            Divider()

            Toggle("Auto-stop on silence", isOn: $autoStopEnabled)

            if autoStopEnabled {
                HStack {
                    Text("Silence delay")
                    Slider(value: $autoStopDelay, in: 1...10, step: 1) {
                        Text("Silence delay")
                    }
                    Text("\(Int(autoStopDelay))s")
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
        .padding()
    }

    // MARK: - Models

    private var modelsTab: some View {
        ModelManagerView()
            .padding()
    }

    // MARK: - Audio

    private var audioTab: some View {
        Form {
            Picker("Input device", selection: $inputDevice) {
                Text("System Default").tag("")
                ForEach(audioService.availableDevices) { device in
                    Text(device.name + (device.isDefault ? " (Default)" : ""))
                        .tag(device.id)
                }
            }

            Toggle("Noise suppression", isOn: $denoiseEnabled)
            Toggle("Voice activity detection", isOn: $vadEnabled)

            Button("Refresh Devices") {
                audioService.refreshDevices()
            }
            .font(.caption)

            // TODO: VAD sensitivity slider
            // TODO: Audio level meter
        }
        .padding()
    }

    // MARK: - Vocabulary

    private var vocabularyTab: some View {
        VocabularySettingsView()
            .padding()
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Text("Byblos")
                .font(.title)

            Text("Local voice-to-text")
                .foregroundStyle(.secondary)

            Text("Version \(appVersion)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()

            Text("Your voice never leaves your machine.")
                .font(.callout)

            Divider()

            // License section.
            LicenseSettingsSection()

            Divider()

            VStack(spacing: 4) {
                Text("Byblos is shareware — free to use with no restrictions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Link("Buy Annual License →", destination: URL(string: "https://byblos.im/#support")!)
                    .font(.callout)
                    .padding(.top, 4)
            }

            Spacer()

            HStack(spacing: 16) {
                Button("Re-run Setup") {
                    UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                    if let appDelegate = NSApp.delegate as? AppDelegate {
                        appDelegate.showOnboarding()
                    }
                }
                .controlSize(.small)

                Link("GitHub", destination: URL(string: "https://github.com/jb1999/byblos")!)
                    .font(.callout)
            }
        }
        .padding()
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - Vocabulary Settings

struct VocabularySettingsView: View {
    @StateObject private var store = VocabularyStore.shared
    @State private var newSource = ""
    @State private var newReplacement = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Vocabulary")
                .font(.headline)

            Text("Add word replacements that run after each transcription.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Add new entry
            HStack {
                TextField("Source phrase", text: $newSource)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)

                TextField("Replacement", text: $newReplacement)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)

                Button("Add") {
                    store.addEntry(source: newSource, replacement: newReplacement)
                    newSource = ""
                    newReplacement = ""
                }
                .disabled(newSource.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Divider()

            // Entry list
            if store.sortedEntries.isEmpty {
                Text("No vocabulary entries yet.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                List {
                    ForEach(store.sortedEntries, id: \.source) { entry in
                        HStack {
                            Text(entry.source)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text(entry.replacement)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fontWeight(.medium)
                            Button {
                                store.removeEntry(source: entry.source)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 100)
            }

            Divider()

            // Import / Export
            HStack {
                Button("Import JSON...") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [UTType.json]
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url,
                       let data = try? Data(contentsOf: url) {
                        store.importJSON(from: data)
                    }
                }

                Button("Export JSON...") {
                    guard let data = store.exportJSON() else { return }
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [UTType.json]
                    panel.nameFieldStringValue = "vocabulary.json"
                    if panel.runModal() == .OK, let url = panel.url {
                        try? data.write(to: url)
                    }
                }

                Spacer()

                Text("\(store.entries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - License Settings

struct LicenseSettingsSection: View {
    @ObservedObject private var license = LicenseService.shared
    @State private var keyInput = ""
    @State private var isActivating = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if license.isLicensed {
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Licensed")
                            .font(.callout.bold())
                        if let days = license.daysRemaining {
                            Text("\(days) days remaining")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let email = license.customerEmail {
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Button("Deactivate") {
                        Task { await license.deactivate() }
                    }
                    .controlSize(.small)
                    .foregroundStyle(.red)
                }
            } else {
                HStack {
                    TextField("Paste license key", text: $keyInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)

                    Button(isActivating ? "Activating..." : "Activate") {
                        activateKey()
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty || isActivating)
                }

                if let msg = statusMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(statusIsError ? .red : .green)
                }
            }
        }
    }

    private func activateKey() {
        isActivating = true
        statusMessage = nil
        Task {
            let success = await LicenseService.shared.activate(key: keyInput)
            isActivating = false
            if success {
                statusMessage = "License activated!"
                statusIsError = false
                keyInput = ""
            } else {
                statusMessage = LicenseService.shared.lastError ?? "Activation failed."
                statusIsError = true
            }
        }
    }
}
