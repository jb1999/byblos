import AppKit
import ServiceManagement
import SwiftUI

/// Simple file logger that always works, regardless of macOS log settings.
enum Log {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Byblos.log")

    static func info(_ msg: String) { write("INFO", msg) }
    static func error(_ msg: String) { write("ERROR", msg) }

    private static func write(_ level: String, _ msg: String) {
        let line = "[\(level)] \(msg)\n"
        // Always print to stderr (visible when run from terminal).
        fputs(line, stderr)
        // Also append to log file.
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlayWindow: OverlayWindow?
    private var hotkeyService: HotkeyService!
    private var accessibilityService: AccessibilityService!
    private var engine: ByblosEngine?
    private var isRecording = false
    private var previousApp: NSRunningApplication?
    private var lastTranscriptionTime: Double?
    private var streamingTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Byblos starting up...")
        setupEngine()
        setupMenuBar()
        setupHotkey()
        setupAccessibility()
        NSApp.setActivationPolicy(.accessory)
        Log.info("Byblos ready. Engine loaded: \(self.engine != nil)")
    }

    // MARK: - Engine

    private func setupEngine() {
        guard let modelPath = ByblosEngine.defaultModelPath() else {
            Log.error("No model found. Run: ./scripts/download-model.sh whisper-base-en")
            return
        }
        let language = UserDefaults.standard.string(forKey: "language") ?? "en"
        Log.info("Loading model from: \(modelPath), language: \(language)")
        engine = ByblosEngine(modelPath: modelPath, language: language)
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon()
        rebuildMenu()
    }

    private var currentModelDisplayName: String {
        let selectedModel = UserDefaults.standard.string(forKey: "selectedModel") ?? "whisper-base"
        let names: [String: String] = [
            "whisper-tiny": "Whisper Tiny",
            "whisper-base": "Whisper Base",
            "whisper-small": "Whisper Small",
            "whisper-medium": "Whisper Medium",
            "distil-whisper": "Distil-Whisper",
            "moonshine-tiny": "Moonshine Tiny",
        ]
        return names[selectedModel] ?? selectedModel
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let recordTitle = isRecording ? "⏹ Stop Recording" : "⏺ Start Recording"
        let recordItem = NSMenuItem(title: recordTitle, action: #selector(menuToggleRecording), keyEquivalent: "")
        recordItem.target = self
        recordItem.isEnabled = engine != nil
        menu.addItem(recordItem)

        menu.addItem(NSMenuItem.separator())

        // Status info: model name + recording state.
        let statusText: String
        if isRecording {
            statusText = "Recording..."
        } else if engine != nil {
            statusText = "Ready — \(currentModelDisplayName)"
        } else {
            statusText = "No model loaded"
        }
        let statusInfo = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusInfo.isEnabled = false
        menu.addItem(statusInfo)

        // Show last transcription time if available.
        if let lastTime = lastTranscriptionTime {
            let timeStr = String(format: "%.1f", lastTime)
            let timeItem = NSMenuItem(title: "Last: \(timeStr)s", action: nil, keyEquivalent: "")
            timeItem.isEnabled = false
            menu.addItem(timeItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Launch at Login toggle.
        let launchAtLogin = SMAppService.mainApp.status == .enabled
        let loginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(menuToggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit Byblos", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func menuToggleRecording() {
        Log.info("Menu toggle recording clicked. isRecording=\(self.isRecording)")
        toggleRecording()
    }
    @objc private func menuOpenSettings() { openSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuToggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                Log.info("Unregistered launch at login")
            } else {
                try service.register()
                Log.info("Registered launch at login")
            }
        } catch {
            Log.error("Failed to toggle launch at login: \(error)")
        }
        rebuildMenu()
    }

    // MARK: - Recording

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard engine != nil else {
            Log.error("No engine loaded — cannot record.")
            return
        }

        // Remember which app was active before the menu bar click.
        // NSWorkspace.shared.frontmostApplication will be Byblos itself at this point
        // since the menu bar was clicked. Use menuBarOwningApplication or runningApplications instead.
        previousApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.isActive && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }) ?? NSWorkspace.shared.frontmostApplication

        isRecording = true
        updateMenuBarIcon()
        rebuildMenu()
        showOverlay()

        if engine?.startRecording() != true {
            Log.error("Failed to start recording from engine")
            isRecording = false
            updateMenuBarIcon()
            rebuildMenu()
            hideOverlay()
        } else {
            Log.info("Recording started. Previous app: \(self.previousApp?.localizedName ?? "none")")
            startStreamingPolling()
        }
    }

    private func startStreamingPolling() {
        streamingTimer?.invalidate()
        // Poll for partial transcription every 2 seconds.
        streamingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let eng = self.engine
            DispatchQueue.global(qos: .userInitiated).async {
                guard let partial = eng?.transcribeSnapshot(), !partial.isEmpty else { return }
                DispatchQueue.main.async {
                    self.overlayWindow?.updatePartialText(partial)
                    Log.info("Partial: \(partial)")
                }
            }
        }
    }

    private func stopStreamingPolling() {
        streamingTimer?.invalidate()
        streamingTimer = nil
    }

    private func stopRecording() {
        guard isRecording else { return }

        stopStreamingPolling()
        let recordingStopTime = CFAbsoluteTimeGetCurrent()

        isRecording = false
        updateMenuBarIcon()
        rebuildMenu()
        overlayWindow?.setProcessing(true)
        Log.info("Recording stopped, transcribing...")

        // Show a processing indicator.
        statusItem.button?.image = NSImage(
            systemSymbolName: "ellipsis.circle",
            accessibilityDescription: "Byblos (Transcribing)"
        )

        // Re-activate the previous app so typed text goes there.
        let targetApp = previousApp
        if let app = targetApp {
            Log.info("Re-activating: \(app.localizedName ?? "unknown")")
            app.activate()
        }

        // Determine the output mode from settings.
        let outputModeSetting = UserDefaults.standard.string(forKey: "outputMode") ?? "type"
        let outputMode: AccessibilityService.OutputMode = outputModeSetting == "clipboard"
            ? .clipboard
            : .accessibilityFirst

        // Run transcription on a background thread to keep UI responsive.
        let eng = engine
        let accessibility = accessibilityService!
        DispatchQueue.global(qos: .userInitiated).async {
            let text = eng?.stopAndTranscribe()
            // Use engine-reported time if available, otherwise wall-clock.
            let engineMs = eng?.transcriptionTimeMs() ?? 0
            let elapsed: Double
            if engineMs > 0 {
                elapsed = Double(engineMs) / 1000.0
            } else {
                elapsed = CFAbsoluteTimeGetCurrent() - recordingStopTime
            }

            DispatchQueue.main.async { [weak self] in
                self?.hideOverlay()
                self?.updateMenuBarIcon()

                self?.lastTranscriptionTime = elapsed
                self?.rebuildMenu()

                guard let text, !text.isEmpty else {
                    Log.info("No transcription result (empty or nil)")
                    return
                }

                Log.info("Transcribed (\(String(format: "%.1f", elapsed))s): \(text)")
                accessibility.typeText(text, mode: outputMode)
            }
        }
    }

    private func updateMenuBarIcon() {
        let symbolName = isRecording ? "record.circle" : "waveform"
        statusItem.button?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: isRecording ? "Byblos (Recording)" : "Byblos"
        )
        statusItem.button?.contentTintColor = isRecording ? .systemRed : nil
    }

    // MARK: - Overlay

    private func showOverlay() {
        if overlayWindow == nil {
            overlayWindow = OverlayWindow()
        }
        overlayWindow?.show()
    }

    private func hideOverlay() {
        overlayWindow?.hide()
    }

    // MARK: - Setup

    private func setupHotkey() {
        // CGEvent tap requires accessibility permission.
        // Only register if already granted — don't trigger a prompt.
        guard AXIsProcessTrusted() else {
            Log.info("Accessibility not granted — hotkey disabled. Use the menu bar to record.")
            return
        }

        let modifierSetting = UserDefaults.standard.string(forKey: "hotkeyModifier") ?? "option"
        let modifier = HotkeyModifier.from(setting: modifierSetting)

        hotkeyService = HotkeyService()
        hotkeyService.hotkeyModifier = modifier
        hotkeyService.onHotkeyDown = { [weak self] in
            DispatchQueue.main.async { self?.startRecording() }
        }
        hotkeyService.onHotkeyUp = { [weak self] in
            DispatchQueue.main.async { self?.stopRecording() }
        }
        hotkeyService.register()
        Log.info("Hotkey registered (hold \(modifierSetting) to record)")
    }

    private func setupAccessibility() {
        accessibilityService = AccessibilityService()
    }

    // MARK: - Settings

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
