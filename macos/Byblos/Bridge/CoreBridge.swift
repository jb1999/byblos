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

    /// Find the default model path.
    static func defaultModelPath() -> String? {
        let modelsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Byblos/models")

        // Prefer base.en, fall back to tiny.en, then any .bin file.
        let candidates = [
            "ggml-base.en.bin",
            "ggml-tiny.en.bin",
        ]

        for candidate in candidates {
            let path = modelsDir.appendingPathComponent(candidate).path
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try any .bin file in the models dir.
        if let files = try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path) {
            if let bin = files.first(where: { $0.hasSuffix(".bin") }) {
                return modelsDir.appendingPathComponent(bin).path
            }
        }

        return nil
    }
}
