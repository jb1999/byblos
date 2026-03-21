//! C ABI exports for native UI integration.
//!
//! This module exposes the core engine to Swift (macOS), C# (Windows),
//! and C (Linux/GTK) via a stable C interface.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use crate::pipeline::Pipeline;

/// Opaque handle to a Byblos pipeline instance.
pub struct ByblosHandle {
    pipeline: Pipeline,
}

/// Create a new Byblos instance with the given model path.
///
/// Returns a pointer to the handle, or null on failure.
/// Caller must eventually call `byblos_destroy` to free.
#[unsafe(no_mangle)]
pub extern "C" fn byblos_create(model_path: *const c_char) -> *mut ByblosHandle {
    let path = unsafe {
        if model_path.is_null() {
            return ptr::null_mut();
        }
        match CStr::from_ptr(model_path).to_str() {
            Ok(s) => s,
            Err(_) => return ptr::null_mut(),
        }
    };

    match Pipeline::new(path.as_ref()) {
        Ok(pipeline) => Box::into_raw(Box::new(ByblosHandle { pipeline })),
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

/// Free a string returned by byblos functions.
#[unsafe(no_mangle)]
pub extern "C" fn byblos_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            drop(CString::from_raw(s));
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
