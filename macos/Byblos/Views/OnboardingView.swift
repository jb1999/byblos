import AVFoundation
import SwiftUI

/// Multi-step onboarding shown on first launch.
struct OnboardingView: View {
    @State private var currentStep = 0
    @State private var micGranted = false
    @State private var checkingMic = false
    @StateObject private var downloader = ModelDownloader()
    @State private var selectedModelId: String?
    @State private var downloadComplete = false

    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Step content
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: microphoneStep
                case 2: accessibilityStep
                case 3: modelStep
                case 4: readyStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Step indicators
            HStack(spacing: 8) {
                ForEach(0..<5, id: \.self) { index in
                    Circle()
                        .fill(index == currentStep ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.bottom, 20)
        }
        .frame(width: 500, height: 400)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Welcome to Byblos")
                .font(.largeTitle.bold())

            Text("Local voice-to-text. Private. Fast.")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("Your voice never leaves your machine.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)

            Spacer()

            Button("Get Started") {
                withAnimation { currentStep = 1 }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 12)
        }
        .padding()
    }

    // MARK: - Step 2: Microphone Permission

    private var microphoneStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: micGranted ? "checkmark.circle.fill" : "mic.circle")
                .font(.system(size: 48))
                .foregroundStyle(micGranted ? .green : .accentColor)

            Text("Microphone Access")
                .font(.title2.bold())

            Text("Byblos needs access to your microphone to transcribe your voice. Audio is processed entirely on your device.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            if !micGranted {
                Button(checkingMic ? "Requesting..." : "Grant Microphone Access") {
                    requestMicAccess()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(checkingMic)
            } else {
                Label("Microphone access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }

            Spacer()

            Button("Continue") {
                withAnimation { currentStep = 2 }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!micGranted)
            .padding(.bottom, 12)
        }
        .padding()
        .onAppear { checkCurrentMicStatus() }
    }

    // MARK: - Step 3: Accessibility

    @State private var accessibilityGranted = false

    private var accessibilityStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "hand.raised.circle")
                .font(.system(size: 48))
                .foregroundStyle(accessibilityGranted ? .green : .accentColor)

            Text("Accessibility Permission")
                .font(.title2.bold())

            Text("Byblos needs Accessibility permission to type transcriptions directly into your apps and to enable the hold-to-record hotkey.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            if !accessibilityGranted {
                Button("Open Accessibility Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                VStack(spacing: 4) {
                    Text("Click +, find Byblos.app, add it, and enable the toggle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Then click Check below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

                Button("Check Permission") {
                    accessibilityGranted = AXIsProcessTrusted()
                }
                .controlSize(.regular)

                VStack(spacing: 2) {
                    Text("Without Accessibility:")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text("• Transcriptions are copied to clipboard (paste with ⌘V)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("• Hold-to-record hotkey will not work")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 340)
                .padding(.top, 4)
            } else {
                Label("Accessibility granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }

            Spacer()

            HStack(spacing: 16) {
                if !accessibilityGranted {
                    Button("Skip (clipboard only)") {
                        withAnimation { currentStep = 3 }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                Button("Continue") {
                    withAnimation { currentStep = 3 }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!accessibilityGranted)
            }
            .padding(.bottom, 12)
        }
        .padding()
        .onAppear {
            accessibilityGranted = AXIsProcessTrusted()
        }
    }

    // MARK: - Step 4: Download a Model

    private var modelStep: some View {
        VStack(spacing: 10) {
            Text("Download Models")
                .font(.title2.bold())
                .padding(.top, 16)

            Text("Pick a speech model (required) and optionally an AI model for smarter features.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            let speechModels = downloader.models.filter { $0.category == .speech }
            let llmModels = downloader.models.filter {
                ["qwen3.5-4b", "qwen3-8b", "phi-3.5-mini"].contains($0.id)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Speech (required)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)

                    ForEach(speechModels) { model in
                        modelRow(model)
                    }

                    Divider()
                        .padding(.vertical, 4)
                        .padding(.horizontal, 20)

                    Text("AI — optional, enables smart cleanup + Agent")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)

                    ForEach(llmModels) { model in
                        modelRow(model)
                    }
                }
                .padding(.horizontal, 20)
            }
            .frame(maxHeight: 240)

            if let error = downloader.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Spacer()

            Button("Continue") {
                withAnimation { currentStep = 4 }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!downloadComplete)
            .padding(.bottom, 10)
        }
        .padding()
        .onReceive(downloader.objectWillChange) { _ in
            DispatchQueue.main.async {
                let hasAny = downloader.models.contains(where: {
                    $0.isDownloaded && $0.category == .speech
                })
                if hasAny { downloadComplete = true }
            }
        }
        .onAppear {
            downloader.refreshModelStates()
            let hasAny = downloader.models.contains(where: {
                $0.isDownloaded && $0.category == .speech
            })
            if hasAny { downloadComplete = true }
        }
    }


    private func modelRow(_ model: ModelEntry) -> some View {
        let isRecommended = model.id == "distil-whisper-large-v3"
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.headline)
                    if isRecommended {
                        Text("Recommended")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
                Text("\(model.sizeLabel) — \(model.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if let progress = downloader.activeDownloads[model.id] {
                VStack(spacing: 2) {
                    ProgressView(value: progress.fractionCompleted)
                        .frame(width: 70)
                    Text(progress.statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button {
                    downloader.cancelDownload(id: model.id)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            } else {
                Button("Download") {
                    selectedModelId = model.id
                    downloader.downloadModel(id: model.id)
                    // Auto-select this model for use.
                    UserDefaults.standard.set(model.id, forKey: "selectedModel")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isRecommended ? Color.accentColor.opacity(0.05) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isRecommended ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15), lineWidth: 1)
                )
        )
    }

    // MARK: - Step 4: Ready

    @State private var showInDock = true

    private var readyStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.title.bold())

            Text("Where should Byblos appear?")
                .font(.callout)
                .foregroundStyle(.secondary)

            // Dock vs Menu Bar choice
            VStack(spacing: 10) {
                Button {
                    showInDock = true
                } label: {
                    HStack {
                        Image(systemName: showInDock ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(showInDock ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dock").font(.callout.bold())
                            Text("Always visible. Click to open. Recommended.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(showInDock ? Color.accentColor.opacity(0.08) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(showInDock ? Color.accentColor.opacity(0.3) : Color.gray.opacity(0.2)))
                }
                .buttonStyle(.plain)

                Button {
                    showInDock = false
                } label: {
                    HStack {
                        Image(systemName: !showInDock ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(!showInDock ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Menu Bar Only").font(.callout.bold())
                            Text("Hidden in the menu bar. May be hidden if menu bar is full.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(!showInDock ? Color.accentColor.opacity(0.08) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(!showInDock ? Color.accentColor.opacity(0.3) : Color.gray.opacity(0.2)))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 360)

            Spacer()

            Button("Start Using Byblos") {
                UserDefaults.standard.set(showInDock, forKey: "showInDock")
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 12)
        }
        .padding()
    }

    // MARK: - Mic Helpers

    private func checkCurrentMicStatus() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micGranted = true
        default:
            micGranted = false
        }
    }

    private func requestMicAccess() {
        checkingMic = true
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                micGranted = granted
                checkingMic = false
                if granted {
                    Log.info("Microphone access granted via onboarding")
                } else {
                    Log.info("Microphone access denied via onboarding")
                }
            }
        }
    }
}

// MARK: - Onboarding Window

@MainActor
class OnboardingWindowController {
    private var window: NSWindow?

    func showOnboarding(completion: @escaping () -> Void) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let onboardingView = OnboardingView {
            completion()
        }

        let hostView = NSHostingView(rootView: onboardingView)
        hostView.frame = NSRect(x: 0, y: 0, width: 500, height: 400)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Welcome to Byblos"
        win.contentView = hostView
        win.center()
        win.isReleasedWhenClosed = false
        window = win

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }
}
