//! C ABI for embedding the decoder in an app (Swift / Objective-C).
//!
//! - [`foveon_render`] `.x3f → DNG or developed-TIFF
//! - [`foveon_open`] / [`foveon_emit`] / [`foveon_close`]: parse, Huffman-decode
//!   & calibrate once, then emit any number of output formats from the same handle
//!
//! The caller owns every returned buffer and frees it with [`foveon_bytes_free`].
//! There is no global state and no filesystem access, so the entry points are
//! safe to call concurrently from many threads — one per image — which is how
//! the Swift wrapper saturates the CPU.

use crate::{RenderInfo, RenderMode};
use std::os::raw::c_char;

/// Owned byte buffer handed back to the caller. Free it exactly once with
/// [`foveon_bytes_free`]; never mutate the fields.
#[repr(C)]
pub struct FoveonBytes {
    pub ptr: *mut u8,
    pub len: usize,
    pub cap: usize,
}

impl FoveonBytes {
    const EMPTY: FoveonBytes = FoveonBytes {
        ptr: std::ptr::null_mut(),
        len: 0,
        cap: 0,
    };

    /// Transfer ownership of `v`'s allocation to the C caller.
    fn from_vec(mut v: Vec<u8>) -> FoveonBytes {
        v.shrink_to_fit();
        let b = FoveonBytes {
            ptr: v.as_mut_ptr(),
            len: v.len(),
            cap: v.capacity(),
        };
        std::mem::forget(v);
        b
    }
}

/// Rendered-image metadata (mirrors [`crate::RenderInfo`]).
#[repr(C)]
pub struct FoveonInfo {
    pub width: u32,
    pub height: u32,
    pub orientation: u32,
    pub spatial_gain: u32,
    pub mono_weights: [f32; 3],
    /// lens metadata
    pub focal_length: f32,
    pub aperture: f32,
    pub focal_min: f32,
    pub focal_max: f32,
    pub aperture_max: f32,
    /// capture metadata
    pub iso: f32,
    pub baseline_exposure: f32,
    /// body lens code (LENSMODEL; 0 = absent, 255 = unknown to the body)
    pub lens_model: u32,
}

impl From<&RenderInfo> for FoveonInfo {
    fn from(info: &RenderInfo) -> FoveonInfo {
        FoveonInfo {
            width: info.width,
            height: info.height,
            orientation: info.orientation as u32,
            spatial_gain: info.spatial_gain as u32,
            mono_weights: info.mono_weights,
            focal_length: info.focal_length,
            aperture: info.aperture,
            focal_min: info.focal_min,
            focal_max: info.focal_max,
            aperture_max: info.aperture_max,
            iso: info.iso,
            baseline_exposure: info.baseline_exposure,
            lens_model: info.lens_model,
        }
    }
}

/// Opaque prepared decode: the parsed container, Huffman-decoded raw and colour
/// calibration, ready to emit any output format.
pub struct FoveonPrepared(crate::Prepared);

/// The C `mode` values shared by [`foveon_render`] and [`foveon_emit`].
fn render_mode(mode: u32) -> Option<RenderMode> {
    match mode {
        0 => Some(RenderMode::Dng),
        1 => Some(RenderMode::TiffLinearF16),
        2 => Some(RenderMode::TiffProxyHalf),
        3 => Some(RenderMode::RgbaLinearF16),
        4 => Some(RenderMode::RgbaProxyHalf),
        _ => None,
    }
}

/// Parse the optional NUL-terminated white-balance override.
///
/// # Safety
/// `wb` must be a valid C string or `NULL`.
unsafe fn wb_str<'a>(wb: *const c_char) -> Result<Option<&'a str>, ()> {
    if wb.is_null() {
        return Ok(None);
    }
    match unsafe { std::ffi::CStr::from_ptr(wb) }.to_str() {
        Ok(s) => Ok(Some(s)),
        Err(_) => Err(()),
    }
}

/// Write an emit result to the out-parameters, returning the C status code.
///
/// # Safety
/// `out_bytes` must be valid-writable; `out_info` must be valid-writable or `NULL`.
unsafe fn deliver(
    result: Result<(Vec<u8>, RenderInfo), String>,
    out_bytes: *mut FoveonBytes,
    out_info: *mut FoveonInfo,
) -> i32 {
    match result {
        Ok((bytes, info)) => {
            unsafe { *out_bytes = FoveonBytes::from_vec(bytes) };
            if !out_info.is_null() {
                unsafe { *out_info = FoveonInfo::from(&info) };
            }
            0
        }
        Err(_) => -4,
    }
}

/// Render `.x3f` bytes to one output format:
/// `0` DNG, `1` developed f16 RGB TIFF, `2` half-res proxy TIFF,
/// `3` bare RGBA16F bitmap, `4` half-res proxy RGBA16F bitmap.
///
/// `wb` is an optional NUL-terminated white-balance name (`NULL` for the
/// as-shot value). On success returns `0`, writes the caller-owned buffer to
/// `*out_bytes`, and — when `out_info` is non-NULL — the dimensions to
/// `*out_info`. On failure returns a negative code and leaves `*out_bytes`
/// empty (a no-op for [`foveon_bytes_free`]).
///
/// # Safety
/// `x3f` must point to `x3f_len` readable bytes; `out_bytes` must be a valid
/// writable pointer; `out_info` must be valid-writable or `NULL`; `wb` must be a
/// valid C string or `NULL`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn foveon_render(
    x3f: *const u8,
    x3f_len: usize,
    mode: u32,
    wb: *const c_char,
    out_bytes: *mut FoveonBytes,
    out_info: *mut FoveonInfo,
) -> i32 {
    if x3f.is_null() || out_bytes.is_null() {
        return -1;
    }
    unsafe { *out_bytes = FoveonBytes::EMPTY };

    let data = unsafe { std::slice::from_raw_parts(x3f, x3f_len) };
    let Ok(wb) = (unsafe { wb_str(wb) }) else {
        return -2;
    };
    let Some(mode) = render_mode(mode) else {
        return -3;
    };
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        crate::render_x3f(data, mode, wb)
    })) {
        Ok(result) => unsafe { deliver(result, out_bytes, out_info) },
        Err(_) => -5,
    }
}

/// Parse, Huffman-decode and colour-calibrate `.x3f` bytes once, for repeated
/// [`foveon_emit`] calls. Returns `NULL` on any failure (bad arguments,
/// malformed file, unsupported camera). Free with [`foveon_close`].
///
/// # Safety
/// `x3f` must point to `x3f_len` readable bytes; `wb` must be a valid C string
/// or `NULL`. The `x3f` bytes are fully consumed and need not outlive the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn foveon_open(
    x3f: *const u8,
    x3f_len: usize,
    wb: *const c_char,
) -> *mut FoveonPrepared {
    if x3f.is_null() {
        return std::ptr::null_mut();
    }
    let data = unsafe { std::slice::from_raw_parts(x3f, x3f_len) };
    let Ok(wb) = (unsafe { wb_str(wb) }) else {
        return std::ptr::null_mut();
    };
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| crate::prepare(data, wb))) {
        Ok(Ok(p)) => Box::into_raw(Box::new(FoveonPrepared(p))),
        _ => std::ptr::null_mut(),
    }
}

/// Emit one output format (same `mode` values as [`foveon_render`]) from a
/// prepared decode. Same out-parameter contract as [`foveon_render`]. The
/// handle is read-only here, so concurrent emits from one handle are safe.
///
/// # Safety
/// `prepared` must be a live handle from [`foveon_open`]; `out_bytes` must be a
/// valid writable pointer; `out_info` must be valid-writable or `NULL`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn foveon_emit(
    prepared: *const FoveonPrepared,
    mode: u32,
    out_bytes: *mut FoveonBytes,
    out_info: *mut FoveonInfo,
) -> i32 {
    if prepared.is_null() || out_bytes.is_null() {
        return -1;
    }
    unsafe { *out_bytes = FoveonBytes::EMPTY };
    let Some(mode) = render_mode(mode) else {
        return -3;
    };
    let p = unsafe { &(*prepared).0 };
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| crate::emit(p, mode))) {
        Ok(result) => unsafe { deliver(result, out_bytes, out_info) },
        Err(_) => -5,
    }
}

/// Free a handle returned by [`foveon_open`] (`NULL` is a no-op).
///
/// # Safety
/// `prepared` must be a handle from [`foveon_open`], not yet closed, or `NULL`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn foveon_close(prepared: *mut FoveonPrepared) {
    if !prepared.is_null() {
        drop(unsafe { Box::from_raw(prepared) });
    }
}

/// Free a buffer returned by [`foveon_render`] / [`foveon_emit`]. A
/// zeroed/empty buffer is a no-op; every non-empty buffer must be freed exactly
/// once.
///
/// # Safety
/// `b` must be a buffer previously returned by this library and not yet freed
/// (or a zeroed `FoveonBytes`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn foveon_bytes_free(b: FoveonBytes) {
    if !b.ptr.is_null() {
        drop(unsafe { Vec::from_raw_parts(b.ptr, b.len, b.cap) });
    }
}
