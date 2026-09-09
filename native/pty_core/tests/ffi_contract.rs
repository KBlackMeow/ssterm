#![cfg(unix)]

use std::ffi::CString;
use std::os::raw::c_char;
use std::time::{Duration, Instant};

use ssterm_pty_core::{
    ssterm_pty_create_with_environment, ssterm_pty_destroy, ssterm_pty_pid, ssterm_pty_read,
    ssterm_pty_resize, ssterm_pty_wait, ssterm_pty_write,
};

#[test]
fn c_abi_spawns_reads_writes_resizes_and_waits() {
    let shell = CString::new("/bin/sh").unwrap();
    let flag = CString::new("-c").unwrap();
    let script = CString::new("read v; printf 'ffi:%s:%s\\n' \"$v\" \"$SSTERM_FFI_TEST\"").unwrap();
    let arguments: [*const c_char; 2] = [flag.as_ptr(), script.as_ptr()];
    let environment = CString::new("SSTERM_FFI_TEST=present").unwrap();
    let environment_values = [environment.as_ptr()];
    let pty = unsafe {
        ssterm_pty_create_with_environment(
            shell.as_ptr(),
            arguments.as_ptr(),
            arguments.len(),
            std::ptr::null(),
            environment_values.as_ptr(),
            environment_values.len(),
            80,
            24,
        )
    };
    assert!(!pty.is_null());
    assert_ne!(unsafe { ssterm_pty_pid(pty) }, 0);
    assert_eq!(unsafe { ssterm_pty_resize(pty, 120, 40) }, 0);
    assert_eq!(unsafe { ssterm_pty_write(pty, b"hello\n".as_ptr(), 6) }, 0);

    let deadline = Instant::now() + Duration::from_secs(5);
    let mut output = Vec::new();
    while Instant::now() < deadline {
        let mut chunk = [0_u8; 256];
        let count = unsafe { ssterm_pty_read(pty, chunk.as_mut_ptr(), chunk.len()) };
        assert!(count >= 0);
        if count == 0 {
            break;
        }
        output.extend_from_slice(&chunk[..count as usize]);
        if String::from_utf8_lossy(&output).contains("ffi:hello:present") {
            break;
        }
    }
    assert!(String::from_utf8_lossy(&output).contains("ffi:hello:present"));
    let mut exit_code = -1;
    assert_eq!(unsafe { ssterm_pty_wait(pty, &mut exit_code) }, 0);
    assert_eq!(exit_code, 0);
    unsafe { ssterm_pty_destroy(pty) };
}
