import AppKit
import Foundation

/// The Byblos Agent — a voice-first personal AI that can understand
/// context, search files, read the screen, and control apps.
///
/// Flow: voice → whisper → agent intent detection → action → response
@MainActor
class AgentEngine: ObservableObject {
    static let shared = AgentEngine()

    @Published var lastResponse: String = ""
    @Published var isProcessing: Bool = false

    /// System prompt for intent detection. Kept lean to preserve context window.
    private let systemPrompt = """
    You are Byblos, a Mac AI assistant. Respond ONLY with valid JSON.

    Available actions: READ_SCREEN, SEARCH_FILES (params: query), READ_FILE (params: path), OPEN_APP (params: name), RUN_APPLESCRIPT (params: script), RUN_COMMAND (params: command), CLIPBOARD_GET, CLIPBOARD_SET (params: text), ANSWER

    Format: {"actions": [{"type": "ACTION", "params": {}}], "response": "brief message"}
    Use ANSWER (no actions needed) for general questions. Use the context provided.

    Examples:
    "what's on my screen" → {"actions":[{"type":"READ_SCREEN","params":{}}],"response":"Reading your screen."}
    "find my resume" → {"actions":[{"type":"SEARCH_FILES","params":{"query":"resume"}}],"response":"Searching..."}
    "open safari" → {"actions":[{"type":"OPEN_APP","params":{"name":"Safari"}}],"response":"Opening Safari."}
    "what time is it" → {"actions":[{"type":"ANSWER","params":{}}],"response":"It's [use the time from context]."}
    "what's on my clipboard" → {"actions":[{"type":"CLIPBOARD_GET","params":{}}],"response":"Checking clipboard."}
    """

    /// Process a voice command through the agent.
    func process(_ input: String) async -> String {
        isProcessing = true
        defer { isProcessing = false }

        Log.info("[Agent] Processing: \(input)")

        // Gather context.
        var contextParts: [String] = []

        // Current app context.
        if let app = NSWorkspace.shared.frontmostApplication?.localizedName {
            contextParts.append("Current app: \(app)")
        }

        // Clipboard content (brief).
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        if !clipboard.isEmpty {
            let brief = clipboard.count > 200 ? String(clipboard.prefix(200)) + "..." : clipboard
            contextParts.append("Clipboard: \(brief)")
        }

        // Time context.
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        contextParts.append("Current time: \(formatter.string(from: Date()))")

        let context = contextParts.joined(separator: "\n")
        let fullPrompt = "\(systemPrompt)\n\nCurrent context:\n\(context)\n\nUser said: \(input)"

        // Send to LLM.
        guard LlmService.shared.isReady else {
            Log.info("[Agent] LLM not ready")
            return "Agent mode requires the LLM model. It's either loading or not installed."
        }

        guard let llmResponse = await LlmService.shared.processText(input, systemPrompt: fullPrompt) else {
            return "I couldn't process that. The LLM helper may be busy."
        }

        Log.info("[Agent] LLM response: \(llmResponse)")

        // Parse the response.
        let (actions, response) = parseResponse(llmResponse)

        // Execute actions and gather results.
        var actionResults: [String] = []
        for action in actions {
            let result = await executeAction(action)
            actionResults.append(result)
        }

        // If we got action results, send them back to the LLM for a final response.
        let nonEmptyResults = actionResults.filter { !$0.isEmpty }
        if !nonEmptyResults.isEmpty {
            let resultsContext = nonEmptyResults.enumerated()
                .map { "Result \($0 + 1):\n\($1)" }
                .joined(separator: "\n\n")

            let summarizePrompt = "You are a helpful assistant. Summarize the following information concisely for the user. Just give the answer, no preamble."
            let summarizeText = "User asked: \(input)\n\nHere is what I found:\n\(resultsContext)"

            // Small delay to ensure LLM helper is ready for next request.
            try? await Task.sleep(nanoseconds: 500_000_000)

            if let finalResponse = await LlmService.shared.processText(summarizeText, systemPrompt: summarizePrompt),
               !finalResponse.isEmpty {
                lastResponse = finalResponse
                return finalResponse
            }

            // If LLM follow-up fails, return the raw results.
            lastResponse = resultsContext
            return resultsContext
        }

        lastResponse = response
        return response
    }

    // MARK: - Response Parsing

    private struct AgentAction {
        let type: String
        let params: [String: String]
    }

    private func parseResponse(_ raw: String) -> ([AgentAction], String) {
        // Try to parse as JSON.
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Not JSON — treat the whole thing as a plain text response.
            return ([], raw)
        }

        var actions: [AgentAction] = []
        if let actionsArray = json["actions"] as? [[String: Any]] {
            for actionDict in actionsArray {
                if let type = actionDict["type"] as? String {
                    var params: [String: String] = [:]
                    if let paramsDict = actionDict["params"] as? [String: Any] {
                        for (key, value) in paramsDict {
                            params[key] = "\(value)"
                        }
                    }
                    actions.append(AgentAction(type: type, params: params))
                }
            }
        }

        let response = json["response"] as? String ?? raw
        return (actions, response)
    }

    // MARK: - Action Execution

    private func executeAction(_ action: AgentAction) async -> String {
        Log.info("[Agent] Executing: \(action.type) \(action.params)")

        switch action.type {
        case "READ_SCREEN":
            // Try the frontmost window first.
            if let content = ScreenReader.readFrontmostWindow(), !content.text.isEmpty {
                Log.info("[Agent] Screen read: \(content.appName) - \(content.windowTitle) (\(content.text.count) chars)")
                return content.summary
            }
            // If frontmost is Byblos itself, try reading selected text or list windows.
            if let selected = ScreenReader.readSelectedText(), !selected.isEmpty {
                Log.info("[Agent] Read selected text: \(selected.count) chars")
                return "Selected text: \(selected)"
            }
            let windows = ScreenReader.listWindows()
            if !windows.isEmpty {
                let listing = windows.prefix(10).map { "\($0.appName): \($0.windowTitle)" }.joined(separator: "\n")
                Log.info("[Agent] Listed \(windows.count) windows")
                return "Open windows:\n\(listing)"
            }
            return "Could not read screen content. Make sure Accessibility permission is granted."

        case "SEARCH_FILES":
            let query = action.params["query"] ?? ""
            let results = FileSearch.search(query: query)
            if results.isEmpty {
                return "No files found for '\(query)'."
            }
            return results.map { $0.description }.joined(separator: "\n")

        case "READ_FILE":
            let path = action.params["path"] ?? ""
            if let content = FileSearch.readFile(at: path) {
                return content
            }
            return "Could not read file at \(path)."

        case "RUN_APPLESCRIPT":
            let script = action.params["script"] ?? ""
            let result = ScriptRunner.runAppleScript(script)
            return result.description

        case "RUN_COMMAND":
            let command = action.params["command"] ?? ""
            let result = ScriptRunner.runShellCommand(command)
            return result.description

        case "CLIPBOARD_GET":
            return ScriptRunner.getClipboard()

        case "CLIPBOARD_SET":
            let text = action.params["text"] ?? ""
            let result = ScriptRunner.setClipboard(text)
            return result.description

        case "OPEN_APP":
            let name = action.params["name"] ?? ""
            let result = ScriptRunner.openApp(name)
            return result.description

        case "NOTIFY":
            let title = action.params["title"] ?? "Byblos"
            let message = action.params["message"] ?? ""
            let result = ScriptRunner.showNotification(title: title, message: message)
            return result.description

        case "ANSWER":
            return "" // No action needed, just use the response text.

        default:
            return "Unknown action: \(action.type)"
        }
    }
}
