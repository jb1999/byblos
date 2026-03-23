import AppKit
import ApplicationServices

/// Types text into the frontmost application using macOS APIs.
///
/// Strategy order:
/// 1. AXUIElement (cleanest, requires Accessibility)
/// 2. Clipboard + Cmd+V via CGEvent (requires Accessibility for CGEvent)
/// 3. Clipboard only (always works — user pastes manually)
class AccessibilityService {

    /// Check if we have accessibility permission (never prompts).
    static var hasPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Type text into the currently focused text field.
    func typeText(_ text: String, mode: OutputMode = .accessibilityFirst) {
        Log.info("[Accessibility] Typing \(text.count) chars, mode=\(mode), trusted=\(AXIsProcessTrusted())")

        switch mode {
        case .accessibilityFirst:
            // Clipboard paste is the most universal method — works in Terminal,
            // VS Code, Cursor, browsers, Electron apps, and native apps.
            // AXUIElement only works with native Cocoa text fields.
            pasteViaCGEvent(text)
        case .keyboardEvents:
            if AXIsProcessTrusted() {
                typeViaKeyboardEvents(text)
            } else {
                pasteViaCGEvent(text)
            }
        case .clipboard:
            setClipboard(text)
        }
    }

    // MARK: - Strategy 1: AXUIElement

    private func typeViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success, let element = focusedElement else {
            return false
        }

        var currentValue: AnyObject?
        AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXValueAttribute as CFString,
            &currentValue
        )

        let newValue: String
        if let current = currentValue as? String {
            newValue = current + text
        } else {
            newValue = text
        }

        let setResult = AXUIElementSetAttributeValue(
            element as! AXUIElement,
            kAXValueAttribute as CFString,
            newValue as CFTypeRef
        )

        return setResult == .success
    }

    // MARK: - Strategy 2: Clipboard + CGEvent Cmd+V

    private func pasteViaCGEvent(_ text: String) {
        setClipboard(text)

        // Small delay to ensure clipboard is set before paste event.
        usleep(50_000) // 50ms

        // Synthesize Cmd+V using CGEvent with nil source (more compatible).
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)

        Log.info("[Accessibility] Sent Cmd+V via CGEvent (text on clipboard)")
    }

    // MARK: - Strategy 3: Keyboard Events (character by character)

    private func typeViaKeyboardEvents(_ text: String) {
        for char in text {
            let str = String(char)
            let utf16 = Array(str.utf16)

            if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                keyDown.post(tap: .cghidEventTap)
            }

            if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                keyUp.post(tap: .cghidEventTap)
            }

            // Small delay between keystrokes to prevent drops.
            usleep(1_000) // 1ms
        }
    }

    // MARK: - Clipboard

    private func setClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Log.info("[Accessibility] Clipboard set (\(text.count) chars)")
    }

    enum OutputMode: CustomStringConvertible {
        case accessibilityFirst
        case keyboardEvents
        case clipboard

        var description: String {
            switch self {
            case .accessibilityFirst: "accessibilityFirst"
            case .keyboardEvents: "keyboardEvents"
            case .clipboard: "clipboard"
            }
        }
    }
}
