import Foundation

/// Executes AppleScript and shell commands for system automation.
struct ScriptRunner {

    /// Run an AppleScript and return the result.
    static func runAppleScript(_ script: String) -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ScriptResult(success: false, output: "", error: error.localizedDescription)
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return ScriptResult(
            success: process.terminationStatus == 0,
            output: output,
            error: errorStr.isEmpty ? nil : errorStr
        )
    }

    /// Run a shell command and return the result.
    /// Commands are sandboxed — no sudo, no rm -rf, no destructive operations.
    static func runShellCommand(_ command: String) -> ScriptResult {
        // Safety check — block dangerous commands.
        let blocked = ["sudo", "rm -rf", "mkfs", "dd if=", ":(){ :", "shutdown", "reboot"]
        for pattern in blocked {
            if command.contains(pattern) {
                return ScriptResult(success: false, output: "", error: "Blocked: potentially dangerous command")
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Timeout after 30 seconds.
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + 30)
        timer.setEventHandler { process.terminate() }
        timer.resume()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            timer.cancel()
            return ScriptResult(success: false, output: "", error: error.localizedDescription)
        }

        timer.cancel()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Truncate very long output.
        let truncatedOutput = output.count > 4000 ? String(output.prefix(4000)) + "\n...(truncated)" : output

        return ScriptResult(
            success: process.terminationStatus == 0,
            output: truncatedOutput,
            error: errorStr.isEmpty ? nil : errorStr
        )
    }

    /// Common AppleScript helpers.

    static func openApp(_ name: String) -> ScriptResult {
        runAppleScript("tell application \"\(name)\" to activate")
    }

    static func getClipboard() -> String {
        runAppleScript("the clipboard").output
    }

    static func setClipboard(_ text: String) -> ScriptResult {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        return runAppleScript("set the clipboard to \"\(escaped)\"")
    }

    static func getBrowserURL() -> String? {
        // Try Safari first, then Chrome.
        let safari = runAppleScript("tell application \"Safari\" to get URL of current tab of front window")
        if safari.success && !safari.output.isEmpty { return safari.output }

        let chrome = runAppleScript("tell application \"Google Chrome\" to get URL of active tab of front window")
        if chrome.success && !chrome.output.isEmpty { return chrome.output }

        return nil
    }

    /// List all available Shortcuts on the system.
    static func listShortcuts() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.error("[ScriptRunner] shortcuts list failed: \(error)")
            return []
        }

        guard process.terminationStatus == 0 else { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Run a Shortcut by name with optional input text.
    static func runShortcut(_ name: String, input: String? = nil) -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        var args = ["run", name]
        if let input {
            args += ["-i", input]
        }
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Timeout after 30 seconds.
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + 30)
        timer.setEventHandler { process.terminate() }
        timer.resume()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            timer.cancel()
            return ScriptResult(success: false, output: "", error: error.localizedDescription)
        }

        timer.cancel()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return ScriptResult(
            success: process.terminationStatus == 0,
            output: output,
            error: errorStr.isEmpty ? nil : errorStr
        )
    }

    /// Get today's calendar events from Calendar.app via AppleScript.
    static func getTodayCalendarEvents() -> ScriptResult {
        let script = """
        set today to current date
        set time of today to 0
        set tomorrow to today + (1 * days)
        set output to ""
        tell application "Calendar"
            repeat with cal in calendars
                set evts to (every event of cal whose start date >= today and start date < tomorrow)
                repeat with evt in evts
                    set evtStart to start date of evt
                    set evtSummary to summary of evt
                    set timeStr to time string of evtStart
                    set output to output & timeStr & " - " & evtSummary & linefeed
                end repeat
            end repeat
        end tell
        if output is "" then
            return "No calendar events today."
        end if
        return output
        """
        return runAppleScript(script)
    }

    /// Get today's reminders from Reminders.app via AppleScript.
    static func getTodayReminders() -> ScriptResult {
        let script = """
        set today to current date
        set time of today to 0
        set tomorrow to today + (1 * days)
        set output to ""
        tell application "Reminders"
            set allReminders to (every reminder whose completed is false)
            repeat with r in allReminders
                try
                    set dueDate to due date of r
                    if dueDate >= today and dueDate < tomorrow then
                        set output to output & name of r & " (due: " & time string of dueDate & ")" & linefeed
                    end if
                end try
            end repeat
        end tell
        if output is "" then
            return "No reminders due today."
        end if
        return output
        """
        return runAppleScript(script)
    }

    static func showNotification(title: String, message: String) -> ScriptResult {
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        let titleEscaped = title.replacingOccurrences(of: "\"", with: "\\\"")
        return runAppleScript(
            "display notification \"\(escaped)\" with title \"\(titleEscaped)\""
        )
    }
}

struct ScriptResult {
    let success: Bool
    let output: String
    let error: String?

    var description: String {
        if success {
            return output.isEmpty ? "(success, no output)" : output
        } else {
            return "Error: \(error ?? "unknown")"
        }
    }
}
