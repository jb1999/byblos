import AppKit
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
        Log.info("Loading model from: \(modelPath)")
        engine = ByblosEngine(modelPath: modelPath)
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon()
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let recordTitle = isRecording ? "⏹ Stop Recording" : "⏺ Start Recording"
        let recordItem = NSMenuItem(title: recordTitle, action: #selector(menuToggleRecording), keyEquivalent: "")
        recordItem.target = self
        recordItem.isEnabled = engine != nil
        menu.addItem(recordItem)

        menu.addItem(NSMenuItem.separator())

        let statusText: String
        if isRecording {
            statusText = "Recording..."
        } else if engine != nil {
            statusText = "Ready — Whisper Base"
        } else {
            statusText = "No model loaded"
        }
        let statusInfo = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusInfo.isEnabled = false
        menu.addItem(statusInfo)

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
        }
    }

    private func stopRecording() {
        guard isRecording else { return }

        isRecording = false
        updateMenuBarIcon()
        rebuildMenu()
        hideOverlay()
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

        // Run transcription on a background thread to keep UI responsive.
        let eng = engine
        let accessibility = accessibilityService!
        DispatchQueue.global(qos: .userInitiated).async {
            let text = eng?.stopAndTranscribe()

            DispatchQueue.main.async { [weak self] in
                // Restore menu bar icon.
                self?.updateMenuBarIcon()

                guard let text, !text.isEmpty else {
                    Log.info("No transcription result (empty or nil)")
                    return
                }

                Log.info("Transcribed: \(text)")
                accessibility.typeText(text)
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

        hotkeyService = HotkeyService()
        hotkeyService.onHotkeyDown = { [weak self] in
            DispatchQueue.main.async { self?.startRecording() }
        }
        hotkeyService.onHotkeyUp = { [weak self] in
            DispatchQueue.main.async { self?.stopRecording() }
        }
        hotkeyService.register()
        Log.info("Hotkey registered (hold Option to record)")
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
