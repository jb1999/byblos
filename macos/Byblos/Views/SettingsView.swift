import ServiceManagement
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
    @AppStorage("inputDevice") private var inputDevice = ""
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("autoStopEnabled") private var autoStopEnabled = true
    @AppStorage("autoStopDelay") private var autoStopDelay: Double = 3.0

    @StateObject private var audioService = AudioService()

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
        .frame(width: 480, height: 400)
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

            Divider()

            HStack(spacing: 16) {
                Button("Re-run Setup") {
                    UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                    // Access AppDelegate to show onboarding.
                    if let appDelegate = NSApp.delegate as? AppDelegate {
                        appDelegate.showOnboarding()
                    }
                }
                .controlSize(.small)

                Link("GitHub", destination: URL(string: "https://github.com/nicholasgasior/byblos")!)
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
