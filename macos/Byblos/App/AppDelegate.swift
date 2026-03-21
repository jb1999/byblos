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
    private var transcriptWindow: TranscriptWindow?
    private var hotkeyService: HotkeyService!
    private var accessibilityService: AccessibilityService!
    private var engine: ByblosEngine?
    private var isRecording = false
    private var previousApp: NSRunningApplication?
    private var lastTranscriptionTime: Double?
    private var recordingStartTime: CFAbsoluteTime = 0
    private var streamingTimer: Timer?
    /// Lock to prevent concurrent access to the whisper model from streaming and final transcription.
    private let engineLock = NSLock()
    /// Last successful partial transcription — used as fallback if final transcription fails.
    private var lastPartialText: String = ""

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

        // Try to load a local LLM for text post-processing.
        if let llmPath = ByblosEngine.defaultLlmPath() {
            Log.info("Loading LLM from: \(llmPath)")
            if engine?.loadLlm(path: llmPath) == true {
                Log.info("LLM loaded successfully")
            } else {
                Log.error("Failed to load LLM from \(llmPath)")
            }
        } else {
            Log.info("No LLM model found — dictation modes will use basic text processing")
        }
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

        // Dictation mode submenu.
        let currentModeId = UserDefaults.standard.string(forKey: "dictationMode") ?? "clean"
        let currentMode = DictationMode.mode(forId: currentModeId)
        let modeItem = NSMenuItem(title: "Mode: \(currentMode.name)", action: nil, keyEquivalent: "")
        let modeSubmenu = NSMenu()
        for mode in DictationMode.allModes {
            let item = NSMenuItem(title: mode.name, action: #selector(menuSelectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.id
            item.image = NSImage(systemSymbolName: mode.icon, accessibilityDescription: mode.name)
            if mode.id == currentModeId {
                item.state = .on
            }
            modeSubmenu.addItem(item)
        }
        modeItem.submenu = modeSubmenu
        menu.addItem(modeItem)

        menu.addItem(NSMenuItem.separator())

        let transcriptItem = NSMenuItem(
            title: "Show Transcripts",
            action: #selector(menuShowTranscripts),
            keyEquivalent: "t"
        )
        transcriptItem.keyEquivalentModifierMask = .command
        transcriptItem.target = self
        menu.addItem(transcriptItem)

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
    @objc private func menuShowTranscripts() { openTranscriptWindow() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuSelectMode(_ sender: NSMenuItem) {
        guard let modeId = sender.representedObject as? String else { return }
        UserDefaults.standard.set(modeId, forKey: "dictationMode")
        Log.info("Dictation mode changed to: \(modeId)")
        rebuildMenu()
    }

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
        recordingStartTime = CFAbsoluteTimeGetCurrent()
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
            lastPartialText = ""
            startStreamingPolling()
        }
    }

    private func startStreamingPolling() {
        streamingTimer?.invalidate()
        // Poll for partial transcription every 2 seconds.
        streamingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let eng = self.engine
            let lock = self.engineLock
            DispatchQueue.global(qos: .userInitiated).async {
                guard lock.try() else { return } // Skip if engine is busy.
                let partial = eng?.transcribeSnapshot()
                lock.unlock()
                guard let partial, !partial.isEmpty else { return }
                DispatchQueue.main.async {
                    self.overlayWindow?.updatePartialText(partial)
                    self.lastPartialText = partial
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

        // IMPORTANT: Stop streaming polling first and wait for any in-flight
        // snapshot transcription to complete before calling stopAndTranscribe.
        // Both use the same whisper model state and cannot run concurrently.
        stopStreamingPolling()

        let recordingStopTime = CFAbsoluteTimeGetCurrent()
        let recordingDuration = recordingStopTime - recordingStartTime

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

        // Get dictation mode for post-processing.
        let dictationModeId = UserDefaults.standard.string(forKey: "dictationMode") ?? "clean"
        let dictationMode = DictationMode.mode(forId: dictationModeId)
        let postProcess = dictationMode.postProcess
        let language = UserDefaults.standard.string(forKey: "language") ?? "en"
        let appContext = targetApp?.localizedName

        // Run transcription on a background thread to keep UI responsive.
        let eng = engine
        let accessibility = accessibilityService!
        let lock = engineLock
        let lastPartial = lastPartialText
        DispatchQueue.global(qos: .userInitiated).async {
            // Wait for any in-flight snapshot to finish.
            lock.lock()
            var rawText = eng?.stopAndTranscribe()
            lock.unlock()

            // If final transcription is empty but we had streaming partials, use those.
            if (rawText ?? "").isEmpty && !lastPartial.isEmpty {
                Log.info("Final transcription empty — using last streaming partial")
                rawText = lastPartial
            }
            // Use engine-reported time if available, otherwise wall-clock.
            let engineMs = eng?.transcriptionTimeMs() ?? 0
            let elapsed: Double
            if engineMs > 0 {
                elapsed = Double(engineMs) / 1000.0
            } else {
                elapsed = CFAbsoluteTimeGetCurrent() - recordingStopTime
            }

            // Apply dictation mode post-processing.
            let processedText = rawText.map { postProcess($0) }

            DispatchQueue.main.async { [weak self] in
                self?.hideOverlay()
                self?.updateMenuBarIcon()

                self?.lastTranscriptionTime = elapsed
                self?.rebuildMenu()

                guard let rawText, !rawText.isEmpty else {
                    Log.info("No transcription result (empty or nil)")
                    return
                }

                let finalText = processedText ?? rawText
                Log.info("Transcribed (\(String(format: "%.1f", elapsed))s): \(finalText)")

                // Save to transcript store.
                let entry = TranscriptEntry(
                    text: finalText,
                    rawText: rawText,
                    mode: dictationModeId,
                    duration: recordingDuration,
                    language: language,
                    appContext: appContext
                )
                TranscriptStore.shared.addEntry(entry)

                accessibility.typeText(finalText, mode: outputMode)
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

    private var settingsWindow: NSWindow?

    private func openSettings() {
        // If we already have a settings window, just bring it forward.
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Menu-bar-only apps (.accessory) cannot present windows that take focus.
        // Temporarily become a regular app so the settings window appears properly.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // macOS 14+ uses showSettingsWindow:, macOS 13 uses showPreferencesWindow:.
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }

        // Track the settings window so we can observe when it closes.
        // The Settings scene window typically appears after a brief run-loop cycle.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Find the settings window (it will be the key window after the action).
            let window = NSApp.windows.first(where: {
                $0.isVisible && $0 !== self.overlayWindow
            })
            self.settingsWindow = window

            if let window {
                Log.info("Settings window opened")
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(self.settingsWindowWillClose(_:)),
                    name: NSWindow.willCloseNotification,
                    object: window
                )
            } else {
                Log.error("Settings window not found — reverting to accessory mode")
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    @objc private func settingsWindowWillClose(_ notification: Notification) {
        Log.info("Settings window closed — reverting to accessory mode")
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: notification.object
        )
        settingsWindow = nil

        // Only revert to accessory if transcript window is also closed.
        if transcriptWindow == nil || !(transcriptWindow?.isVisible ?? false) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Transcript Window

    private func openTranscriptWindow() {
        if let existing = transcriptWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if transcriptWindow == nil {
            transcriptWindow = TranscriptWindow()
        }
        transcriptWindow?.makeKeyAndOrderFront(nil)
        Log.info("Transcript window opened")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(transcriptWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: transcriptWindow
        )
    }

    @objc private func transcriptWindowWillClose(_ notification: Notification) {
        Log.info("Transcript window closed")
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: notification.object
        )

        // Only revert to accessory if settings window is also closed.
        if settingsWindow == nil || !(settingsWindow?.isVisible ?? false) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
