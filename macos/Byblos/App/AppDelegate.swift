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
    private var onboardingController: OnboardingWindowController?
    /// Tracks the last partial text for auto-stop silence detection.
    private var previousPartialText: String = ""
    /// Number of consecutive polling intervals where partial text didn't change.
    private var unchangedPartialCount: Int = 0
    /// Whether speech has been detected (partial text appeared at least once).
    private var speechDetected: Bool = false
    /// Last typed text for undo support.
    private var lastTypedText: String = ""
    /// Character count of last typed text for undo support.
    private var lastTypedLength: Int = 0

    @AppStorage("autoStopEnabled") private var autoStopEnabled = true
    @AppStorage("autoStopDelay") private var autoStopDelay: Double = 3.0
    @AppStorage("appAwareMode") private var appAwareMode = true
    /// Tracks the effective mode for the current recording session (may differ from user selection if app-aware).
    private var effectiveModeId: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Byblos starting up...")

        // Observe notifications.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleRecordingNotification),
            name: Notification.Name("ByblosToggleRecording"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReloadEngineNotification),
            name: Notification.Name("ByblosReloadEngine"),
            object: nil
        )

        // Show onboarding FIRST on fresh installs (before going accessory).
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            showOnboarding()
            // After onboarding completes, setupEngine is called from the completion handler.
            setupMenuBar()
            return
        }

        // Normal launch.
        setupEngine()
        setupMenuBar()
        setupHotkey()
        setupAccessibility()
        applyAppMode()

        // Start scheduled tasks and load skills.
        TaskScheduler.shared.start()
        SkillsManager.shared.loadSkills()

        Log.info("Byblos ready. Engine loaded: \(self.engine != nil)")

        // Validate license on launch (once/day, non-blocking).
        Task { await LicenseService.shared.validateCached() }
    }

    @objc private func handleToggleRecordingNotification() {
        toggleRecording()
    }

    @objc private func handleReloadEngineNotification() {
        guard !isRecording else {
            Log.info("Cannot reload engine while recording")
            return
        }
        Log.info("Reloading engine with new model selection...")
        setupEngine()
    }

    func showOnboarding() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if onboardingController == nil {
            onboardingController = OnboardingWindowController()
        }
        onboardingController?.showOnboarding { [weak self] in
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            Log.info("Onboarding completed")
            self?.onboardingController?.close()
            self?.onboardingController = nil

            // Reload engine in case a model was downloaded during onboarding.
            self?.setupEngine()
            self?.setupHotkey()
            self?.setupAccessibility()
            self?.applyAppMode()
        }
    }

    /// Apply dock or menu-bar-only mode based on user preference.
    private func applyAppMode() {
        let showInDock = UserDefaults.standard.bool(forKey: "showInDock")
        if showInDock {
            NSApp.setActivationPolicy(.regular)
            Log.info("App mode: Dock")
        } else {
            NSApp.setActivationPolicy(.accessory)
            Log.info("App mode: Menu bar only")
        }
    }

    // MARK: - Engine

    private func setupEngine() {
        // NOTE: LLM (llama.cpp) and whisper.cpp both use ggml-metal and cannot
        // coexist in the same process yet — Metal backend can only init once.
        // LLM will be moved to a helper process in a future update.
        // For now, dictation modes use regex-based text processing.

        guard let modelPath = ByblosEngine.defaultModelPath() else {
            Log.error("No model found. Run: ./scripts/download-model.sh whisper-base-en")
            return
        }
        let language = UserDefaults.standard.string(forKey: "language") ?? "en"
        Log.info("Loading model from: \(modelPath), language: \(language)")
        engine = ByblosEngine(modelPath: modelPath, language: language)

        // Start the LLM helper process (separate process to avoid ggml-metal conflicts).
        if LlmService.shared.isAvailable {
            LlmService.shared.start()
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon()

        // Left-click = toggle recording, right-click = show menu.
        if let button = statusItem.button {
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
        }
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            // Show context menu on right-click.
            let menu = buildMenu()
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            // Left-click: toggle recording directly.
            toggleRecording()
        }
    }

    private var currentModelDisplayName: String {
        let selectedModel = UserDefaults.standard.string(forKey: "selectedModel") ?? "whisper-base"
        let names: [String: String] = [
            "whisper-tiny": "Whisper Tiny",
            "whisper-base": "Whisper Base",
            "whisper-small": "Whisper Small",
            "whisper-medium": "Whisper Medium",
            "whisper-large-v3": "Whisper Large v3",
            "whisper-turbo": "Whisper Large v3 Turbo",
            "distil-whisper-large-v3": "Distil-Whisper Large v3",
        ]
        return names[selectedModel] ?? selectedModel
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let recordTitle = isRecording ? "Stop Recording" : "Start Recording"
        let recordItem = NSMenuItem(title: recordTitle, action: #selector(menuToggleRecording), keyEquivalent: "")
        recordItem.target = self
        recordItem.isEnabled = engine != nil
        menu.addItem(recordItem)

        let undoItem = NSMenuItem(title: "Undo Last (\u{2318}Z)", action: #selector(menuUndoLast), keyEquivalent: "")
        undoItem.target = self
        undoItem.isEnabled = lastTypedLength > 0
        menu.addItem(undoItem)

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

        // Auto-stop toggle.
        let autoStopItem = NSMenuItem(
            title: "Auto-stop on Silence",
            action: #selector(menuToggleAutoStop),
            keyEquivalent: ""
        )
        autoStopItem.target = self
        autoStopItem.state = autoStopEnabled ? .on : .off
        menu.addItem(autoStopItem)

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

        return menu
    }

    @objc private func menuToggleAutoStop() {
        autoStopEnabled.toggle()
        Log.info("Auto-stop on silence: \(autoStopEnabled)")
    }

    @objc private func menuToggleRecording() {
        Log.info("Menu toggle recording clicked. isRecording=\(self.isRecording)")
        toggleRecording()
    }
    @objc private func menuUndoLast() { undoLastTranscription() }
    @objc private func menuOpenSettings() { openSettings() }
    @objc private func menuShowTranscripts() { openTranscriptWindow() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuSelectMode(_ sender: NSMenuItem) {
        guard let modeId = sender.representedObject as? String else { return }
        UserDefaults.standard.set(modeId, forKey: "dictationMode")
        Log.info("Dictation mode changed to: \(modeId)")
    }

    /// Suggest a dictation mode based on the focused app's bundle ID.
    private func suggestedModeForApp(_ bundleId: String) -> String? {
        switch bundleId {
        case "com.apple.mail", "com.google.Gmail":
            return "email"
        case "com.tinyspeck.slackmacgap", "com.discord.Discord", "com.apple.MobileSMS":
            return "clean"
        case "com.microsoft.VSCode", "com.apple.dt.Xcode":
            return "codeComment"
        case "com.apple.Notes", "md.obsidian":
            return "notes"
        default:
            // Match Cursor editor variants (dev.cursor.*).
            if bundleId.hasPrefix("dev.cursor.") {
                return "codeComment"
            }
            return nil
        }
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

        // Determine effective dictation mode for this session.
        let userModeId = UserDefaults.standard.string(forKey: "dictationMode") ?? "clean"
        if appAwareMode, let bundleId = previousApp?.bundleIdentifier,
           let suggested = suggestedModeForApp(bundleId) {
            effectiveModeId = suggested
            Log.info("App-aware mode: auto-selected '\(suggested)' for \(bundleId)")
        } else {
            effectiveModeId = userModeId
        }

        // Configure translate mode on the engine.
        let isTranslate = effectiveModeId == "translate"
        engine?.setTranslate(isTranslate)

        isRecording = true
        recordingStartTime = CFAbsoluteTimeGetCurrent()
        speechDetected = false
        previousPartialText = ""
        unchangedPartialCount = 0
        updateMenuBarIcon()
        TranscriptRecordingState.shared.isRecording = true
        TranscriptRecordingState.shared.partialText = ""
        showOverlay()

        if engine?.startRecording() != true {
            Log.error("Failed to start recording from engine")
            isRecording = false
            updateMenuBarIcon()
            TranscriptRecordingState.shared.isRecording = false
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
                    TranscriptRecordingState.shared.partialText = partial
                    Log.info("Partial: \(partial)")

                    // Auto-stop silence detection: if partial text hasn't changed,
                    // speech may have ended.
                    if self.autoStopEnabled && self.isRecording {
                        self.checkAutoStop(currentPartial: partial)
                    }
                }
            }
        }
    }

    /// Checks if recording should auto-stop due to silence (no new transcription).
    private func checkAutoStop(currentPartial: String) {
        let elapsed = CFAbsoluteTimeGetCurrent() - recordingStartTime

        // Mark that speech was detected once we get any partial text.
        if !currentPartial.isEmpty {
            speechDetected = true
        }

        // Don't auto-stop if we haven't recorded long enough or no speech detected.
        guard speechDetected, elapsed >= 1.5 else {
            previousPartialText = currentPartial
            unchangedPartialCount = 0
            return
        }

        if currentPartial == previousPartialText {
            unchangedPartialCount += 1
            // Each poll is 2 seconds. Auto-stop after enough unchanged polls.
            // autoStopDelay is in seconds; convert to number of 2s polling intervals.
            let requiredCount = max(1, Int(ceil(autoStopDelay / 2.0)))
            if unchangedPartialCount >= requiredCount {
                Log.info("Auto-stopping: no new speech for \(unchangedPartialCount * 2)s")
                overlayWindow?.updatePartialText(currentPartial + "\n[Auto-stopping...]")
                // Brief delay so user sees the indicator, then stop.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.isRecording else { return }
                    self.stopRecording()
                }
            }
        } else {
            unchangedPartialCount = 0
        }
        previousPartialText = currentPartial
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
        TranscriptRecordingState.shared.isRecording = false
        TranscriptRecordingState.shared.partialText = ""
        overlayWindow?.setProcessing(true)
        Log.info("Recording stopped, transcribing...")

        // Show a processing indicator.
        statusItem.button?.image = NSImage(
            systemSymbolName: "ellipsis.circle",
            accessibilityDescription: "Byblos (Transcribing)"
        )

        let targetApp = previousApp

        // Determine the output mode from settings.
        let outputModeSetting = UserDefaults.standard.string(forKey: "outputMode") ?? "type"
        let outputMode: AccessibilityService.OutputMode = outputModeSetting == "clipboard"
            ? .clipboard
            : .accessibilityFirst

        // Get dictation mode for post-processing (use effective mode from app-aware selection).
        let dictationModeId = effectiveModeId ?? (UserDefaults.standard.string(forKey: "dictationMode") ?? "clean")
        let dictationMode = DictationMode.mode(forId: dictationModeId)
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

            // Apply regex-based post-processing synchronously.
            // LLM processing happens asynchronously after typing.
            let processedText = rawText.map { dictationMode.postProcess($0) }

            DispatchQueue.main.async { [weak self] in
                self?.hideOverlay()
                self?.updateMenuBarIcon()

                self?.lastTranscriptionTime = elapsed

                guard let rawText, !rawText.isEmpty else {
                    Log.info("No transcription result (empty or nil)")
                    return
                }

                // Apply vocabulary replacement after dictation post-processing.
                let postProcessed = processedText ?? rawText
                let finalText = VocabularyStore.shared.apply(to: postProcessed)
                Log.info("Transcribed (\(String(format: "%.1f", elapsed))s): \(finalText)")

                // Check for undo voice commands.
                if self?.isUndoCommand(finalText) == true {
                    self?.undoLastTranscription()
                    return
                }

                // Agent mode: route to AgentEngine instead of typing.
                if dictationModeId == "agent" {
                    Log.info("[Agent] Routing to agent: \(rawText)")
                    self?.overlayWindow?.updatePartialText("Thinking...")
                    self?.overlayWindow?.show()
                    Task {
                        let response = await AgentEngine.shared.process(rawText)
                        Log.info("[Agent] Response: \(response)")

                        // Show response in overlay briefly, then copy to clipboard.
                        self?.overlayWindow?.updatePartialText(response)

                        // Save to transcript store.
                        let entry = TranscriptEntry(
                            text: "Q: \(rawText)\nA: \(response)",
                            rawText: rawText,
                            mode: "agent",
                            duration: recordingDuration,
                            language: language,
                            appContext: appContext
                        )
                        TranscriptStore.shared.addEntry(entry)

                        // Also type the response if it's short enough.
                        if response.count < 500 {
                            accessibility.typeText(response, mode: outputMode)
                        } else {
                            // For long responses, copy to clipboard and notify.
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(response, forType: .string)
                            _ = ScriptRunner.showNotification(
                                title: "Byblos Agent",
                                message: "Response copied to clipboard (\(response.count) chars)"
                            )
                        }

                        // Hide overlay after a delay.
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        self?.hideOverlay()
                    }
                    return
                }

                // Normal dictation mode: type text and save.
                let entry = TranscriptEntry(
                    text: finalText,
                    rawText: rawText,
                    mode: dictationModeId,
                    duration: recordingDuration,
                    language: language,
                    appContext: appContext
                )
                TranscriptStore.shared.addEntry(entry)

                // Re-activate the target app RIGHT before typing.
                if let app = targetApp {
                    Log.info("Re-activating: \(app.localizedName ?? "unknown")")
                    app.activate()
                    // Give the app a moment to come to foreground.
                    usleep(200_000) // 200ms
                }

                accessibility.typeText(finalText, mode: outputMode)

                // Track for undo support.
                self?.lastTypedText = finalText
                self?.lastTypedLength = finalText.count


                // If LLM is available, re-process the text asynchronously.
                if LlmService.shared.isReady && !dictationMode.systemPrompt.isEmpty {
                    let entryId = entry.id
                    Task {
                        if let improved = await LlmService.shared.processText(rawText, systemPrompt: dictationMode.systemPrompt) {
                            Log.info("LLM improved: \(improved)")
                            await MainActor.run {
                                TranscriptStore.shared.updateText(for: entryId, newText: improved)
                            }
                        }
                    }
                }
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

    // MARK: - Undo Last Transcription

    func undoLastTranscription() {
        guard lastTypedLength > 0 else {
            Log.info("Undo: nothing to undo")
            return
        }
        Log.info("Undo: deleting \(lastTypedLength) characters")

        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<lastTypedLength {
            // Virtual key 0x33 = Delete (backspace).
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true) {
                keyDown.post(tap: .cgAnnotatedSessionEventTap)
            }
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false) {
                keyUp.post(tap: .cgAnnotatedSessionEventTap)
            }
        }

        Log.info("Undo: deleted '\(lastTypedText)'")
        lastTypedText = ""
        lastTypedLength = 0
    }

    /// Check if transcription text is an undo command.
    private func isUndoCommand(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower.hasPrefix("scratch that") || lower.hasPrefix("undo that") || lower.hasPrefix("delete that")
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

        // Create our own settings window — avoids the system menu bar.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Byblos Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )

        settingsWindow = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Log.info("Settings window opened")
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
