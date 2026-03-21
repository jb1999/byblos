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
