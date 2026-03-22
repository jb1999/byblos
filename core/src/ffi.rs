//! C ABI exports for native UI integration.
//!
//! This module exposes the core engine to Swift (macOS), C# (Windows),
//! and C (Linux/GTK) via a stable C interface.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use std::sync::Mutex;

use crate::llm::LlmEngine;
use crate::pipeline::Pipeline;

/// Opaque handle to a Byblos pipeline instance.
pub struct ByblosHandle {
    pipeline: Pipeline,
    llm: Option<LlmEngine>,
}

/// Initialize the LLM backend early, before whisper/ggml.
/// Must be called before `byblos_create` if you want LLM support.
/// Returns an opaque LLM handle, or null on failure.
/// Pass the returned handle to `byblos_attach_llm` after creating the pipeline.
static EARLY_LLM: Mutex<Option<LlmEngine>> = Mutex::new(None);

#[unsafe(no_mangle)]
pub extern "C" fn byblos_init_llm_early(model_path: *const c_char) -> bool {
    let path = unsafe {
        if model_path.is_null() {
            return false;
        }
        match CStr::from_ptr(model_path).to_str() {
            Ok(s) => s,
            Err(_) => return false,
        }
    };

    match LlmEngine::load(path.as_ref()) {
        Ok(engine) => {
            if let Ok(mut guard) = EARLY_LLM.lock() {
                *guard = Some(engine);
            }
            log::info!("LLM initialized early (before whisper)");
            true
        }
        Err(e) => {
            log::error!("Failed to init LLM early: {e}");
            false
        }
    }
}

/// Attach an early-initialized LLM to a pipeline handle.
#[unsafe(no_mangle)]
pub extern "C" fn byblos_attach_llm(handle: *mut ByblosHandle) -> bool {
    let handle = unsafe {
        if handle.is_null() {
            return false;
        }
        &mut *handle
    };

    if let Ok(mut guard) = EARLY_LLM.lock() {
        if let Some(engine) = guard.take() {
            handle.llm = Some(engine);
            return true;
        }
    }
    false
}

/// Create a new Byblos instance with the given model path and language.
///
/// `language` is a language code (e.g. "en", "fr", "auto"). Pass null for default ("en").
/// Returns a pointer to the handle, or null on failure.
/// Caller must eventually call `byblos_destroy` to free.
#[unsafe(no_mangle)]
pub extern "C" fn byblos_create(
    model_path: *const c_char,
    language: *const c_char,
) -> *mut ByblosHandle {
    let path = unsafe {
        if model_path.is_null() {
            return ptr::null_mut();
        }
        match CStr::from_ptr(model_path).to_str() {
            Ok(s) => s,
            Err(_) => return ptr::null_mut(),
        }
    };

    let lang = if language.is_null() {
        "en"
    } else {
        unsafe {
            match CStr::from_ptr(language).to_str() {
                Ok(s) => s,
                Err(_) => "en",
            }
        }
    };

    match Pipeline::with_language(path.as_ref(), lang) {
        Ok(pipeline) => Box::into_raw(Box::new(ByblosHandle { pipeline, llm: None })),
        Err(e) => {
            log::error!("Failed to create pipeline: {e}");
            ptr::null_mut()
        }
    }
}

/// Start recording audio.
#[unsafe(no_mangle)]
pub extern "C" fn byblos_start_recording(handle: *mut ByblosHandle) -> bool {
    let handle = unsafe {
        if handle.is_null() {
            return false;
        }
        &mut *handle
    };
    handle.pipeline.start_recording().is_ok()
}

/// Stop recording and begin transcription.
///
/// Returns the transcribed text as a C string. Caller must free with `byblos_free_string`.
#[unsafe(no_mangle)]
pub extern "C" fn byblos_stop_recording(handle: *mut ByblosHandle) -> *mut c_char {
    let handle = unsafe {
        if handle.is_null() {
            return ptr::null_mut();
        }
        &mut *handle
    };

    match handle.pipeline.stop_and_transcribe() {
        Ok(text) => CString::new(text).map(|s| s.into_raw()).unwrap_or(ptr::null_mut()),
        Err(e) => {
            log::error!("Transcription failed: {e}");
            ptr::null_mut()
        }
    }
}

/// Callback type for streaming partial results.
/// `text` is a temporary C string (only valid during the call).
/// `user_data` is the opaque pointer passed to `byblos_start_streaming`.
pub type ByblosPartialCallback =
    extern "C" fn(text: *const c_char, user_data: *mut std::ffi::c_void);

/// Start recording with streaming partial results.
///
/// The callback will be called periodically on a background thread with
/// partial transcription text. Call `byblos_stop_recording` to stop and
/// get the final result.
#[unsafe(no_mangle)]
pub extern "C" fn byblos_start_streaming(
    handle: *mut ByblosHandle,
    callback: ByblosPartialCallback,
    user_data: *mut std::ffi::c_void,
) -> bool {
    let handle = unsafe {
        if handle.is_null() {
            return false;
        }
        &mut *handle
    };
    handle
        .pipeline
        .start_streaming(callback, user_data)
        .is_ok()
}

/// Transcribe a snapshot of the current recording without stopping it.
///
/// Returns the partial transcription as a C string.
/// Caller must free with `byblos_free_string`.
/// Returns null if no audio or transcription fails.
#[unsafe(no_mangle)]
pub extern "C" fn byblos_transcribe_snapshot(handle: *mut ByblosHandle) -> *mut c_char {
    let handle = unsafe {
        if handle.is_null() {
            return ptr::null_mut();
        }
        &mut *handle
    };

    match handle.pipeline.transcribe_snapshot() {
        Ok(text) if !text.is_empty() => {
            CString::new(text).map(|s| s.into_raw()).unwrap_or(ptr::null_mut())
        }
        _ => ptr::null_mut(),
    }
}

/// Free a string returned by byblos functions.
#[unsafe(no_mangle)]
pub extern "C" fn byblos_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            drop(CString::from_raw(s));
        }
    }
}

/// Load a new model at runtime, replacing the current one.
///
/// `language` is a language code (e.g. "en", "fr", "auto"). Pass null for default ("en").
/// Returns true on success, false on failure.
#[unsafe(no_mangle)]
pub extern "C" fn byblos_load_model(
    handle: *mut ByblosHandle,
    model_path: *const c_char,
    language: *const c_char,
) -> bool {
    let handle = unsafe {
        if handle.is_null() {
            return false;
        }
        &mut *handle
    };

    let path = unsafe {
        if model_path.is_null() {
            return false;
        }
        match CStr::from_ptr(model_path).to_str() {
            Ok(s) => s,
            Err(_) => return false,
        }
    };

    let lang = if language.is_null() {
        "en"
    } else {
        unsafe {
            match CStr::from_ptr(language).to_str() {
                Ok(s) => s,
                Err(_) => "en",
            }
        }
    };

    match handle.pipeline.reload_model(path.as_ref(), lang) {
        Ok(()) => true,
        Err(e) => {
            log::error!("Failed to load model: {e}");
            false
        }
    }
}

/// Get the duration of the last transcription in milliseconds.
///
/// Returns 0 if no transcription has been performed yet.
#[unsafe(no_mangle)]
pub extern "C" fn byblos_get_transcription_time_ms(handle: *const ByblosHandle) -> u64 {
    let handle = unsafe {
        if handle.is_null() {
            return 0;
        }
        &*handle
    };
    handle.pipeline.last_transcription_ms()
}

/// Load a local LLM model (GGUF format) for text post-processing.
///
/// Call this after `byblos_create` to enable LLM-powered dictation modes.
/// Returns true on success, false on failure.
#[unsafe(no_mangle)]
pub extern "C" fn byblos_load_llm(
    handle: *mut ByblosHandle,
    model_path: *const c_char,
) -> bool {
    let handle = unsafe {
        if handle.is_null() {
            return false;
        }
        &mut *handle
    };

    let path = unsafe {
        if model_path.is_null() {
            return false;
        }
        match CStr::from_ptr(model_path).to_str() {
            Ok(s) => s,
            Err(_) => return false,
        }
    };

    match LlmEngine::load(path.as_ref()) {
        Ok(engine) => {
            handle.llm = Some(engine);
            true
        }
        Err(e) => {
            log::error!("Failed to load LLM: {e}");
            false
        }
    }
}

/// Process text through the local LLM with a system prompt.
///
/// Returns the processed text as a C string. Caller must free with `byblos_free_string`.
/// Returns null if no LLM is loaded or processing fails.
/// Falls back to returning the original text if LLM is not available.
#[unsafe(no_mangle)]
pub extern "C" fn byblos_process_text(
    handle: *mut ByblosHandle,
    text: *const c_char,
    system_prompt: *const c_char,
) -> *mut c_char {
    let handle = unsafe {
        if handle.is_null() {
            return ptr::null_mut();
        }
        &mut *handle
    };

    let text_str = unsafe {
        if text.is_null() {
            return ptr::null_mut();
        }
        match CStr::from_ptr(text).to_str() {
            Ok(s) => s,
            Err(_) => return ptr::null_mut(),
        }
    };

    let prompt_str = unsafe {
        if system_prompt.is_null() {
            return ptr::null_mut();
        }
        match CStr::from_ptr(system_prompt).to_str() {
            Ok(s) => s,
            Err(_) => return ptr::null_mut(),
        }
    };

    let result = if let Some(ref llm) = handle.llm {
        match llm.process(text_str, prompt_str) {
            Ok(processed) => processed,
            Err(e) => {
                log::error!("LLM processing failed: {e}");
                text_str.to_string()
            }
        }
    } else {
        // No LLM loaded — return original text.
        text_str.to_string()
    };

    CString::new(result)
        .map(|s| s.into_raw())
        .unwrap_or(ptr::null_mut())
}

/// Check if a local LLM is loaded.
#[unsafe(no_mangle)]
pub extern "C" fn byblos_has_llm(handle: *const ByblosHandle) -> bool {
    let handle = unsafe {
        if handle.is_null() {
            return false;
        }
        &*handle
    };
    handle.llm.is_some()
}

/// Enable or disable translation-to-English mode.
///
/// When enabled, whisper will translate any language to English.
#[unsafe(no_mangle)]
pub extern "C" fn byblos_set_translate(handle: *mut ByblosHandle, translate: bool) {
    let handle = unsafe {
        if handle.is_null() {
            return;
        }
        &mut *handle
    };
    handle.pipeline.set_translate(translate);
}

/// Transcribe an audio file from disk.
///
/// The file must be a WAV file (16-bit or 32-bit float).
/// For other formats, convert to WAV first (e.g. using afconvert on macOS).
/// Returns the transcribed text as a C string. Caller must free with `byblos_free_string`.
/// Returns null on failure.
#[unsafe(no_mangle)]
pub extern "C" fn byblos_transcribe_file(
    handle: *mut ByblosHandle,
    file_path: *const c_char,
) -> *mut c_char {
    let handle = unsafe {
        if handle.is_null() {
            return ptr::null_mut();
        }
        &mut *handle
    };

    let path_str = unsafe {
        if file_path.is_null() {
            return ptr::null_mut();
        }
        match CStr::from_ptr(file_path).to_str() {
            Ok(s) => s,
            Err(_) => return ptr::null_mut(),
        }
    };

    match handle.pipeline.transcribe_file(std::path::Path::new(path_str)) {
        Ok(text) => CString::new(text)
            .map(|s| s.into_raw())
            .unwrap_or(ptr::null_mut()),
        Err(e) => {
            log::error!("File transcription failed: {e}");
            ptr::null_mut()
        }
    }
}

/// Destroy a Byblos instance and free all resources.
#[unsafe(no_mangle)]
pub extern "C" fn byblos_destroy(handle: *mut ByblosHandle) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}
