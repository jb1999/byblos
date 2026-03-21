import AppKit
import ApplicationServices

/// Reads content from the screen using macOS Accessibility APIs.
///
/// Can extract text from the focused app, specific windows, or UI elements
/// without screenshots — using the same APIs that VoiceOver uses.
struct ScreenReader {

    /// Read the text content of the currently focused UI element.
    static func readFocusedElement() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard result == .success, let element = focusedElement else {
            return nil
        }
        return extractText(from: element as! AXUIElement)
    }

    /// Read the title and content of the frontmost window.
    static func readFrontmostWindow() -> WindowContent? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // Get the focused window.
        var windowValue: AnyObject?
        AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue)
        guard let window = windowValue else { return nil }

        let windowElement = window as! AXUIElement

        // Get window title.
        var titleValue: AnyObject?
        AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleValue)
        let title = titleValue as? String ?? ""

        // Get window role.
        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(windowElement, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""

        // Recursively extract all text from the window.
        let text = extractAllText(from: windowElement)

        return WindowContent(
            appName: app.localizedName ?? "Unknown",
            windowTitle: title,
            role: role,
            text: text
        )
    }

    /// Read the selected text in the frontmost app.
    static func readSelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard result == .success, let element = focusedElement else {
            return nil
        }

        var selectedValue: AnyObject?
        AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )
        return selectedValue as? String
    }

    /// Get info about all visible windows.
    static func listWindows() -> [WindowInfo] {
        var result: [WindowInfo] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowsValue: AnyObject?
            AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)

            guard let windows = windowsValue as? [AXUIElement] else { continue }
            for window in windows {
                var titleValue: AnyObject?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
                let title = titleValue as? String ?? ""
                if !title.isEmpty {
                    result.append(WindowInfo(
                        appName: app.localizedName ?? "Unknown",
                        windowTitle: title,
                        bundleId: app.bundleIdentifier ?? ""
                    ))
                }
            }
        }
        return result
    }

    // MARK: - Private

    private static func extractText(from element: AXUIElement) -> String? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        return value as? String
    }

    /// Recursively extract all text content from a UI element tree.
    private static func extractAllText(from element: AXUIElement, depth: Int = 0) -> String {
        guard depth < 10 else { return "" } // Prevent infinite recursion.

        var parts: [String] = []

        // Get this element's value/title.
        if let text = extractText(from: element), !text.isEmpty {
            parts.append(text)
        } else {
            var titleValue: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
            if let title = titleValue as? String, !title.isEmpty {
                parts.append(title)
            }
        }

        // Get children and recurse.
        var childrenValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        if let children = childrenValue as? [AXUIElement] {
            for child in children.prefix(50) { // Limit to prevent explosion.
                let childText = extractAllText(from: child, depth: depth + 1)
                if !childText.isEmpty {
                    parts.append(childText)
                }
            }
        }

        return parts.joined(separator: "\n")
    }
}

// MARK: - Types

struct WindowContent {
    let appName: String
    let windowTitle: String
    let role: String
    let text: String

    var summary: String {
        var result = "App: \(appName)\nWindow: \(windowTitle)\n"
        if !text.isEmpty {
            // Truncate very long content.
            let truncated = text.count > 2000 ? String(text.prefix(2000)) + "..." : text
            result += "Content:\n\(truncated)"
        }
        return result
    }
}

struct WindowInfo {
    let appName: String
    let windowTitle: String
    let bundleId: String
}
