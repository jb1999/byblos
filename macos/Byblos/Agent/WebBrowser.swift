import Foundation

/// Simple web browsing capabilities using AppleScript for Safari/Chrome interaction.
struct WebBrowser {

    /// Get the URL of the current browser tab (tries Safari, then Chrome).
    static func getCurrentURL() -> String? {
        // Try Safari first.
        let safari = ScriptRunner.runAppleScript(
            "tell application \"Safari\" to get URL of current tab of front window"
        )
        if safari.success && !safari.output.isEmpty {
            return safari.output
        }

        // Try Chrome.
        let chrome = ScriptRunner.runAppleScript(
            "tell application \"Google Chrome\" to get URL of active tab of front window"
        )
        if chrome.success && !chrome.output.isEmpty {
            return chrome.output
        }

        return nil
    }

    /// Get the title of the current browser tab.
    static func getCurrentPageTitle() -> String? {
        let safari = ScriptRunner.runAppleScript(
            "tell application \"Safari\" to get name of current tab of front window"
        )
        if safari.success && !safari.output.isEmpty {
            return safari.output
        }

        let chrome = ScriptRunner.runAppleScript(
            "tell application \"Google Chrome\" to get title of active tab of front window"
        )
        if chrome.success && !chrome.output.isEmpty {
            return chrome.output
        }

        return nil
    }

    /// Get the visible text content of the current browser page.
    /// Uses AppleScript to get page source then strips HTML tags.
    static func getCurrentPageContent() -> String? {
        // Safari: get the source of the current tab.
        let safari = ScriptRunner.runAppleScript(
            "tell application \"Safari\" to get source of current tab of front window"
        )
        if safari.success && !safari.output.isEmpty {
            return stripHTML(safari.output)
        }

        // Chrome: execute JavaScript to get the body text.
        let chrome = ScriptRunner.runAppleScript(
            "tell application \"Google Chrome\" to execute active tab of front window javascript \"document.body.innerText\""
        )
        if chrome.success && !chrome.output.isEmpty {
            return truncate(chrome.output)
        }

        return nil
    }

    /// Open a URL in the default browser.
    static func openURL(_ urlString: String) -> ScriptResult {
        let escaped = urlString.replacingOccurrences(of: "\"", with: "\\\"")
        return ScriptRunner.runShellCommand("open \"\(escaped)\"")
    }

    /// Search the web using the default browser.
    static func search(_ query: String) -> ScriptResult {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return ScriptResult(success: false, output: "", error: "Could not encode search query")
        }
        let url = "https://www.google.com/search?q=\(encoded)"
        return openURL(url)
    }

    // MARK: - Private

    /// Strip HTML tags and return plain text, truncated to a reasonable length.
    private static func stripHTML(_ html: String) -> String {
        // Remove script and style blocks.
        var cleaned = html
        let blockPatterns = [
            "<script[^>]*>[\\s\\S]*?</script>",
            "<style[^>]*>[\\s\\S]*?</style>",
        ]
        for pattern in blockPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned,
                    range: NSRange(cleaned.startIndex..., in: cleaned),
                    withTemplate: ""
                )
            }
        }

        // Remove remaining HTML tags.
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }

        // Decode common HTML entities.
        cleaned = cleaned
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        // Collapse whitespace.
        let lines = cleaned.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        cleaned = lines.joined(separator: "\n")

        return truncate(cleaned)
    }

    /// Truncate text to keep within reasonable LLM context limits.
    private static func truncate(_ text: String, maxChars: Int = 4000) -> String {
        if text.count > maxChars {
            return String(text.prefix(maxChars)) + "\n...(truncated)"
        }
        return text
    }
}
