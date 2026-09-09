//! Cross-platform PTY resource core.
//!
//! This layer deliberately owns the native PTY, its reader/writer handles and
//! child lifecycle. The Flutter bridge remains responsible for forwarding
//! chunks to Dart ports, so the Dart-facing API can migrate without changing
//! stream semantics.

use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::io::{self, Read, Write};
use std::os::raw::c_char;
use std::path::Path;
use std::ptr;
use std::sync::Mutex;

use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};

pub struct PtySession {
    master: Box<dyn MasterPty + Send>,
    reader: Mutex<Box<dyn Read + Send>>,
    writer: Mutex<Box<dyn Write + Send>>,
    child: Mutex<Box<dyn Child + Send + Sync>>,
    pid: Option<u32>,
}

impl PtySession {
    pub fn spawn(
        executable: &str,
        arguments: &[String],
        working_directory: Option<&Path>,
        environment: impl IntoIterator<Item = (String, String)>,
        columns: u16,
        rows: u16,
    ) -> io::Result<Self> {
        let system = native_pty_system();
        let pair = system
            .openpty(PtySize {
                rows: rows.max(1),
                cols: columns.max(1),
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(to_io)?;
        let mut command = CommandBuilder::new(executable);
        command.args(arguments);
        if let Some(working_directory) = working_directory {
            command.cwd(working_directory);
        }
        for (key, value) in environment {
            command.env(key, value);
        }
        let child = pair.slave.spawn_command(command).map_err(to_io)?;
        let pid = child.process_id();
        drop(pair.slave);
        let reader = pair.master.try_clone_reader().map_err(to_io)?;
        let writer = pair.master.take_writer().map_err(to_io)?;
        Ok(Self {
            master: pair.master,
            reader: Mutex::new(reader),
            writer: Mutex::new(writer),
            child: Mutex::new(child),
            pid,
        })
    }

    /// Blocking read for the bridge-owned reader thread.
    pub fn read(&self, output: &mut [u8]) -> io::Result<usize> {
        self.reader
            .lock()
            .expect("PTY reader mutex poisoned")
            .read(output)
    }

    pub fn write_all(&self, input: &[u8]) -> io::Result<()> {
        let mut writer = self.writer.lock().expect("PTY writer mutex poisoned");
        writer.write_all(input)?;
        writer.flush()
    }

    pub fn resize(&self, columns: u16, rows: u16) -> io::Result<()> {
        self.master
            .resize(PtySize {
                rows: rows.max(1),
                cols: columns.max(1),
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(to_io)
    }

    pub fn pid(&self) -> Option<u32> {
        self.pid
    }

    pub fn try_wait(&self) -> io::Result<Option<i32>> {
        self.child
            .lock()
            .expect("PTY child mutex poisoned")
            .try_wait()
            .map(|status| status.map(|value| value.exit_code() as i32))
    }

    pub fn wait(&self) -> io::Result<i32> {
        self.child
            .lock()
            .expect("PTY child mutex poisoned")
            .wait()
            .map(|status| status.exit_code() as i32)
    }

    pub fn kill(&self) -> io::Result<()> {
        #[cfg(unix)]
        {
            self.kill_unix()
        }
        #[cfg(not(unix))]
        {
            self.child.lock().expect("PTY child mutex poisoned").kill()
        }
    }

    #[cfg(unix)]
    fn kill_unix(&self) -> io::Result<()> {
        let Some(pid) = self.pid else {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "PTY child has no process ID",
            ));
        };
        // `wait()` legitimately holds the child mutex while blocking. Send
        // SIGKILL by the immutable PID so shutdown can always wake that
        // waiter instead of deadlocking behind its lock.
        let result = unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
        if result == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }
}

fn to_io(error: impl std::fmt::Display) -> io::Error {
    io::Error::other(error.to_string())
}

/// Opaque C-ABI owner for one PTY and its child process.
pub struct SstermPtyCore {
    session: PtySession,
}

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::new("no error").unwrap());
}

fn set_error(error: impl std::fmt::Display) {
    let message = error.to_string().replace('\0', " ");
    let value = CString::new(message).unwrap_or_else(|_| CString::new("native PTY error").unwrap());
    LAST_ERROR.with(|slot| *slot.borrow_mut() = value);
}

fn clear_error() {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = CString::new("").unwrap());
}

unsafe fn required_utf8<'a>(value: *const c_char, name: &str) -> io::Result<&'a str> {
    if value.is_null() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{name} must not be null"),
        ));
    }
    CStr::from_ptr(value).to_str().map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{name} must be valid UTF-8"),
        )
    })
}

unsafe fn optional_utf8<'a>(value: *const c_char, name: &str) -> io::Result<Option<&'a str>> {
    if value.is_null() {
        Ok(None)
    } else {
        required_utf8(value, name).map(Some)
    }
}

unsafe fn utf8_array(
    values: *const *const c_char,
    count: usize,
    name: &str,
) -> io::Result<Vec<String>> {
    if count != 0 && values.is_null() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{name} must not be null when its count is non-zero"),
        ));
    }
    (0..count)
        .map(|index| required_utf8(*values.add(index), name).map(str::to_owned))
        .collect()
}

struct FfiSpawnOptions {
    executable: *const c_char,
    arguments: *const *const c_char,
    argument_count: usize,
    working_directory: *const c_char,
    environment: *const *const c_char,
    environment_count: usize,
    columns: u16,
    rows: u16,
}

unsafe fn create_session(options: FfiSpawnOptions) -> io::Result<PtySession> {
    let executable = required_utf8(options.executable, "executable")?;
    let arguments = utf8_array(options.arguments, options.argument_count, "argument")?;
    let cwd = optional_utf8(options.working_directory, "working_directory")?;
    let environment = utf8_array(
        options.environment,
        options.environment_count,
        "environment entry",
    )?
    .into_iter()
    .map(|entry| {
        entry.split_once('=').map_or_else(
            || {
                Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "environment entries must have KEY=VALUE form",
                ))
            },
            |(key, value)| Ok((key.to_owned(), value.to_owned())),
        )
    })
    .collect::<io::Result<Vec<_>>>()?;
    PtySession::spawn(
        executable,
        &arguments,
        cwd.map(Path::new),
        environment,
        options.columns,
        options.rows,
    )
}

/// Creates a PTY session. `arguments` excludes the executable itself.
#[no_mangle]
/// # Safety
///
/// All non-null string pointers must point to valid, NUL-terminated UTF-8 for
/// this call. `arguments` must reference `argument_count` pointers when the
/// count is non-zero.
pub unsafe extern "C" fn ssterm_pty_create(
    executable: *const c_char,
    arguments: *const *const c_char,
    argument_count: usize,
    working_directory: *const c_char,
    columns: u16,
    rows: u16,
) -> *mut SstermPtyCore {
    let result = std::panic::catch_unwind(|| {
        create_session(FfiSpawnOptions {
            executable,
            arguments,
            argument_count,
            working_directory,
            environment: ptr::null(),
            environment_count: 0,
            columns,
            rows,
        })
    });
    match result {
        Ok(Ok(session)) => {
            clear_error();
            Box::into_raw(Box::new(SstermPtyCore { session }))
        }
        Ok(Err(error)) => {
            set_error(error);
            ptr::null_mut()
        }
        Err(_) => {
            set_error("panic while creating native PTY");
            ptr::null_mut()
        }
    }
}

/// Creates a PTY session with additional `KEY=VALUE` environment entries.
#[no_mangle]
/// # Safety
///
/// All non-null string pointers must point to valid, NUL-terminated UTF-8 for
/// this call. `arguments` and `environment` must each reference at least the
/// supplied count of pointers when their respective count is non-zero.
pub unsafe extern "C" fn ssterm_pty_create_with_environment(
    executable: *const c_char,
    arguments: *const *const c_char,
    argument_count: usize,
    working_directory: *const c_char,
    environment: *const *const c_char,
    environment_count: usize,
    columns: u16,
    rows: u16,
) -> *mut SstermPtyCore {
    let result = std::panic::catch_unwind(|| {
        create_session(FfiSpawnOptions {
            executable,
            arguments,
            argument_count,
            working_directory,
            environment,
            environment_count,
            columns,
            rows,
        })
    });
    match result {
        Ok(Ok(session)) => {
            clear_error();
            Box::into_raw(Box::new(SstermPtyCore { session }))
        }
        Ok(Err(error)) => {
            set_error(error);
            ptr::null_mut()
        }
        Err(_) => {
            set_error("panic while creating native PTY");
            ptr::null_mut()
        }
    }
}

#[no_mangle]
/// # Safety
///
/// `pty` must be null or a unique pointer returned by this library. It must
/// not be used again after this call, nor be accessed by another thread.
pub unsafe extern "C" fn ssterm_pty_destroy(pty: *mut SstermPtyCore) {
    if !pty.is_null() {
        let pty = Box::from_raw(pty);
        let _ = pty.session.kill();
        let _ = pty.session.wait();
    }
}

#[no_mangle]
/// # Safety
///
/// `pty` must point to a live PTY from this library. For non-zero `length`,
/// `buffer` must reference writable storage for at least that many bytes.
pub unsafe extern "C" fn ssterm_pty_read(
    pty: *mut SstermPtyCore,
    buffer: *mut u8,
    length: usize,
) -> i64 {
    if pty.is_null() || (buffer.is_null() && length != 0) {
        set_error("PTY and non-empty read buffer must not be null");
        return -1;
    }
    if length == 0 {
        return 0;
    }
    match (*pty)
        .session
        .read(std::slice::from_raw_parts_mut(buffer, length))
    {
        Ok(read) => {
            clear_error();
            read as i64
        }
        Err(error) => {
            set_error(error);
            -1
        }
    }
}

#[no_mangle]
/// # Safety
///
/// `pty` must point to a live PTY from this library. For non-zero `length`,
/// `buffer` must reference readable storage for at least that many bytes.
pub unsafe extern "C" fn ssterm_pty_write(
    pty: *mut SstermPtyCore,
    buffer: *const u8,
    length: usize,
) -> i32 {
    if pty.is_null() || (buffer.is_null() && length != 0) {
        set_error("PTY and non-empty write buffer must not be null");
        return -1;
    }
    let input = if length == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(buffer, length)
    };
    match (*pty).session.write_all(input) {
        Ok(()) => {
            clear_error();
            0
        }
        Err(error) => {
            set_error(error);
            -1
        }
    }
}

#[no_mangle]
/// # Safety
///
/// `pty` must point to a live PTY from this library and not be concurrently
/// destroyed.
pub unsafe extern "C" fn ssterm_pty_resize(
    pty: *mut SstermPtyCore,
    columns: u16,
    rows: u16,
) -> i32 {
    if pty.is_null() {
        set_error("PTY must not be null");
        return -1;
    }
    match (*pty).session.resize(columns, rows) {
        Ok(()) => 0,
        Err(error) => {
            set_error(error);
            -1
        }
    }
}

#[no_mangle]
/// # Safety
///
/// `pty` must point to a live PTY from this library and not be concurrently
/// destroyed.
pub unsafe extern "C" fn ssterm_pty_kill(pty: *mut SstermPtyCore) -> i32 {
    if pty.is_null() {
        set_error("PTY must not be null");
        return -1;
    }
    match (*pty).session.kill() {
        Ok(()) => 0,
        Err(error) => {
            set_error(error);
            -1
        }
    }
}

#[no_mangle]
/// # Safety
///
/// `pty` must point to a live PTY from this library. `exit_code` must point to
/// writable `i32` storage, and no other caller may concurrently wait on it.
pub unsafe extern "C" fn ssterm_pty_wait(pty: *mut SstermPtyCore, exit_code: *mut i32) -> i32 {
    if pty.is_null() || exit_code.is_null() {
        set_error("PTY and exit_code must not be null");
        return -1;
    }
    match (*pty).session.wait() {
        Ok(status) => {
            *exit_code = status;
            clear_error();
            0
        }
        Err(error) => {
            set_error(error);
            -1
        }
    }
}

#[no_mangle]
/// # Safety
///
/// `pty` must point to a live PTY from this library and not be concurrently
/// destroyed.
pub unsafe extern "C" fn ssterm_pty_pid(pty: *mut SstermPtyCore) -> u32 {
    if pty.is_null() {
        set_error("PTY must not be null");
        return 0;
    }
    (*pty).session.pid().unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn ssterm_pty_error() -> *const c_char {
    LAST_ERROR.with(|slot| slot.borrow().as_ptr())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[cfg(unix)]
    #[test]
    fn spawns_resizes_writes_and_reaps_a_unix_shell() {
        let session = PtySession::spawn(
            "/bin/sh",
            &[
                "-c".to_owned(),
                "read v; printf 'reply:%s\\n' \"$v\"".to_owned(),
            ],
            None,
            [("TERM".to_owned(), "xterm-256color".to_owned())],
            80,
            24,
        )
        .expect("spawn PTY shell");
        assert!(session.pid().is_some());
        session.resize(120, 40).expect("resize PTY");
        session.write_all(b"hello\n").expect("write PTY");

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut output = Vec::new();
        while Instant::now() < deadline {
            let mut chunk = [0_u8; 512];
            let read = session.read(&mut chunk).expect("read PTY");
            if read == 0 {
                break;
            }
            output.extend_from_slice(&chunk[..read]);
            if output
                .windows(b"reply:hello".len())
                .any(|line| line == b"reply:hello")
            {
                break;
            }
        }
        assert!(String::from_utf8_lossy(&output).contains("reply:hello"));
        assert_eq!(session.wait().expect("wait PTY"), 0);
    }

    #[cfg(unix)]
    #[test]
    fn kills_a_long_lived_child() {
        let session = PtySession::spawn(
            "/bin/sh",
            &["-c".to_owned(), "while :; do sleep 1; done".to_owned()],
            None,
            std::iter::empty(),
            80,
            24,
        )
        .expect("spawn long-lived PTY shell");
        session.kill().expect("kill PTY child");
        assert!(session.wait().expect("wait killed PTY") != 0);
    }
}
