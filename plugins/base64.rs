// base64.rs — example pun plugin written in Rust.
//
// Provides one tool, "base64_encode", that encodes a string to base64.
//
// Build:
//   rustc --edition 2021 --crate-type cdylib base64.rs -o libbase64.so
// Install:
//   mkdir -p ~/.pun/plugins && cp libbase64.so ~/.pun/plugins/

use std::ffi::{CStr, c_char, c_int, c_void};
use std::ptr;

#[repr(C)]
struct PluginRegistry {
    add: Option<unsafe extern "C" fn(
        reg: *mut c_void,
        name: *const c_char,
        description: *const c_char,
        parameters_json: *const c_char,
        run_fn: unsafe extern "C" fn(
            tool_ctx: *mut c_void,
            alloc: *mut c_void,
            args_json: *const c_char,
            out_ptr: *mut *mut c_char,
            out_len: *mut usize,
            is_error: *mut c_int,
        ) -> c_int,
    >>,
    reg_ctx: *mut c_void,
}

extern "C" {
    fn malloc(size: usize) -> *mut c_void;
}

extern "C" fn base64_run(
    _tool_ctx: *mut c_void,
    _alloc: *mut c_void,
    args_json: *const c_char,
    out_ptr: *mut *mut c_char,
    out_len: *mut usize,
    is_error: *mut c_int,
) -> c_int {
    unsafe {
        *is_error = 0;
        // Parse { "text": "..." } minimally — we look for "text":"..."
        let args = CStr::from_ptr(args_json);
        let args_str = match args.to_str() {
            Ok(s) => s,
            Err(_) => return 1,
        };
        // Crude JSON extract: find "text":"..." (assumes no escaped quotes in input)
        let needle = "\"text\":\"";
        let start = match args_str.find(needle) {
            Some(i) => i + needle.len(),
            None => return 1,
        };
        let end = match args_str[start..].find('"') {
            Some(j) => start + j,
            None => return 1,
        };
        let text = &args_str[start..end];

        // Base64 encode (RFC 4648)
        let encoded = base64_encode(text.as_bytes());

        // malloc + copy
        let buf = malloc(encoded.len());
        if buf.is_null() {
            return 1;
        }
        ptr::copy_nonoverlapping(encoded.as_ptr() as *const c_char, buf as *mut c_char, encoded.len());
        *out_ptr = buf as *mut c_char;
        *out_len = encoded.len();
    }
    0
}

fn base64_encode(data: &[u8]) -> Vec<u8> {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = Vec::with_capacity((data.len() + 2) / 3 * 4);
    let mut i = 0;
    while i + 3 <= data.len() {
        let n = ((data[i] as u32) << 16) | ((data[i + 1] as u32) << 8) | (data[i + 2] as u32);
        out.push(TABLE[((n >> 18) & 0x3F) as usize]);
        out.push(TABLE[((n >> 12) & 0x3F) as usize]);
        out.push(TABLE[((n >> 6) & 0x3F) as usize]);
        out.push(TABLE[(n & 0x3F) as usize]);
        i += 3;
    }
    let rem = data.len() - i;
    if rem == 1 {
        let n = (data[i] as u32) << 16;
        out.push(TABLE[((n >> 18) & 0x3F) as usize]);
        out.push(TABLE[((n >> 12) & 0x3F) as usize]);
        out.push(b'=');
        out.push(b'=');
    } else if rem == 2 {
        let n = ((data[i] as u32) << 16) | ((data[i + 1] as u32) << 8);
        out.push(TABLE[((n >> 18) & 0x3F) as usize]);
        out.push(TABLE[((n >> 12) & 0x3F) as usize]);
        out.push(TABLE[((n >> 6) & 0x3F) as usize]);
        out.push(b'=');
    }
    out
}

#[no_mangle]
pub extern "C" fn pun_plugin_register(reg: *mut PluginRegistry, _tool_ctx: *mut c_void) -> c_int {
    unsafe {
        if reg.is_null() {
            return -1;
        }
        let r = &*reg;
        let add = match r.add {
            Some(f) => f,
            None => return -1,
        };
        add(
            r.reg_ctx,
            b"base64_encode\0".as_ptr() as *const c_char,
            b"Encode a string to base64. Pass {\"text\":\"...\"}.\0".as_ptr() as *const c_char,
            b"{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}\0".as_ptr() as *const c_char,
            base64_run,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn encodes_hello() {
        assert_eq!(b"SGVsbG8=", base64_encode(b"Hello").as_slice());
    }
    #[test]
    fn encodes_foobar() {
        assert_eq!(b"Zm9vYmFy", base64_encode(b"foobar").as_slice());
    }
}
