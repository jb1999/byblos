import Foundation

/// Manages the byblos-llm helper process for local LLM text processing.
///
/// Communication is via JSON lines over stdin/stdout pipes.
/// The helper runs in a separate process to avoid ggml-metal conflicts with whisper.
@MainActor
class LlmService: ObservableObject {
    static let shared = LlmService()

    @Published var isReady = false
    @Published var isLoading = false

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var readBuffer = ""

    /// Path to the byblos-llm helper binary.
    private var helperPath: String? {
        // Look next to the main app binary first.
        if let bundlePath = Bundle.main.executablePath {
            let dir = (bundlePath as NSString).deletingLastPathComponent
            let candidate = (dir as NSString).appendingPathComponent("byblos-llm")
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        // Fall back to the build directory (development).
        let devPath = "/Volumes/userspace/jbilla/byblos.im/target/release/byblos-llm"
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }
        return nil
    }

    /// Find the best available LLM model.
    private var modelPath: String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Byblos/llm-models")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return nil
        }
        // Prefer larger/better models first.
        let preferred = ["qwen3-8b", "deepseek-r1", "eurollm", "mistral-7b", "qwen3.5-4b", "qwen2.5-7b", "llama-3.2-3b", "phi-3.5", "phi-4", "qwen", "tinyllama"]
        for prefix in preferred {
            if let match = files.first(where: { $0.lowercased().contains(prefix) && $0.hasSuffix(".gguf") }) {
                return dir.appendingPathComponent(match).path
            }
        }
        // Any GGUF file.
        if let gguf = files.first(where: { $0.hasSuffix(".gguf") }) {
            return dir.appendingPathComponent(gguf).path
        }
        return nil
    }

    var isAvailable: Bool {
        helperPath != nil && modelPath != nil
    }

    /// Start the LLM helper process.
    func start() {
        guard !isLoading, !isReady else { return }
        guard let helper = helperPath, let model = modelPath else {
            Log.info("[LLM] No helper binary or model found")
            return
        }

        isLoading = true
        Log.info("[LLM] Starting helper: \(helper) with model: \(model)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: helper)
        proc.arguments = [model]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        // Read stderr for debug logging.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Log.info("[LLM stderr] \(str.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        // Read stdout for JSON responses.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.handleOutput(str)
            }
        }

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                Log.info("[LLM] Helper process terminated")
                self?.isReady = false
                self?.isLoading = false
                self?.process = nil
            }
        }

        do {
            try proc.run()
            process = proc
            stdinPipe = stdin
            stdoutPipe = stdout
            Log.info("[LLM] Helper process started (PID: \(proc.processIdentifier))")
        } catch {
            Log.error("[LLM] Failed to start helper: \(error)")
            isLoading = false
        }
    }

    /// Stop the LLM helper process.
    func stop() {
        sendRequest(LlmRequest(method: "quit"))
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.process?.terminate()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        isReady = false
    }

    /// Process text through the LLM with a system prompt.
    /// Returns the processed text, or nil if LLM is not available.
    func processText(_ text: String, systemPrompt: String) async -> String? {
        guard isReady else {
            Log.info("[LLM] Not ready, returning nil")
            return nil
        }

        // Wait if a previous request is still pending.
        while pendingContinuation != nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation
            Log.info("[LLM] Sending request: text=\(text.prefix(80))... prompt=\(systemPrompt.prefix(80))...")
            sendRequest(LlmRequest(method: "process", text: text, system_prompt: systemPrompt))

            // Timeout after 30 seconds.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                if let cont = self?.pendingContinuation {
                    Log.info("[LLM] Request timed out")
                    self?.pendingContinuation = nil
                    cont.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Private

    private var pendingContinuation: CheckedContinuation<String?, Never>?

    private struct LlmRequest: Encodable {
        let method: String
        var text: String = ""
        var system_prompt: String = ""
    }

    private struct LlmResponse: Decodable {
        let ok: Bool
        let result: String?
        let error: String?
        let duration_ms: UInt64?
    }

    private func sendRequest(_ request: LlmRequest) {
        guard let pipe = stdinPipe else { return }
        guard let data = try? JSONEncoder().encode(request),
              let str = String(data: data, encoding: .utf8)
        else { return }

        let line = str + "\n"
        pipe.fileHandleForWriting.write(line.data(using: .utf8)!)
    }

    private func handleOutput(_ str: String) {
        readBuffer += str

        // Process complete JSON lines.
        while let newlineRange = readBuffer.range(of: "\n") {
            let line = String(readBuffer[readBuffer.startIndex..<newlineRange.lowerBound])
            readBuffer = String(readBuffer[newlineRange.upperBound...])

            guard !line.isEmpty else { continue }
            processResponse(line)
        }
    }

    private func processResponse(_ json: String) {
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(LlmResponse.self, from: data)
        else {
            Log.error("[LLM] Invalid response: \(json)")
            return
        }

        if !isReady && response.ok && response.result == "ready" {
            isReady = true
            isLoading = false
            Log.info("[LLM] Helper is ready")
            return
        }

        if let cont = pendingContinuation {
            pendingContinuation = nil
            if response.ok, let result = response.result {
                if let ms = response.duration_ms {
                    Log.info("[LLM] Processed in \(ms)ms")
                }
                cont.resume(returning: result)
            } else {
                Log.error("[LLM] Processing failed: \(response.error ?? "unknown")")
                cont.resume(returning: nil)
            }
        }
    }

    deinit {
        process?.terminate()
    }
}
