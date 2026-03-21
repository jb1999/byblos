import AppKit
import ApplicationServices

/// Types text into the frontmost application using macOS Accessibility API.
///
/// This is how SuperWhisper, Wispr Flow, and macOS Dictation all work.
/// Requires the user to grant Accessibility permission.
class AccessibilityService {

    /// Check if we have accessibility permission (never prompts).
    static var hasPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Type text into the currently focused text field.
    ///
    /// Strategy:
    /// 1. Try AXUIElement API to set value directly (cleanest).
    /// 2. Fall back to CGEvent keyboard synthesis (works more broadly).
    /// 3. Last resort: clipboard paste (works everywhere but clobbers clipboard).
    func typeText(_ text: String, mode: OutputMode = .accessibilityFirst) {
        switch mode {
        case .accessibilityFirst:
            if !typeViaAccessibility(text) {
                typeViaKeyboardEvents(text)
            }
        case .keyboardEvents:
            typeViaKeyboardEvents(text)
        case .clipboard:
            pasteViaClipboard(text)
        }
    }

    // MARK: - Strategies

    /// Insert text via AXUIElement (preferred — doesn't trigger keyboard shortcuts).
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

        // Get current value and selection to insert at cursor.
        var currentValue: AnyObject?
        AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXValueAttribute as CFString,
            &currentValue
        )

        // Try setting value with appended text.
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

    /// Synthesize keyboard events to type each character.
    private func typeViaKeyboardEvents(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)

        for char in text {
            let str = String(char)
            let utf16 = Array(str.utf16)

            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                keyDown.post(tap: .cgAnnotatedSessionEventTap)
            }

            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                keyUp.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

    /// Paste via clipboard (last resort).
    private func pasteViaClipboard(_ text: String) {
        // Save current clipboard.
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        // Set text and paste.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Synthesize Cmd+V.
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // 'v'
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)

        // Restore clipboard after a brief delay.
        if let previous = previousContents {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    enum OutputMode {
        case accessibilityFirst
        case keyboardEvents
        case clipboard
    }
}
