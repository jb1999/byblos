import Foundation

/// High-level Swift interface to the Byblos core engine.
/// Uses the C FFI declared in ByblosCore-Bridging-Header.h.
class ByblosEngine {
    private var handle: OpaquePointer?

    init?(modelPath: String, language: String? = nil) {
        let h: OpaquePointer? = modelPath.withCString { pathPtr in
            if let language {
                return language.withCString { langPtr in
                    byblos_create(pathPtr, langPtr)
                }
            } else {
                return byblos_create(pathPtr, nil)
            }
        }
        guard let h else {
            Log.info("[ByblosEngine] Failed to create engine for model: \(modelPath)")
            return nil
        }
        handle = h
        Log.info("[ByblosEngine] Loaded model: \(modelPath) language: \(language ?? "en")")
    }

    deinit {
        if let handle {
            byblos_destroy(handle)
        }
    }

    func startRecording() -> Bool {
        guard let handle else { return false }
        let result = byblos_start_recording(handle)
        Log.info("[ByblosEngine] Start recording: \(result)")
        return result
    }

    func stopAndTranscribe() -> String? {
        guard let handle else { return nil }
        guard let cStr = byblos_stop_recording(handle) else {
            Log.info("[ByblosEngine] Transcription returned nil")
            return nil
        }
        let result = String(cString: cStr)
        byblos_free_string(cStr)
        Log.info("[ByblosEngine] Transcribed: \(result)")
        return result
    }

    /// Load a different model at runtime.
    func loadModel(path: String, language: String? = nil) -> Bool {
        guard let handle else { return false }
        return path.withCString { pathPtr in
            if let language {
                return language.withCString { langPtr in
                    byblos_load_model(handle, pathPtr, langPtr)
                }
            } else {
                return byblos_load_model(handle, pathPtr, nil)
            }
        }
    }

    /// Transcribe a snapshot of current recording without stopping it.
    /// Returns partial transcription text, or nil.
    func transcribeSnapshot() -> String? {
        guard let handle else { return nil }
        guard let cStr = byblos_transcribe_snapshot(handle) else { return nil }
        let result = String(cString: cStr)
        byblos_free_string(cStr)
        return result
    }

    /// Get the duration of the last transcription in milliseconds.
    func transcriptionTimeMs() -> UInt64 {
        guard let handle else { return 0 }
        return byblos_get_transcription_time_ms(handle)
    }

    /// Enable or disable translation-to-English mode.
    func setTranslate(_ enabled: Bool) {
        guard let handle else { return }
        byblos_set_translate(handle, enabled)
        Log.info("[ByblosEngine] Translation mode: \(enabled ? "enabled" : "disabled")")
    }

    /// Transcribe an audio file from disk (must be WAV format).
    /// For non-WAV files, convert to WAV first using afconvert.
    func transcribeFile(path: String) -> String? {
        guard let handle else { return nil }
        guard let cStr = path.withCString({ pathPtr in
            byblos_transcribe_file(handle, pathPtr)
        }) else {
            Log.error("[ByblosEngine] File transcription returned nil for: \(path)")
            return nil
        }
        let result = String(cString: cStr)
        byblos_free_string(cStr)
        Log.info("[ByblosEngine] File transcribed: \(result.prefix(100))...")
        return result
    }

    // MARK: - Local LLM

    /// Initialize LLM early (must be called before ByblosEngine.init).
    /// This is needed because llama.cpp and whisper.cpp share ggml backends
    /// and llama must initialize first.
    static func initLlmEarly(path: String) -> Bool {
        path.withCString { byblos_init_llm_early($0) }
    }

    /// Attach an early-initialized LLM to this engine.
    func attachLlm() -> Bool {
        guard let handle else { return false }
        return byblos_attach_llm(handle)
    }

    /// Load a local LLM model (GGUF format) for text post-processing.
    /// NOTE: This only works if called before whisper init. Use initLlmEarly + attachLlm instead.
    func loadLlm(path: String) -> Bool {
        guard let handle else { return false }
        return path.withCString { byblos_load_llm(handle, $0) }
    }

    /// Check if a local LLM is loaded.
    var hasLlm: Bool {
        guard let handle else { return false }
        return byblos_has_llm(handle)
    }

    /// Process text through the local LLM with a system prompt.
    /// Returns processed text, or original text if LLM not available.
    func processText(_ text: String, systemPrompt: String) -> String? {
        guard let handle else { return nil }
        let result: UnsafeMutablePointer<CChar>? = text.withCString { textPtr in
            systemPrompt.withCString { promptPtr in
                byblos_process_text(handle, textPtr, promptPtr)
            }
        }
        guard let cStr = result else { return nil }
        let output = String(cString: cStr)
        byblos_free_string(cStr)
        return output
    }

    /// Find the default LLM model path.
    static func defaultLlmPath() -> String? {
        let llmDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Byblos/llm-models")
        try? FileManager.default.createDirectory(atPath: llmDir.path, withIntermediateDirectories: true)

        // Look for any .gguf file.
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: llmDir.path) else {
            return nil
        }
        if let gguf = files.first(where: { $0.hasSuffix(".gguf") }) {
            return llmDir.appendingPathComponent(gguf).path
        }
        return nil
    }

    /// Map model IDs to filenames.
    static let modelFileNames: [String: String] = [
        "whisper-tiny": "ggml-tiny.bin",
        "whisper-base": "ggml-base.bin",
        "whisper-small": "ggml-small.bin",
        "whisper-medium": "ggml-medium.bin",
        "whisper-large-v3": "ggml-large-v3.bin",
        "whisper-turbo": "ggml-large-v3-turbo.bin",
        "distil-whisper-large-v3": "ggml-distil-large-v3.bin",
        // Parakeet models are directories, not single files.
        // The path points to the directory containing model.onnx + tokenizer.json.
        "parakeet-tdt-0.6b": "parakeet-tdt-0.6b",
    ]

    /// Find the model path for the user's selected model.
    /// Falls back to any downloaded model if the selected one isn't available.
    static func defaultModelPath() -> String? {
        let modelsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Byblos/models")

        // Try the user's selected model first.
        let selectedId = UserDefaults.standard.string(forKey: "selectedModel") ?? "whisper-base"
        if let fileName = modelFileNames[selectedId] {
            let path = modelsDir.appendingPathComponent(fileName).path
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Fall back to any downloaded model (prefer larger/better ones).
        let fallbackOrder = [
            "ggml-large-v3-turbo.bin",
            "ggml-distil-large-v3.bin",
            "ggml-large-v3.bin",
            "ggml-medium.bin",
            "ggml-small.bin",
            "ggml-base.bin",
            "ggml-tiny.bin",
            // Also check English-only variants (user may have downloaded these earlier).
            "ggml-base.en.bin",
            "ggml-tiny.en.bin",
        ]

        for fileName in fallbackOrder {
            let path = modelsDir.appendingPathComponent(fileName).path
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Last resort: any .bin file.
        if let files = try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path) {
            if let bin = files.first(where: { $0.hasSuffix(".bin") }) {
                return modelsDir.appendingPathComponent(bin).path
            }
        }

        return nil
    }
}
