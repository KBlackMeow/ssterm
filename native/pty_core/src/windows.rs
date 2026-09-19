use std::collections::BTreeMap;
use std::ffi::{c_void, OsStr, OsString};
use std::fs::File;
use std::io::{self, Read, Write};
use std::mem;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::FromRawHandle;
use std::path::Path;
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

use winapi::shared::minwindef::{DWORD, FALSE};
use winapi::shared::winerror::{ERROR_BROKEN_PIPE, ERROR_IO_PENDING, ERROR_PIPE_CONNECTED, S_OK};
use winapi::um::consoleapi::{ClosePseudoConsole, CreatePseudoConsole, ResizePseudoConsole};
use winapi::um::errhandlingapi::GetLastError;
use winapi::um::fileapi::{CreateFileW, ReadFile, WriteFile, OPEN_EXISTING};
use winapi::um::handleapi::{CloseHandle, DuplicateHandle, INVALID_HANDLE_VALUE};
use winapi::um::ioapiset::{CancelIoEx, GetOverlappedResult};
use winapi::um::libloaderapi::{GetProcAddress, LoadLibraryW};
use winapi::um::minwinbase::OVERLAPPED;
use winapi::um::namedpipeapi::{ConnectNamedPipe, CreateNamedPipeW};
use winapi::um::processthreadsapi::{
    CreateProcessW, DeleteProcThreadAttributeList, GetCurrentProcess, GetExitCodeProcess,
    InitializeProcThreadAttributeList, OpenProcess, TerminateProcess, UpdateProcThreadAttribute,
    PROCESS_INFORMATION,
};
use winapi::um::synchapi::{CreateEventW, ResetEvent, WaitForSingleObject};
use winapi::um::winbase::{
    CREATE_UNICODE_ENVIRONMENT, EXTENDED_STARTUPINFO_PRESENT, INFINITE,
    PIPE_ACCESS_DUPLEX, PIPE_READMODE_BYTE, PIPE_TYPE_BYTE, PIPE_WAIT, STARTF_USESTDHANDLES,
    STARTUPINFOEXW,
};
use winapi::um::wincon::COORD;
use winapi::um::wincontypes::HPCON;
use winapi::um::winnt::{
    DUPLICATE_SAME_ACCESS, FILE_ATTRIBUTE_NORMAL, GENERIC_READ, GENERIC_WRITE, HANDLE,
    PROCESS_TERMINATE,
};

const PIPE_BUFFER_SIZE: DWORD = 128 * 1024;
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const STILL_ACTIVE: DWORD = 259;

type CreatePseudoConsoleFn =
    unsafe extern "system" fn(COORD, HANDLE, HANDLE, DWORD, *mut HPCON) -> i32;
type ResizePseudoConsoleFn = unsafe extern "system" fn(HPCON, COORD) -> i32;
type ClosePseudoConsoleFn = unsafe extern "system" fn(HPCON);

#[derive(Clone, Copy)]
struct ConPtyApi {
    create: CreatePseudoConsoleFn,
    resize: ResizePseudoConsoleFn,
    close: ClosePseudoConsoleFn,
    sidecar: bool,
}

fn conpty_api() -> &'static ConPtyApi {
    static API: OnceLock<ConPtyApi> = OnceLock::new();
    API.get_or_init(|| unsafe {
        let sidecar = wide_null("conpty.dll");
        let module = LoadLibraryW(sidecar.as_ptr());
        if !module.is_null() {
            let create = GetProcAddress(module, b"ConptyCreatePseudoConsole\0".as_ptr().cast());
            let resize = GetProcAddress(module, b"ConptyResizePseudoConsole\0".as_ptr().cast());
            let close = GetProcAddress(module, b"ConptyClosePseudoConsole\0".as_ptr().cast());
            if !create.is_null() && !resize.is_null() && !close.is_null() {
                return ConPtyApi {
                    create: mem::transmute(create),
                    resize: mem::transmute(resize),
                    close: mem::transmute(close),
                    sidecar: true,
                };
            }
        }
        ConPtyApi {
            create: CreatePseudoConsole,
            resize: ResizePseudoConsole,
            close: ClosePseudoConsole,
            sidecar: false,
        }
    })
}

struct OwnedHandle(HANDLE);

unsafe impl Send for OwnedHandle {}
unsafe impl Sync for OwnedHandle {}

impl Drop for OwnedHandle {
    fn drop(&mut self) {
        if !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE {
            unsafe { CloseHandle(self.0) };
        }
    }
}

pub struct PtySession {
    conpty: HPCON,
    io: SessionIo,
    process: Mutex<OwnedHandle>,
    pid: u32,
    // A sidecar OpenConsole opens the session by querying the attached
    // terminal (DA1) and stalls several seconds when nothing answers. The
    // first read sniffs that query and answers on the writer.
    answer_startup_query: AtomicBool,
}

enum SessionIo {
    Overlapped {
        reader: Mutex<OverlappedReader>,
        writer: Mutex<OverlappedWriter>,
    },
    Synchronous {
        reader: Mutex<File>,
        writer: Mutex<File>,
    },
}

enum PendingIo {
    Overlapped(OwnedHandle),
    Synchronous { reader: File, writer: File },
}

unsafe impl Send for PtySession {}
unsafe impl Sync for PtySession {}

impl PtySession {
    pub fn spawn(
        executable: &str,
        arguments: &[String],
        working_directory: Option<&Path>,
        environment: impl IntoIterator<Item = (String, String)>,
        columns: u16,
        rows: u16,
    ) -> io::Result<Self> {
        let mut conpty = ptr::null_mut();
        let size = COORD {
            X: columns.max(1) as i16,
            Y: rows.max(1) as i16,
        };
        let (result, pending_io) = if conpty_api().sidecar {
            let pipe = DuplexPipe::create()?;
            let result = unsafe {
                (conpty_api().create)(size, pipe.client.0, pipe.client.0, 0, &mut conpty)
            };
            (result, PendingIo::Overlapped(pipe.server))
        } else {
            let input = NamedPipe::create("in")?;
            let output = NamedPipe::create("out")?;
            let result = unsafe {
                (conpty_api().create)(size, input.server.0, output.server.0, 0, &mut conpty)
            };
            let writer = input.connect(GENERIC_WRITE)?;
            let reader = output.connect(GENERIC_READ)?;
            (result, PendingIo::Synchronous { reader, writer })
        };
        if result != S_OK {
            return Err(io::Error::other(format!(
                "CreatePseudoConsole failed with HRESULT {result:#x}"
            )));
        }
        let guard = ConPtyGuard(conpty);

        let io = match pending_io {
            PendingIo::Overlapped(server) => {
                let read_handle = duplicate_handle(server.0)?;
                SessionIo::Overlapped {
                    reader: Mutex::new(OverlappedReader::new(read_handle)?),
                    writer: Mutex::new(OverlappedWriter::new(server)?),
                }
            }
            PendingIo::Synchronous { reader, writer } => SessionIo::Synchronous {
                reader: Mutex::new(reader),
                writer: Mutex::new(writer),
            },
        };
        let (process, pid) = spawn_attached(
            conpty,
            executable,
            arguments,
            working_directory,
            environment,
        )?;
        mem::forget(guard);
        Ok(Self {
            conpty,
            io,
            process: Mutex::new(process),
            pid,
            answer_startup_query: AtomicBool::new(true),
        })
    }

    pub fn read(&self, output: &mut [u8]) -> io::Result<usize> {
        let mut count = match &self.io {
            SessionIo::Overlapped { reader, .. } => reader
                .lock()
                .expect("PTY reader mutex poisoned")
                .read(output),
            SessionIo::Synchronous { reader, .. } => reader
                .lock()
                .expect("PTY reader mutex poisoned")
                .read(output),
        }?;
        if count != 0 && self.answer_startup_query.swap(false, Ordering::Relaxed) {
            if output[..count].starts_with(b"\x1b[c") {
                self.answer_startup_query_if_asked();
                // Consume the query here so a terminal emulator above the
                // bridge cannot answer it again and leak a stray reply into
                // the child's input.
                output.copy_within(3..count, 0);
                count -= 3;
                if count == 0 {
                    return self.read(output);
                }
            }
        }
        Ok(count)
    }

    /// Answers a terminal-identification query emitted at session start.
    ///
    /// A sidecar OpenConsole sends `CSI c` (DA1) as the very first output and
    /// blocks the child's output for roughly three seconds when no reply
    /// arrives. Windows Terminal answers immediately, so it never sees the
    /// stall. The reply mirrors what Windows Terminal and xterm.js send:
    /// a level-5 VT500-class device with the common feature set. Replying
    /// only when the query was observed keeps sessions without the query
    /// (for example the inbox kernel32 pseudoconsole, which never asks)
    /// free of stray input that would otherwise leak to the child.
    fn answer_startup_query_if_asked(&self) {
        let _ = self.write_all(b"\x1b[?65;1;2;3;4;6;9;15;16;17;18;21;22;28c");
    }

    pub fn write_all(&self, input: &[u8]) -> io::Result<()> {
        match &self.io {
            SessionIo::Overlapped { writer, .. } => writer
                .lock()
                .expect("PTY writer mutex poisoned")
                .write_all(input),
            SessionIo::Synchronous { writer, .. } => {
                let mut writer = writer.lock().expect("PTY writer mutex poisoned");
                writer.write_all(input)?;
                writer.flush()
            }
        }
    }

    pub fn resize(&self, columns: u16, rows: u16) -> io::Result<()> {
        let result = unsafe {
            (conpty_api().resize)(
                self.conpty,
                COORD {
                    X: columns.max(1) as i16,
                    Y: rows.max(1) as i16,
                },
            )
        };
        if result == S_OK {
            Ok(())
        } else {
            Err(io::Error::other(format!(
                "ResizePseudoConsole failed with HRESULT {result:#x}"
            )))
        }
    }

    pub fn pid(&self) -> Option<u32> {
        Some(self.pid)
    }

    pub fn try_wait(&self) -> io::Result<Option<i32>> {
        let process = self.process.lock().expect("PTY process mutex poisoned");
        let mut code = 0;
        if unsafe { GetExitCodeProcess(process.0, &mut code) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok((code != STILL_ACTIVE).then_some(code as i32))
    }

    pub fn wait(&self) -> io::Result<i32> {
        let process = self.process.lock().expect("PTY process mutex poisoned");
        unsafe { WaitForSingleObject(process.0, INFINITE) };
        let mut code = 0;
        if unsafe { GetExitCodeProcess(process.0, &mut code) } == 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(code as i32)
        }
    }

    pub fn kill(&self) -> io::Result<()> {
        // `wait()` locks the process handle while it blocks.  Terminating by
        // PID instead of through that lock keeps teardown deadlock-free, which
        // matters for WSL launchers whose relay can outlive wsl.exe briefly.
        let process = unsafe { OpenProcess(PROCESS_TERMINATE, FALSE, self.pid) };
        if process.is_null() {
            return Err(io::Error::last_os_error());
        }
        let result = unsafe { TerminateProcess(process, 1) };
        unsafe { CloseHandle(process) };
        if result == 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }
}

impl Drop for PtySession {
    fn drop(&mut self) {
        unsafe { (conpty_api().close)(self.conpty) };
    }
}

struct ConPtyGuard(HPCON);

impl Drop for ConPtyGuard {
    fn drop(&mut self) {
        unsafe { (conpty_api().close)(self.0) };
    }
}

struct NamedPipe {
    server: OwnedHandle,
    name: Vec<u16>,
}

impl NamedPipe {
    fn create(kind: &str) -> io::Result<Self> {
        static NEXT_PIPE: AtomicU64 = AtomicU64::new(1);
        let id = NEXT_PIPE.fetch_add(1, Ordering::Relaxed);
        let name = wide_null(&format!(
            r"\\.\pipe\ssterm-conpty-{}-{id}-{kind}",
            std::process::id()
        ));
        let server = unsafe {
            CreateNamedPipeW(
                name.as_ptr(),
                PIPE_ACCESS_DUPLEX,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                1,
                PIPE_BUFFER_SIZE,
                PIPE_BUFFER_SIZE,
                30_000,
                ptr::null_mut(),
            )
        };
        if server == INVALID_HANDLE_VALUE {
            Err(io::Error::last_os_error())
        } else {
            Ok(Self {
                server: OwnedHandle(server),
                name,
            })
        }
    }

    fn connect(&self, access: DWORD) -> io::Result<File> {
        let client = unsafe {
            CreateFileW(
                self.name.as_ptr(),
                access,
                0,
                ptr::null_mut(),
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL,
                ptr::null_mut(),
            )
        };
        if client == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        let connected = unsafe { ConnectNamedPipe(self.server.0, ptr::null_mut()) };
        if connected == 0 && unsafe { GetLastError() } != ERROR_PIPE_CONNECTED {
            unsafe { CloseHandle(client) };
            return Err(io::Error::last_os_error());
        }
        Ok(unsafe { File::from_raw_handle(client.cast()) })
    }
}

struct DuplexPipe {
    server: OwnedHandle,
    client: OwnedHandle,
}

impl DuplexPipe {
    fn create() -> io::Result<Self> {
        nt_overlapped_pipe()
    }
}

struct OverlappedReader {
    handle: OwnedHandle,
    event: OwnedHandle,
    overlapped: OVERLAPPED,
    buffer: Vec<u8>,
    offset: usize,
    length: usize,
    pending: bool,
    eof: bool,
}

unsafe impl Send for OverlappedReader {}

impl OverlappedReader {
    fn new(handle: OwnedHandle) -> io::Result<Self> {
        let event = unsafe { CreateEventW(ptr::null_mut(), 1, 0, ptr::null()) };
        if event.is_null() {
            return Err(io::Error::last_os_error());
        }
        let mut reader = Self {
            handle,
            event: OwnedHandle(event),
            overlapped: unsafe { mem::zeroed() },
            buffer: vec![0; PIPE_BUFFER_SIZE as usize],
            offset: 0,
            length: 0,
            pending: false,
            eof: false,
        };
        reader.queue()?;
        Ok(reader)
    }

    fn queue(&mut self) -> io::Result<()> {
        if self.eof {
            return Ok(());
        }
        unsafe { ResetEvent(self.event.0) };
        self.overlapped = unsafe { mem::zeroed() };
        self.overlapped.hEvent = self.event.0;
        let mut read = 0;
        let result = unsafe {
            ReadFile(
                self.handle.0,
                self.buffer.as_mut_ptr().cast(),
                self.buffer.len() as DWORD,
                &mut read,
                &mut self.overlapped,
            )
        };
        if result != 0 {
            self.length = read as usize;
            self.offset = 0;
            self.pending = false;
            return Ok(());
        }
        match unsafe { GetLastError() } {
            ERROR_IO_PENDING => {
                self.pending = true;
                Ok(())
            }
            ERROR_BROKEN_PIPE => {
                self.eof = true;
                self.pending = false;
                Ok(())
            }
            _ => Err(io::Error::last_os_error()),
        }
    }

    fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        if output.is_empty() {
            return Ok(0);
        }
        if self.offset == self.length && self.pending {
            let mut read = 0;
            if unsafe { GetOverlappedResult(self.handle.0, &mut self.overlapped, &mut read, 1) }
                == 0
            {
                if unsafe { GetLastError() } == ERROR_BROKEN_PIPE {
                    self.eof = true;
                    self.pending = false;
                    return Ok(0);
                }
                return Err(io::Error::last_os_error());
            }
            self.length = read as usize;
            self.offset = 0;
            self.pending = false;
        }
        if self.offset == self.length {
            if self.eof {
                return Ok(0);
            }
            self.queue()?;
            return self.read(output);
        }
        let count = output.len().min(self.length - self.offset);
        output[..count].copy_from_slice(&self.buffer[self.offset..self.offset + count]);
        self.offset += count;
        if self.offset == self.length {
            // Match Windows Terminal: keep the next read pending while the
            // caller parses, snapshots, and posts the completed buffer.
            self.queue()?;
        }
        Ok(count)
    }
}

impl Drop for OverlappedReader {
    fn drop(&mut self) {
        unsafe { CancelIoEx(self.handle.0, &mut self.overlapped) };
    }
}

struct OverlappedWriter {
    handle: OwnedHandle,
    event: OwnedHandle,
}

unsafe impl Send for OverlappedWriter {}

impl OverlappedWriter {
    fn new(handle: OwnedHandle) -> io::Result<Self> {
        let event = unsafe { CreateEventW(ptr::null_mut(), 1, 0, ptr::null()) };
        if event.is_null() {
            Err(io::Error::last_os_error())
        } else {
            Ok(Self {
                handle,
                event: OwnedHandle(event),
            })
        }
    }

    fn write_all(&mut self, mut input: &[u8]) -> io::Result<()> {
        while !input.is_empty() {
            unsafe { ResetEvent(self.event.0) };
            let mut overlapped: OVERLAPPED = unsafe { mem::zeroed() };
            overlapped.hEvent = self.event.0;
            let mut written = 0;
            let result = unsafe {
                WriteFile(
                    self.handle.0,
                    input.as_ptr().cast(),
                    input.len().min(DWORD::MAX as usize) as DWORD,
                    &mut written,
                    &mut overlapped,
                )
            };
            if result == 0 {
                if unsafe { GetLastError() } != ERROR_IO_PENDING {
                    return Err(io::Error::last_os_error());
                }
                if unsafe { GetOverlappedResult(self.handle.0, &mut overlapped, &mut written, 1) }
                    == 0
                {
                    return Err(io::Error::last_os_error());
                }
            }
            if written == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "ConPTY input closed",
                ));
            }
            input = &input[written as usize..];
        }
        Ok(())
    }
}

fn duplicate_handle(handle: HANDLE) -> io::Result<OwnedHandle> {
    let mut duplicate = ptr::null_mut();
    let process = unsafe { GetCurrentProcess() };
    if unsafe {
        DuplicateHandle(
            process,
            handle,
            process,
            &mut duplicate,
            0,
            FALSE,
            DUPLICATE_SAME_ACCESS,
        )
    } == 0
    {
        Err(io::Error::last_os_error())
    } else {
        Ok(OwnedHandle(duplicate))
    }
}

#[repr(C)]
struct UnicodeString {
    length: u16,
    maximum_length: u16,
    buffer: *mut u16,
}

#[repr(C)]
struct ObjectAttributes {
    length: u32,
    root_directory: HANDLE,
    object_name: *mut UnicodeString,
    attributes: u32,
    security_descriptor: *mut c_void,
    security_quality_of_service: *mut c_void,
}

#[repr(C)]
struct IoStatusBlock {
    status: isize,
    information: usize,
}

#[link(name = "ntdll")]
unsafe extern "system" {
    fn NtCreateFile(
        file_handle: *mut HANDLE,
        desired_access: u32,
        object_attributes: *mut ObjectAttributes,
        io_status_block: *mut IoStatusBlock,
        allocation_size: *mut i64,
        file_attributes: u32,
        share_access: u32,
        create_disposition: u32,
        create_options: u32,
        ea_buffer: *mut c_void,
        ea_length: u32,
    ) -> i32;
    fn NtCreateNamedPipeFile(
        file_handle: *mut HANDLE,
        desired_access: u32,
        object_attributes: *mut ObjectAttributes,
        io_status_block: *mut IoStatusBlock,
        share_access: u32,
        create_disposition: u32,
        create_options: u32,
        named_pipe_type: u32,
        read_mode: u32,
        completion_mode: u32,
        maximum_instances: u32,
        inbound_quota: u32,
        outbound_quota: u32,
        default_timeout: *mut i64,
    ) -> i32;
}

fn nt_overlapped_pipe() -> io::Result<DuplexPipe> {
    const OBJ_CASE_INSENSITIVE: u32 = 0x40;
    const SYNCHRONIZE: u32 = 0x0010_0000;
    const FILE_SHARE_READ: u32 = 1;
    const FILE_SHARE_WRITE: u32 = 2;
    const FILE_OPEN: u32 = 1;
    const FILE_CREATE: u32 = 2;
    const FILE_SYNCHRONOUS_IO_NONALERT: u32 = 0x20;
    const FILE_NON_DIRECTORY_FILE: u32 = 0x40;

    fn pipe_directory() -> io::Result<&'static OwnedHandle> {
        static DIRECTORY: OnceLock<Result<OwnedHandle, (i32, String)>> = OnceLock::new();
        match DIRECTORY.get_or_init(|| {
            let mut path: Vec<u16> = OsStr::new(r"\Device\NamedPipe\").encode_wide().collect();
            let mut name = UnicodeString {
                length: (path.len() * 2) as u16,
                maximum_length: (path.len() * 2) as u16,
                buffer: path.as_mut_ptr(),
            };
            let mut attributes = ObjectAttributes {
                length: mem::size_of::<ObjectAttributes>() as u32,
                root_directory: ptr::null_mut(),
                object_name: &mut name,
                attributes: 0,
                security_descriptor: ptr::null_mut(),
                security_quality_of_service: ptr::null_mut(),
            };
            let mut status_block = IoStatusBlock {
                status: 0,
                information: 0,
            };
            let mut handle = ptr::null_mut();
            let status = unsafe {
                NtCreateFile(
                    &mut handle,
                    SYNCHRONIZE | GENERIC_READ,
                    &mut attributes,
                    &mut status_block,
                    ptr::null_mut(),
                    0,
                    FILE_SHARE_READ | FILE_SHARE_WRITE,
                    FILE_OPEN,
                    FILE_SYNCHRONOUS_IO_NONALERT,
                    ptr::null_mut(),
                    0,
                )
            };
            if status < 0 {
                Err((
                    status,
                    format!("NtCreateFile(pipe directory) failed: {status:#x}"),
                ))
            } else {
                Ok(OwnedHandle(handle))
            }
        }) {
            Ok(handle) => Ok(handle),
            Err((status, message)) => Err(io::Error::other(format!("{message} ({status})"))),
        }
    }

    let directory = pipe_directory()?;
    let mut empty_name = UnicodeString {
        length: 0,
        maximum_length: 0,
        buffer: ptr::null_mut(),
    };
    let mut attributes = ObjectAttributes {
        length: mem::size_of::<ObjectAttributes>() as u32,
        root_directory: directory.0,
        object_name: &mut empty_name,
        attributes: OBJ_CASE_INSENSITIVE,
        security_descriptor: ptr::null_mut(),
        security_quality_of_service: ptr::null_mut(),
    };
    let mut status_block = IoStatusBlock {
        status: 0,
        information: 0,
    };
    let mut server = ptr::null_mut();
    let mut timeout: i64 = -1_000_000_000;
    let status = unsafe {
        NtCreateNamedPipeFile(
            &mut server,
            SYNCHRONIZE | GENERIC_READ | GENERIC_WRITE,
            &mut attributes,
            &mut status_block,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            FILE_CREATE,
            0,
            0,
            0,
            0,
            1,
            PIPE_BUFFER_SIZE,
            PIPE_BUFFER_SIZE,
            &mut timeout,
        )
    };
    if status < 0 {
        return Err(io::Error::other(format!(
            "NtCreateNamedPipeFile failed with NTSTATUS {status:#x}"
        )));
    }
    let server = OwnedHandle(server);

    attributes.root_directory = server.0;
    let mut client = ptr::null_mut();
    let status = unsafe {
        NtCreateFile(
            &mut client,
            SYNCHRONIZE | GENERIC_READ | GENERIC_WRITE,
            &mut attributes,
            &mut status_block,
            ptr::null_mut(),
            0,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            FILE_OPEN,
            FILE_NON_DIRECTORY_FILE,
            ptr::null_mut(),
            0,
        )
    };
    if status < 0 {
        return Err(io::Error::other(format!(
            "NtCreateFile(pipe client) failed with NTSTATUS {status:#x}"
        )));
    }
    Ok(DuplexPipe {
        server,
        client: OwnedHandle(client),
    })
}

fn spawn_attached(
    conpty: HPCON,
    executable: &str,
    arguments: &[String],
    working_directory: Option<&Path>,
    environment: impl IntoIterator<Item = (String, String)>,
) -> io::Result<(OwnedHandle, u32)> {
    let mut attribute_bytes = 0usize;
    unsafe { InitializeProcThreadAttributeList(ptr::null_mut(), 1, 0, &mut attribute_bytes) };
    let mut attributes = vec![0u8; attribute_bytes];
    let attribute_list = attributes.as_mut_ptr().cast();
    if unsafe { InitializeProcThreadAttributeList(attribute_list, 1, 0, &mut attribute_bytes) } == 0
    {
        return Err(io::Error::last_os_error());
    }
    let attributes_guard = AttributeListGuard(attribute_list.cast());
    if unsafe {
        UpdateProcThreadAttribute(
            attribute_list,
            0,
            PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            conpty,
            mem::size_of::<HPCON>(),
            ptr::null_mut(),
            ptr::null_mut(),
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }

    let mut startup: STARTUPINFOEXW = unsafe { mem::zeroed() };
    startup.StartupInfo.cb = mem::size_of::<STARTUPINFOEXW>() as DWORD;
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = INVALID_HANDLE_VALUE;
    startup.StartupInfo.hStdOutput = INVALID_HANDLE_VALUE;
    startup.StartupInfo.hStdError = INVALID_HANDLE_VALUE;
    startup.lpAttributeList = attribute_list;

    let mut command_line = command_line(executable, arguments);
    let mut environment_block = environment_block(environment);
    let working_directory = working_directory.map(|path| wide_null(path.as_os_str()));
    let mut info: PROCESS_INFORMATION = unsafe { mem::zeroed() };
    let created = unsafe {
        CreateProcessW(
            ptr::null(),
            command_line.as_mut_ptr(),
            ptr::null_mut(),
            ptr::null_mut(),
            FALSE,
            EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
            environment_block.as_mut_ptr().cast(),
            working_directory
                .as_ref()
                .map_or(ptr::null(), |path| path.as_ptr()),
            &mut startup.StartupInfo,
            &mut info,
        )
    };
    drop(attributes_guard);
    if created == 0 {
        return Err(io::Error::last_os_error());
    }
    unsafe { CloseHandle(info.hThread) };
    Ok((OwnedHandle(info.hProcess), info.dwProcessId))
}

struct AttributeListGuard(*mut c_void);

impl Drop for AttributeListGuard {
    fn drop(&mut self) {
        unsafe { DeleteProcThreadAttributeList(self.0.cast()) };
    }
}

fn wide_null(value: impl AsRef<OsStr>) -> Vec<u16> {
    value.as_ref().encode_wide().chain(Some(0)).collect()
}

fn command_line(executable: &str, arguments: &[String]) -> Vec<u16> {
    let mut command = quote_argument(executable);
    for argument in arguments {
        command.push(' ');
        command.push_str(&quote_argument(argument));
    }
    wide_null(command)
}

fn quote_argument(value: &str) -> String {
    if !value.is_empty() && !value.chars().any(|ch| ch.is_whitespace() || ch == '"') {
        return value.to_owned();
    }
    let mut quoted = String::from("\"");
    let mut slashes = 0;
    for ch in value.chars() {
        if ch == '\\' {
            slashes += 1;
        } else {
            if ch == '"' {
                quoted.extend(std::iter::repeat_n('\\', slashes + 1));
            }
            quoted.extend(std::iter::repeat_n('\\', slashes));
            slashes = 0;
            quoted.push(ch);
        }
    }
    quoted.extend(std::iter::repeat_n('\\', slashes * 2));
    quoted.push('"');
    quoted
}

fn environment_block(overrides: impl IntoIterator<Item = (String, String)>) -> Vec<u16> {
    let mut values = BTreeMap::<String, (OsString, OsString)>::new();
    for (key, value) in std::env::vars_os() {
        values.insert(key.to_string_lossy().to_uppercase(), (key, value));
    }
    for (key, value) in overrides {
        values.insert(key.to_uppercase(), (key.into(), value.into()));
    }
    let mut block = Vec::new();
    for (_, (key, value)) in values {
        block.extend(key.encode_wide());
        block.push('=' as u16);
        block.extend(value.encode_wide());
        block.push(0);
    }
    block.push(0);
    block
}
