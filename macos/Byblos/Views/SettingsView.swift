import SwiftUI

struct SettingsView: View {
    @AppStorage("selectedModel") private var selectedModel = "whisper-base"
    @AppStorage("hotkeyModifier") private var hotkeyModifier = "option"
    @AppStorage("denoiseEnabled") private var denoiseEnabled = true
    @AppStorage("vadEnabled") private var vadEnabled = true
    @AppStorage("voiceCommands") private var voiceCommands = true
    @AppStorage("autoCapitalize") private var autoCapitalize = true
    @AppStorage("language") private var language = "en"
    @AppStorage("outputMode") private var outputMode = "type"

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }

            modelsTab
                .tabItem { Label("Models", systemImage: "cpu") }

            audioTab
                .tabItem { Label("Audio", systemImage: "mic") }

            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 360)
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

            Picker("Language", selection: $language) {
                Text("English").tag("en")
                Text("Auto-detect").tag("auto")
            }
        }
        .padding()
    }

    // MARK: - Models

    private var modelsTab: some View {
        Form {
            Picker("Active model", selection: $selectedModel) {
                Text("Whisper Tiny (75 MB)").tag("whisper-tiny")
                Text("Whisper Base (142 MB)").tag("whisper-base")
                Text("Whisper Small (466 MB)").tag("whisper-small")
                Text("Whisper Medium (1.5 GB)").tag("whisper-medium")
                Text("Distil-Whisper (756 MB)").tag("distil-whisper")
                Text("Moonshine Tiny (60 MB)").tag("moonshine-tiny")
            }

            // TODO: Show download status, disk usage, benchmark results
            Text("Model management coming soon")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Audio

    private var audioTab: some View {
        Form {
            Toggle("Noise suppression", isOn: $denoiseEnabled)
            Toggle("Voice activity detection", isOn: $vadEnabled)

            // TODO: Input device picker
            // TODO: VAD sensitivity slider
            // TODO: Audio level meter
        }
        .padding()
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Text("Byblos")
                .font(.title)

            Text("Local voice-to-text")
                .foregroundStyle(.secondary)

            Text("v0.1.0")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()

            Text("Your voice never leaves your machine.")
                .font(.callout)

            Spacer()

            VStack(spacing: 4) {
                Text("Byblos is free to use.")
                    .font(.callout)
                Text("If you find it useful, please consider supporting development.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Link("Support Byblos →", destination: URL(string: "https://byblos.im/support")!)
                    .font(.callout)
                    .padding(.top, 4)
            }
        }
        .padding()
    }
}
