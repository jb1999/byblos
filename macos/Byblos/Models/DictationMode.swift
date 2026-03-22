import Foundation

/// A dictation mode that defines how raw transcription text is post-processed.
struct DictationMode: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
    let description: String
    let systemPrompt: String
    let postProcess: @Sendable (String) -> String

    static func == (lhs: DictationMode, rhs: DictationMode) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Built-in Modes

extension DictationMode {

    static let raw = DictationMode(
        id: "raw",
        name: "Raw",
        icon: "waveform",
        description: "No processing. Exact transcription.",
        systemPrompt: "",
        postProcess: { $0 }
    )

    static let clean = DictationMode(
        id: "clean",
        name: "Clean",
        icon: "sparkles",
        description: "Remove filler words, fix punctuation.",
        systemPrompt: "Clean up this transcription. Remove filler words and fix punctuation while preserving the original meaning.",
        postProcess: { text in
            var result = text

            // Remove common filler words (case-insensitive, whole-word boundaries).
            let fillers = [
                "\\bum\\b", "\\buh\\b", "\\blike\\b,?\\s*",
                "\\byou know\\b,?\\s*", "\\bI mean\\b,?\\s*",
                "\\bbasically\\b,?\\s*", "\\bactually\\b,?\\s*",
                "\\bso\\b,?\\s+(?=[a-z])", "\\bright\\b,?\\s*(?=\\w)",
                "\\bkind of\\b\\s*", "\\bsort of\\b\\s*",
            ]

            for pattern in fillers {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    result = regex.stringByReplacingMatches(
                        in: result,
                        range: NSRange(result.startIndex..., in: result),
                        withTemplate: ""
                    )
                }
            }

            // Collapse multiple spaces.
            if let multiSpace = try? NSRegularExpression(pattern: "\\s{2,}") {
                result = multiSpace.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: " "
                )
            }

            // Capitalize first letter of sentences.
            result = capitalizeSentences(result)
            result = result.trimmingCharacters(in: .whitespaces)

            // Ensure trailing period.
            if !result.isEmpty && !result.hasSuffix(".") && !result.hasSuffix("!") && !result.hasSuffix("?") {
                result += "."
            }

            return result
        }
    )

    static let email = DictationMode(
        id: "email",
        name: "Email",
        icon: "envelope",
        description: "Professional tone with greeting and structure.",
        systemPrompt: "Format this transcription as a professional email. Add appropriate greeting and closing if missing. Use paragraph structure.",
        postProcess: { text in
            var result = DictationMode.clean.postProcess(text)

            // Add paragraph breaks at natural boundaries.
            let breakPatterns = [". But ", ". However ", ". Also ", ". Additionally "]
            for pattern in breakPatterns {
                result = result.replacingOccurrences(of: pattern, with: ".\n\n")
            }

            return result
        }
    )

    static let notes = DictationMode(
        id: "notes",
        name: "Notes",
        icon: "note.text",
        description: "Bullet points from stream of consciousness.",
        systemPrompt: "Convert this transcription into concise bullet-point notes. Strip conversational filler and organize into clear points.",
        postProcess: { text in
            let cleaned = DictationMode.clean.postProcess(text)

            // Split on sentence boundaries and convert to bullet points.
            let sentences = cleaned.components(separatedBy: ". ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if sentences.count <= 1 {
                return "- " + cleaned
            }

            return sentences.map { sentence in
                var s = sentence
                // Remove trailing period for bullet format.
                if s.hasSuffix(".") { s = String(s.dropLast()) }
                return "- " + s
            }.joined(separator: "\n")
        }
    )

    static let codeComment = DictationMode(
        id: "codeComment",
        name: "Code Comment",
        icon: "chevron.left.forwardslash.chevron.right",
        description: "Format as concise code comment.",
        systemPrompt: "Format this transcription as a concise code comment. Strip all filler, be direct and technical.",
        postProcess: { text in
            var result = DictationMode.clean.postProcess(text)

            // Make it more concise: remove hedging language.
            let hedges = [
                "I think ", "I believe ", "maybe ", "perhaps ",
                "it seems like ", "it looks like ",
            ]
            for hedge in hedges {
                result = result.replacingOccurrences(of: hedge, with: "", options: .caseInsensitive)
            }

            result = result.trimmingCharacters(in: .whitespaces)
            result = capitalizeSentences(result)

            // Prefix with comment markers.
            let lines = result.components(separatedBy: "\n")
            return lines.map { "// " + $0 }.joined(separator: "\n")
        }
    )

    static let translate = DictationMode(
        id: "translate",
        name: "Translate",
        icon: "globe",
        description: "Transcribe any language, translate to English.",
        systemPrompt: "",
        postProcess: { $0 } // Translation is handled natively by whisper.
    )

    static let agent = DictationMode(
        id: "agent",
        name: "Agent",
        icon: "brain",
        description: "AI agent that can read your screen, search files, and control apps.",
        systemPrompt: "", // Agent mode uses its own prompt system.
        postProcess: { $0 } // Agent mode bypasses normal post-processing.
    )

    /// All built-in modes in display order.
    static let allModes: [DictationMode] = [.raw, .clean, .email, .notes, .codeComment, .translate, .agent]

    /// Look up a mode by its id. Falls back to `.clean` if not found.
    static func mode(forId id: String) -> DictationMode {
        allModes.first(where: { $0.id == id }) ?? .clean
    }

    /// Process text using LLM helper if available, falling back to regex-based postProcess.
    func apply(to text: String) async -> String {
        // Raw mode always passes through.
        if id == "raw" { return text }

        // Try LLM helper process if available and mode has a system prompt.
        let llm = await MainActor.run { LlmService.shared }
        if await llm.isReady, !systemPrompt.isEmpty {
            if let result = await llm.processText(text, systemPrompt: systemPrompt), !result.isEmpty {
                return result
            }
        }

        // Fall back to regex-based processing.
        return postProcess(text)
    }
}

// MARK: - Helpers

private func capitalizeSentences(_ text: String) -> String {
    guard !text.isEmpty else { return text }
    var result = text
    // Capitalize after sentence-ending punctuation.
    if let regex = try? NSRegularExpression(pattern: "([.!?])\\s+([a-z])") {
        let mutableResult = NSMutableString(string: result)
        regex.replaceMatches(
            in: mutableResult,
            range: NSRange(location: 0, length: mutableResult.length),
            withTemplate: "$1 $2"
        )
        // NSRegularExpression template doesn't uppercase, so do it manually.
        let nsRange = NSRange(result.startIndex..., in: result)
        let matches = regex.matches(in: result, range: nsRange)
        for match in matches.reversed() {
            if let range = Range(match.range(at: 2), in: result) {
                result.replaceSubrange(range, with: result[range].uppercased())
            }
        }
    }
    // Capitalize first character.
    if let first = result.first, first.isLowercase {
        result = first.uppercased() + result.dropFirst()
    }
    return result
}
