#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <Windows.h>

#include "flutter_pty.h"

#include "include/dart_api.h"
#include "include/dart_api_dl.h"
#include "include/dart_native_api.h"

// Keep Windows on the same high-throughput Rust PTY bridge as Unix.  The
// Rust core uses ConPTY on Windows, so this covers cmd/PowerShell as well as
// wsl.exe and distribution launchers without a separate WSL output path.
// 128 KiB read chunks match the sidecar pipe's NT buffer size so overlapped
// reads drain full batches without extra round trips.
#define PTY_READ_BUFFER_SIZE (128 * 1024)
#define PTY_RUST_READ_WINDOW 32

typedef struct SstermPtyCore SstermPtyCore;
typedef SstermPtyCore *(*RustPtyCreateFn)(const char *, const char *const *, size_t,
                                          const char *, const char *const *, size_t,
                                          uint16_t, uint16_t);
typedef void (*RustPtyDestroyFn)(SstermPtyCore *);
typedef int64_t (*RustPtyReadFn)(SstermPtyCore *, uint8_t *, size_t);
typedef int32_t (*RustPtyWriteFn)(SstermPtyCore *, const uint8_t *, size_t);
typedef int32_t (*RustPtyResizeFn)(SstermPtyCore *, uint16_t, uint16_t);
typedef int32_t (*RustPtyKillFn)(SstermPtyCore *);
typedef int32_t (*RustPtyWaitFn)(SstermPtyCore *, int32_t *);
typedef uint32_t (*RustPtyPidFn)(SstermPtyCore *);
typedef const char *(*RustPtyErrorFn)(void);

typedef struct RustPtyApi {
    HMODULE library;
    RustPtyCreateFn create;
    RustPtyDestroyFn destroy;
    RustPtyReadFn read;
    RustPtyWriteFn write;
    RustPtyResizeFn resize;
    RustPtyKillFn kill;
    RustPtyWaitFn wait;
    RustPtyPidFn pid;
    RustPtyErrorFn error;
} RustPtyApi;

static RustPtyApi rust_pty_api;
static INIT_ONCE rust_pty_api_once = INIT_ONCE_STATIC_INIT;

static HMODULE load_rust_pty_library(void)
{
    WCHAR path[MAX_PATH];
    DWORD length = GetModuleFileNameW(NULL, path, MAX_PATH);
    if (length == 0 || length >= MAX_PATH)
    {
        return NULL;
    }
    WCHAR *name = wcsrchr(path, L'\\');
    if (name == NULL)
    {
        return NULL;
    }
    const WCHAR library_name[] = L"ssterm_pty_core.dll";
    if ((size_t)(name - path) + 1 + _countof(library_name) > _countof(path))
    {
        return NULL;
    }
    wcscpy_s(name + 1, _countof(path) - (size_t)(name + 1 - path), library_name);
    return LoadLibraryW(path);
}

static BOOL CALLBACK load_rust_pty_api(PINIT_ONCE once, PVOID parameter, PVOID *context)
{
    (void)once;
    (void)parameter;
    (void)context;
    rust_pty_api.library = load_rust_pty_library();
    if (rust_pty_api.library == NULL)
    {
        return TRUE;
    }
    rust_pty_api.create = (RustPtyCreateFn)GetProcAddress(rust_pty_api.library, "ssterm_pty_create_with_environment");
    rust_pty_api.destroy = (RustPtyDestroyFn)GetProcAddress(rust_pty_api.library, "ssterm_pty_destroy");
    rust_pty_api.read = (RustPtyReadFn)GetProcAddress(rust_pty_api.library, "ssterm_pty_read");
    rust_pty_api.write = (RustPtyWriteFn)GetProcAddress(rust_pty_api.library, "ssterm_pty_write");
    rust_pty_api.resize = (RustPtyResizeFn)GetProcAddress(rust_pty_api.library, "ssterm_pty_resize");
    rust_pty_api.kill = (RustPtyKillFn)GetProcAddress(rust_pty_api.library, "ssterm_pty_kill");
    rust_pty_api.wait = (RustPtyWaitFn)GetProcAddress(rust_pty_api.library, "ssterm_pty_wait");
    rust_pty_api.pid = (RustPtyPidFn)GetProcAddress(rust_pty_api.library, "ssterm_pty_pid");
    rust_pty_api.error = (RustPtyErrorFn)GetProcAddress(rust_pty_api.library, "ssterm_pty_error");
    if (rust_pty_api.create == NULL || rust_pty_api.destroy == NULL ||
        rust_pty_api.read == NULL || rust_pty_api.write == NULL || rust_pty_api.resize == NULL ||
        rust_pty_api.kill == NULL || rust_pty_api.wait == NULL ||
        rust_pty_api.pid == NULL || rust_pty_api.error == NULL)
    {
        FreeLibrary(rust_pty_api.library);
        ZeroMemory(&rust_pty_api, sizeof(rust_pty_api));
    }
    return TRUE;
}

static BOOL use_rust_pty(void)
{
    const char *enabled = getenv("SSTERM_USE_RUST_PTY");
    if (enabled != NULL && strcmp(enabled, "0") == 0)
    {
        return FALSE;
    }
    InitOnceExecuteOnce(&rust_pty_api_once, load_rust_pty_api, NULL, NULL);
    return rust_pty_api.create != NULL;
}

static size_t string_vector_length(char **values)
{
    size_t length = 0;
    if (values == NULL) return 0;
    while (values[length] != NULL) length++;
    return length;
}

static int arg_needs_quotes(const char *arg)
{
    if (arg == NULL || arg[0] == '\0')
    {
        return 1;
    }

    for (const char *p = arg; *p != '\0'; p++)
    {
        if (*p == ' ' || *p == '\t' || *p == '"')
        {
            return 1;
        }
    }

    return 0;
}

static int append_bytes(char **buffer, int *length, int *capacity, const char *data, int data_len)
{
    if (data == NULL || data_len <= 0)
    {
        return 1;
    }

    if (*length + data_len + 1 > *capacity)
    {
        int new_capacity = *capacity == 0 ? 256 : *capacity;

        while (*length + data_len + 1 > new_capacity)
        {
            new_capacity *= 2;
        }

        char *resized = realloc(*buffer, new_capacity);

        if (resized == NULL)
        {
            return 0;
        }

        *buffer = resized;
        *capacity = new_capacity;
    }

    memcpy(*buffer + *length, data, data_len);
    *length += data_len;
    (*buffer)[*length] = '\0';
    return 1;
}

static int append_char(char **buffer, int *length, int *capacity, char ch)
{
    return append_bytes(buffer, length, capacity, &ch, 1);
}

static int append_cstring(char **buffer, int *length, int *capacity, const char *text)
{
    if (text == NULL)
    {
        return 1;
    }

    return append_bytes(buffer, length, capacity, text, (int)strlen(text));
}

static int append_quoted_token(
    char **buffer,
    int *length,
    int *capacity,
    const char *arg,
    int leading_space)
{
    if (arg == NULL)
    {
        return 1;
    }

    if (leading_space && !append_char(buffer, length, capacity, ' '))
    {
        return 0;
    }

    if (!arg_needs_quotes(arg))
    {
        return append_cstring(buffer, length, capacity, arg);
    }

    if (!append_char(buffer, length, capacity, '"'))
    {
        return 0;
    }

    int backslashes = 0;
    for (const char *p = arg; *p != '\0'; p++)
    {
        if (*p == '\\')
        {
            backslashes++;
            continue;
        }

        if (*p == '"')
        {
            for (int i = 0; i < backslashes * 2 + 1; i++)
            {
                if (!append_char(buffer, length, capacity, '\\'))
                {
                    return 0;
                }
            }
            backslashes = 0;
            if (!append_char(buffer, length, capacity, '"'))
            {
                return 0;
            }
            continue;
        }

        while (backslashes > 0)
        {
            if (!append_char(buffer, length, capacity, '\\'))
            {
                return 0;
            }
            backslashes--;
        }
        if (!append_char(buffer, length, capacity, *p))
        {
            return 0;
        }
    }

    while (backslashes > 0)
    {
        if (!append_char(buffer, length, capacity, '\\') ||
            !append_char(buffer, length, capacity, '\\'))
        {
            return 0;
        }
        backslashes--;
    }

    return append_char(buffer, length, capacity, '"');
}

static LPWSTR build_command(char *executable, char **arguments)
{
    char *utf8_command = NULL;
    int length = 0;
    int capacity = 0;

    if (executable != NULL)
    {
        if (!append_quoted_token(&utf8_command, &length, &capacity, executable, 0))
        {
            free(utf8_command);
            return NULL;
        }
    }

    if (arguments != NULL)
    {
        // Dart builds argv execvp-style: arguments[0] is the executable.
        // Do not duplicate it — otherwise WSL/Git Bash receive the Windows
        // exe path as a command to run inside the Linux/MSYS session.
        int i = 0;
        if (arguments[0] != NULL && executable != NULL &&
            strcmp(arguments[0], executable) == 0)
        {
            i = 1;
        }

        while (arguments[i] != NULL)
        {
            if (!append_quoted_token(
                    &utf8_command, &length, &capacity, arguments[i], 1))
            {
                free(utf8_command);
                return NULL;
            }

            i++;
        }
    }

    if (utf8_command == NULL)
    {
        utf8_command = malloc(1);

        if (utf8_command == NULL)
        {
            return NULL;
        }

        utf8_command[0] = '\0';
    }

    int wlen = MultiByteToWideChar(CP_UTF8, 0, utf8_command, -1, NULL, 0);
    LPWSTR command = malloc(wlen * sizeof(WCHAR));

    if (command != NULL)
    {
        MultiByteToWideChar(CP_UTF8, 0, utf8_command, -1, command, wlen);
    }

    free(utf8_command);

    return command;
}

static LPWSTR build_environment(char **environment)
{
    if (environment == NULL)
    {
        LPWSTR empty = malloc(2 * sizeof(WCHAR));
        if (empty != NULL)
        {
            empty[0] = 0;
            empty[1] = 0;
        }
        return empty;
    }

    int total_wlen = 0;
    int i = 0;

    while (environment[i] != NULL)
    {
        total_wlen += MultiByteToWideChar(CP_UTF8, 0, environment[i], -1, NULL, 0);
        i++;
    }
    total_wlen += 1;

    LPWSTR environment_block = malloc(total_wlen * sizeof(WCHAR));

    if (environment_block == NULL)
    {
        return NULL;
    }

    int pos = 0;
    i = 0;

    while (environment[i] != NULL)
    {
        int wlen = MultiByteToWideChar(CP_UTF8, 0, environment[i], -1, environment_block + pos, total_wlen - pos);
        pos += wlen;
        i++;
    }

    environment_block[pos] = 0;

    return environment_block;
}

static LPWSTR build_working_directory(char *working_directory)
{
    if (working_directory == NULL)
    {
        return NULL;
    }

    int wlen = MultiByteToWideChar(CP_UTF8, 0, working_directory, -1, NULL, 0);
    LPWSTR working_directory_block = malloc(wlen * sizeof(WCHAR));

    if (working_directory_block == NULL)
    {
        return NULL;
    }

    MultiByteToWideChar(CP_UTF8, 0, working_directory, -1, working_directory_block, wlen);

    return working_directory_block;
}

typedef struct ReadLoopOptions
{
    HANDLE fd;

    SstermPtyCore *rust_pty;

    BOOL uses_rust;

    Dart_Port port;

    HANDLE hMutex;

    BOOL ackRead;

    CRITICAL_SECTION *rust_ack_lock;

    CONDITION_VARIABLE *rust_ack_condition;

    size_t *rust_read_credits;

    BOOL *rust_read_stopping;

} ReadLoopOptions;

static DWORD WINAPI read_loop(LPVOID arg)
{
    ReadLoopOptions *options = (ReadLoopOptions *)arg;

    char buffer[PTY_READ_BUFFER_SIZE];

    while (1)
    {
        DWORD readlen = 0;

        if (options->ackRead)
        {
            if (options->uses_rust)
            {
                EnterCriticalSection(options->rust_ack_lock);
                while (*options->rust_read_credits == 0 && !*options->rust_read_stopping)
                {
                    SleepConditionVariableCS(options->rust_ack_condition,
                                             options->rust_ack_lock, INFINITE);
                }
                if (*options->rust_read_stopping)
                {
                    LeaveCriticalSection(options->rust_ack_lock);
                    break;
                }
                (*options->rust_read_credits)--;
                LeaveCriticalSection(options->rust_ack_lock);
            }
            else
            {
                WaitForSingleObject(options->hMutex, INFINITE);
            }
        }

        BOOL ok;
        if (options->uses_rust)
        {
            int64_t count = rust_pty_api.read(options->rust_pty, (uint8_t *)buffer, sizeof(buffer));
            if (count <= 0)
            {
                break;
            }
            readlen = (DWORD)count;
            ok = TRUE;
        }
        else
        {
            ok = ReadFile(options->fd, buffer, sizeof(buffer), &readlen, NULL);
        }

        if (!ok)
        {
            break;
        }

        if (readlen <= 0)
        {
            break;
        }

        Dart_CObject result;
        result.type = Dart_CObject_kTypedData;
        result.value.as_typed_data.type = Dart_TypedData_kUint8;
        result.value.as_typed_data.length = readlen;
        result.value.as_typed_data.values = (uint8_t *)buffer;

        Dart_PostCObject_DL(options->port, &result);
    }

    free(options);
    return 0;
}

static BOOL start_read_thread(HANDLE fd, SstermPtyCore *rust_pty, BOOL uses_rust,
                              Dart_Port port, HANDLE mutex, BOOL ackRead,
                              CRITICAL_SECTION *rust_ack_lock,
                              CONDITION_VARIABLE *rust_ack_condition,
                              size_t *rust_read_credits,
                              BOOL *rust_read_stopping,
                              HANDLE *thread_out)
{
    ReadLoopOptions *options = malloc(sizeof(ReadLoopOptions));

    if (options == NULL) return FALSE;

    options->fd = fd;
    options->rust_pty = rust_pty;
    options->uses_rust = uses_rust;
    options->port = port;
    options->hMutex = mutex;
    options->ackRead = ackRead;
    options->rust_ack_lock = rust_ack_lock;
    options->rust_ack_condition = rust_ack_condition;
    options->rust_read_credits = rust_read_credits;
    options->rust_read_stopping = rust_read_stopping;

    DWORD thread_id;

    HANDLE thread = CreateThread(NULL, 0, read_loop, options, 0, &thread_id);

    if (thread == NULL)
    {
        free(options);
        return FALSE;
    }
    *thread_out = thread;
    return TRUE;
}

typedef struct WaitExitOptions
{
    HANDLE pid;

    SstermPtyCore *rust_pty;

    BOOL uses_rust;

    Dart_Port port;

    HANDLE hMutex;
} WaitExitOptions;

static DWORD WINAPI wait_exit_thread(LPVOID arg)
{
    WaitExitOptions *options = (WaitExitOptions *)arg;

    if (options->uses_rust)
    {
        int32_t exit_code = -1;
        if (rust_pty_api.wait(options->rust_pty, &exit_code) == 0)
        {
            Dart_PostInteger_DL(options->port, exit_code);
        }
    }
    else
    {
        DWORD exit_code = 0;
        WaitForSingleObject(options->pid, INFINITE);
        GetExitCodeProcess(options->pid, &exit_code);
        CloseHandle(options->pid);
        CloseHandle(options->hMutex);
        Dart_PostInteger_DL(options->port, exit_code);
    }

    free(options);
    return 0;
}

static BOOL start_wait_exit_thread(HANDLE pid, SstermPtyCore *rust_pty, BOOL uses_rust,
                                   Dart_Port port, HANDLE mutex, HANDLE *thread_out)
{
    WaitExitOptions *options = malloc(sizeof(WaitExitOptions));

    if (options == NULL) return FALSE;

    options->pid = pid;
    options->rust_pty = rust_pty;
    options->uses_rust = uses_rust;
    options->port = port;
    options->hMutex = mutex;

    DWORD thread_id;

    HANDLE thread = CreateThread(NULL, 0, wait_exit_thread, options, 0, &thread_id);

    if (thread == NULL)
    {
        free(options);
        return FALSE;
    }
    *thread_out = thread;
    return TRUE;
}

typedef struct PtyHandle
{
    HANDLE inputWriteSide;

    HANDLE outputReadSide;

    HPCON hPty;

    DWORD dwProcessId;

    BOOL ackRead;

    HANDLE hMutex;

    SstermPtyCore *rust_pty;

    BOOL uses_rust;

    HANDLE rust_read_thread;

    HANDLE rust_wait_thread;

    CRITICAL_SECTION rust_ack_lock;

    CONDITION_VARIABLE rust_ack_condition;

    size_t rust_read_credits;

    BOOL rust_read_stopping;

} PtyHandle;

static __declspec(thread) char error_buffer[1024];
static __declspec(thread) BOOL has_error = FALSE;

static void set_rust_error_message(const char *message)
{
    if (message == NULL || message[0] == '\0')
    {
        message = "Rust PTY operation failed";
    }
    snprintf(error_buffer, sizeof(error_buffer), "%s", message);
    has_error = TRUE;
}

static void set_windows_error(const char *stage, DWORD code)
{
    WCHAR wide_message[512] = {0};
    char utf8_message[768] = {0};
    DWORD length = FormatMessageW(
        FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        NULL,
        code,
        0,
        wide_message,
        (DWORD)(sizeof(wide_message) / sizeof(wide_message[0])),
        NULL);

    while (length > 0 && (wide_message[length - 1] == L'\r' ||
                          wide_message[length - 1] == L'\n' ||
                          wide_message[length - 1] == L' '))
    {
        wide_message[--length] = L'\0';
    }

    if (length > 0)
    {
        WideCharToMultiByte(
            CP_UTF8,
            0,
            wide_message,
            -1,
            utf8_message,
            (int)sizeof(utf8_message),
            NULL,
            NULL);
    }

    if (utf8_message[0] != '\0')
    {
        snprintf(error_buffer, sizeof(error_buffer),
                 "%s (Windows error %lu: %s)", stage,
                 (unsigned long)code, utf8_message);
    }
    else
    {
        snprintf(error_buffer, sizeof(error_buffer),
                 "%s (Windows error %lu)", stage, (unsigned long)code);
    }
    has_error = TRUE;
}

static void set_hresult_error(const char *stage, HRESULT result)
{
    DWORD message_code = HRESULT_FACILITY(result) == FACILITY_WIN32
        ? HRESULT_CODE(result)
        : (DWORD)result;
    WCHAR wide_message[512] = {0};
    char utf8_message[768] = {0};
    DWORD length = FormatMessageW(
        FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        NULL,
        message_code,
        0,
        wide_message,
        (DWORD)(sizeof(wide_message) / sizeof(wide_message[0])),
        NULL);

    while (length > 0 && (wide_message[length - 1] == L'\r' ||
                          wide_message[length - 1] == L'\n' ||
                          wide_message[length - 1] == L' '))
    {
        wide_message[--length] = L'\0';
    }
    if (length > 0)
    {
        WideCharToMultiByte(
            CP_UTF8, 0, wide_message, -1, utf8_message,
            (int)sizeof(utf8_message), NULL, NULL);
    }

    if (utf8_message[0] != '\0')
    {
        snprintf(error_buffer, sizeof(error_buffer),
                 "%s (HRESULT 0x%08lX: %s)", stage,
                 (unsigned long)(DWORD)result, utf8_message);
    }
    else
    {
        snprintf(error_buffer, sizeof(error_buffer),
                 "%s (HRESULT 0x%08lX)", stage,
                 (unsigned long)(DWORD)result);
    }
    has_error = TRUE;
}

FFI_PLUGIN_EXPORT PtyHandle *pty_create(PtyOptions *options)
{
    has_error = FALSE;
    if (use_rust_pty())
    {
        const size_t argument_count = string_vector_length(options->arguments);
        const size_t environment_count = string_vector_length(options->environment);
        const char *const *arguments = argument_count == 0
                                           ? NULL
                                           : (const char *const *)(options->arguments + 1);
        const size_t rust_argument_count = argument_count == 0 ? 0 : argument_count - 1;
        SstermPtyCore *rust_pty = rust_pty_api.create(
            options->executable, arguments, rust_argument_count,
            options->working_directory,
            (const char *const *)options->environment, environment_count,
            (uint16_t)options->cols, (uint16_t)options->rows);
        if (rust_pty == NULL)
        {
            set_rust_error_message(rust_pty_api.error());
            return NULL;
        }
        // The Rust core opens the pseudoconsole without
        // PSEUDOCONSOLE_INHERIT_CURSOR, so ConPTY never issues its startup
        // cursor-position query and no reply is required here.

        PtyHandle *handle = calloc(1, sizeof(PtyHandle));
        if (handle == NULL)
        {
            rust_pty_api.destroy(rust_pty);
            set_rust_error_message("Unable to allocate Rust PTY handle");
            return NULL;
        }
        handle->rust_pty = rust_pty;
        handle->uses_rust = TRUE;
        handle->dwProcessId = rust_pty_api.pid(rust_pty);
        handle->ackRead = options->ackRead;
        InitializeCriticalSection(&handle->rust_ack_lock);
        InitializeConditionVariable(&handle->rust_ack_condition);
        handle->rust_read_credits = PTY_RUST_READ_WINDOW;

        if (!start_read_thread(NULL, rust_pty, TRUE, options->stdout_port,
                               NULL, options->ackRead, &handle->rust_ack_lock,
                               &handle->rust_ack_condition, &handle->rust_read_credits,
                               &handle->rust_read_stopping, &handle->rust_read_thread) ||
            !start_wait_exit_thread(NULL, rust_pty, TRUE, options->exit_port,
                                    NULL, &handle->rust_wait_thread))
        {
            EnterCriticalSection(&handle->rust_ack_lock);
            handle->rust_read_stopping = TRUE;
            WakeAllConditionVariable(&handle->rust_ack_condition);
            LeaveCriticalSection(&handle->rust_ack_lock);
            rust_pty_api.kill(rust_pty);
            if (handle->rust_read_thread != NULL)
            {
                WaitForSingleObject(handle->rust_read_thread, INFINITE);
                CloseHandle(handle->rust_read_thread);
            }
            if (handle->rust_wait_thread != NULL)
            {
                // The child has been killed above, so this wait is bounded by
                // process termination and cannot leave the Rust handle live.
                WaitForSingleObject(handle->rust_wait_thread, INFINITE);
                CloseHandle(handle->rust_wait_thread);
            }
            rust_pty_api.destroy(rust_pty);
            DeleteCriticalSection(&handle->rust_ack_lock);
            free(handle);
            set_rust_error_message("Unable to start Rust PTY bridge threads");
            return NULL;
        }
        return handle;
    }

    HANDLE inputReadSide = NULL;
    HANDLE inputWriteSide = NULL;
    HANDLE outputReadSide = NULL;
    HANDLE outputWriteSide = NULL;
    HPCON hPty = NULL;
    PPROC_THREAD_ATTRIBUTE_LIST lpAttributeList = NULL;
    HANDLE mutex = NULL;
    PtyHandle *pty = NULL;

    PROCESS_INFORMATION processInfo;
    ZeroMemory(&processInfo, sizeof(processInfo));

    LPWSTR command = NULL;
    LPWSTR environment_block = NULL;
    LPWSTR working_directory = NULL;

    // --- create pipes ---
    if (!CreatePipe(&inputReadSide, &inputWriteSide, NULL, 0))
    {
        set_windows_error("CreatePipe(input) failed", GetLastError());
        goto cleanup;
    }

    if (!CreatePipe(&outputReadSide, &outputWriteSide, NULL, 0))
    {
        set_windows_error("CreatePipe(output) failed", GetLastError());
        goto cleanup;
    }

    // --- create pseudo console ---
    COORD size;
    size.X = options->cols;
    size.Y = options->rows;

    HRESULT result = CreatePseudoConsole(size, inputReadSide, outputWriteSide, 0, &hPty);

    if (FAILED(result))
    {
        set_hresult_error("CreatePseudoConsole failed", result);
        goto cleanup;
    }

    // --- proc thread attribute list ---
    STARTUPINFOEX startupInfo;
    ZeroMemory(&startupInfo, sizeof(startupInfo));
    startupInfo.StartupInfo.cb = sizeof(startupInfo);

    startupInfo.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startupInfo.StartupInfo.hStdInput = NULL;
    startupInfo.StartupInfo.hStdOutput = NULL;
    startupInfo.StartupInfo.hStdError = NULL;

    SIZE_T bytesRequired;
    InitializeProcThreadAttributeList(NULL, 1, 0, &bytesRequired);
    lpAttributeList = (PPROC_THREAD_ATTRIBUTE_LIST)malloc(bytesRequired);

    if (lpAttributeList == NULL)
    {
        set_windows_error(
            "Allocating process attribute list failed",
            ERROR_NOT_ENOUGH_MEMORY);
        goto cleanup;
    }

    if (!InitializeProcThreadAttributeList(lpAttributeList, 1, 0, &bytesRequired))
    {
        set_windows_error(
            "InitializeProcThreadAttributeList failed",
            GetLastError());
        goto cleanup;
    }
    startupInfo.lpAttributeList = lpAttributeList;

    if (!UpdateProcThreadAttribute(lpAttributeList,
                                   0,
                                   PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                   hPty,
                                   sizeof(hPty),
                                   NULL,
                                   NULL))
    {
        set_windows_error("UpdateProcThreadAttribute failed", GetLastError());
        goto cleanup;
    }

    // --- build command / env / cwd strings ---
    command = build_command(options->executable, options->arguments);
    environment_block = build_environment(options->environment);
    working_directory = build_working_directory(options->working_directory);

    // --- create process ---
    BOOL ok = CreateProcessW(NULL,
                             command,
                             NULL,
                             NULL,
                             FALSE,
                             EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
                             environment_block,
                             working_directory,
                             &startupInfo.StartupInfo,
                             &processInfo);

    free(command);
    command = NULL;
    free(environment_block);
    environment_block = NULL;
    free(working_directory);
    working_directory = NULL;

    if (!ok)
    {
        set_windows_error("CreateProcessW failed", GetLastError());
        goto cleanup;
    }

    // --- success path: wire up read/wait threads ---
    DeleteProcThreadAttributeList(lpAttributeList);
    free(lpAttributeList);
    lpAttributeList = NULL;
    CloseHandle(processInfo.hThread);
    processInfo.hThread = NULL;
    CloseHandle(inputReadSide);
    inputReadSide = NULL;
    CloseHandle(outputWriteSide);
    outputWriteSide = NULL;

    pty = malloc(sizeof(PtyHandle));

    if (pty == NULL)
    {
        set_windows_error("Allocating PTY handle failed", ERROR_NOT_ENOUGH_MEMORY);
        goto cleanup;
    }

    mutex = CreateSemaphore(NULL, 1, 1, NULL);
    if (mutex == NULL)
    {
        set_windows_error("CreateSemaphore failed", GetLastError());
        goto cleanup;
    }

    // The legacy path never joins these threads; closing the handles right
    // away simply drops our reference while the threads keep running.
    HANDLE ignored_read_thread = NULL;
    start_read_thread(outputReadSide, NULL, FALSE, options->stdout_port, mutex,
                      options->ackRead, NULL, NULL, NULL, NULL,
                      &ignored_read_thread);
    if (ignored_read_thread != NULL)
    {
        CloseHandle(ignored_read_thread);
    }
    HANDLE ignored_wait_thread = NULL;
    start_wait_exit_thread(processInfo.hProcess, NULL, FALSE, options->exit_port,
                           mutex, &ignored_wait_thread);
    if (ignored_wait_thread != NULL)
    {
        CloseHandle(ignored_wait_thread);
    }

    pty->inputWriteSide = inputWriteSide;
    pty->outputReadSide = outputReadSide;
    pty->hPty = hPty;
    pty->dwProcessId = processInfo.dwProcessId;
    pty->ackRead = options->ackRead;
    pty->hMutex = mutex;
    pty->uses_rust = FALSE;

    return pty;

cleanup:
    // Close all resources that were successfully created and not yet
    // transferred to the PtyHandle.  Handles that were closed and NULL-ed
    // on the success path are skipped by the NULL checks below.
    if (inputReadSide != NULL)   CloseHandle(inputReadSide);
    if (inputWriteSide != NULL)  CloseHandle(inputWriteSide);
    if (outputReadSide != NULL)  CloseHandle(outputReadSide);
    if (outputWriteSide != NULL) CloseHandle(outputWriteSide);
    if (hPty != NULL)            ClosePseudoConsole(hPty);
    if (lpAttributeList != NULL)
    {
        DeleteProcThreadAttributeList(lpAttributeList);
        free(lpAttributeList);
    }
    if (processInfo.hThread != NULL)  CloseHandle(processInfo.hThread);
    if (processInfo.hProcess != NULL) CloseHandle(processInfo.hProcess);
    if (mutex != NULL)                CloseHandle(mutex);
    free(command);
    free(environment_block);
    free(working_directory);
    free(pty);
    return NULL;
}

static DWORD WINAPI close_pseudo_console_thread(LPVOID arg)
{
    ClosePseudoConsole((HPCON)arg);
    return 0;
}

static DWORD WINAPI destroy_rust_pty_thread(LPVOID arg)
{
    PtyHandle *handle = (PtyHandle *)arg;

    // Rust owns the ConPTY handles.  Its reader and waiter must be finished
    // before the opaque owner is destroyed, but this worker is never the
    // Flutter platform thread.  For WSL, a slow relay can therefore only
    // retain this worker, never freeze tab close or application shutdown.
    WaitForSingleObject(handle->rust_read_thread, INFINITE);
    WaitForSingleObject(handle->rust_wait_thread, INFINITE);
    CloseHandle(handle->rust_read_thread);
    CloseHandle(handle->rust_wait_thread);
    rust_pty_api.destroy(handle->rust_pty);
    DeleteCriticalSection(&handle->rust_ack_lock);
    free(handle);
    return 0;
}

// The actual teardown work, run entirely on a plain native thread (never a
// Dart isolate -- see pty_destroy's comment for why that distinction matters).
static DWORD WINAPI destroy_thread(LPVOID arg)
{
    PtyHandle *handle = (PtyHandle *)arg;

    CloseHandle(handle->inputWriteSide);

    // Unblock read_loop's ReadFile before tearing down the console.
    CloseHandle(handle->outputReadSide);

    // Terminate the shell before ClosePseudoConsole.  Dart-side Pty.kill()
    // usually does this first, but if the process is still alive
    // ClosePseudoConsole blocks the calling thread until every attached
    // process exits — freezing the Flutter UI on Windows.
    HANDLE hProcess = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, handle->dwProcessId);
    if (hProcess != NULL)
    {
        TerminateProcess(hProcess, 1);
        WaitForSingleObject(hProcess, 5000);
        CloseHandle(hProcess);
    }

    // For WSL-backed shells, dwProcessId is the `wsl.exe`/`ubuntu.exe`
    // launcher, not the process actually attached to the pseudoconsole (the
    // real session lives inside the WSL VM and is relayed by a separate,
    // outlasting helper process). TerminateProcess above kills the launcher
    // but the relay can keep the console attached, so ClosePseudoConsole can
    // block forever. Run it on its own thread too and give up after a
    // bounded wait; on timeout the pseudoconsole handle is intentionally
    // leaked rather than risking another hang.
    HANDLE closeThread = CreateThread(NULL, 0, close_pseudo_console_thread, handle->hPty, 0, NULL);
    if (closeThread != NULL)
    {
        WaitForSingleObject(closeThread, 3000);
        CloseHandle(closeThread);
    }

    free(handle);
    return 0;
}

FFI_PLUGIN_EXPORT void pty_destroy(PtyHandle *handle)
{
    if (handle == NULL)
    {
        return;
    }

    if (handle->uses_rust)
    {
        EnterCriticalSection(&handle->rust_ack_lock);
        handle->rust_read_stopping = TRUE;
        WakeAllConditionVariable(&handle->rust_ack_condition);
        LeaveCriticalSection(&handle->rust_ack_lock);
        rust_pty_api.kill(handle->rust_pty);

        HANDLE thread = CreateThread(NULL, 0, destroy_rust_pty_thread, handle, 0, NULL);
        if (thread != NULL)
        {
            CloseHandle(thread);
        }
        // Do not free a live handle if worker creation fails. The process has
        // already been terminated; retaining this small owner is safer than
        // racing its blocking bridge threads.
        return;
    }

    // Hand the whole teardown off to a plain Win32 thread and return
    // immediately. This call USED to run on a throwaway Dart isolate
    // (`Isolate.run`/`Isolate.spawn`) so the slow steps below wouldn't block
    // the caller -- but any Dart isolate spawned or messaged at the exact
    // moment the app's window is closing races the engine's own isolate-group
    // shutdown (which waits for every isolate in the group to fully
    // terminate) and can hang the whole process forever, reproducibly, once
    // a WSL tab is open. A plain native thread isn't part of that isolate
    // bookkeeping at all, so it can't race it. Making this call itself
    // return near-instantly means the Dart side no longer needs an isolate
    // hop to stay non-blocking either.
    HANDLE thread = CreateThread(NULL, 0, destroy_thread, handle, 0, NULL);
    if (thread != NULL)
    {
        CloseHandle(thread);
    }
    else
    {
        free(handle);
    }
}

FFI_PLUGIN_EXPORT void pty_write(PtyHandle *handle, char *buffer, int length)
{
    if (handle != NULL && handle->uses_rust)
    {
        if (length >= 0)
        {
            rust_pty_api.write(handle->rust_pty, (const uint8_t *)buffer, (size_t)length);
        }
        return;
    }
    DWORD bytesWritten;

    WriteFile(handle->inputWriteSide, buffer, length, &bytesWritten, NULL);

    FlushFileBuffers(handle->inputWriteSide);

    return;
}

FFI_PLUGIN_EXPORT void pty_ack_read(PtyHandle *handle)
{
    if (handle == NULL)
    {
        return;
    }
    if (handle->ackRead)
    {
        if (handle->uses_rust)
        {
            EnterCriticalSection(&handle->rust_ack_lock);
            if (handle->rust_read_credits < PTY_RUST_READ_WINDOW)
            {
                handle->rust_read_credits++;
                WakeConditionVariable(&handle->rust_ack_condition);
            }
            LeaveCriticalSection(&handle->rust_ack_lock);
        }
        else
        {
            ReleaseSemaphore(handle->hMutex, 1, NULL);
        }
    }
}

FFI_PLUGIN_EXPORT int pty_resize(PtyHandle *handle, int rows, int cols)
{
    if (handle != NULL && handle->uses_rust)
    {
        return rust_pty_api.resize(handle->rust_pty, (uint16_t)cols, (uint16_t)rows);
    }
    COORD size;

    size.X = cols;
    size.Y = rows;

    return ResizePseudoConsole(handle->hPty, size);
}

FFI_PLUGIN_EXPORT int pty_getpid(PtyHandle *handle)
{
    return (int)handle->dwProcessId;
}

FFI_PLUGIN_EXPORT char *pty_error()
{
    return has_error ? error_buffer : NULL;
}

typedef struct JobHandle
{
    HANDLE handle;
} JobHandle;

FFI_PLUGIN_EXPORT JobHandle *job_create_kill_on_close(void)
{
    HANDLE job = CreateJobObjectW(NULL, NULL);
    if (job == NULL)
    {
        return NULL;
    }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = {0};
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformation,
            &info,
            sizeof(info)))
    {
        CloseHandle(job);
        return NULL;
    }
    JobHandle *result = calloc(1, sizeof(JobHandle));
    if (result == NULL)
    {
        CloseHandle(job);
        return NULL;
    }
    result->handle = job;
    return result;
}

FFI_PLUGIN_EXPORT int job_assign_pid(JobHandle *handle, int pid)
{
    if (handle == NULL || handle->handle == NULL)
        return ERROR_INVALID_HANDLE;
    HANDLE process = OpenProcess(
        PROCESS_SET_QUOTA | PROCESS_TERMINATE,
        FALSE,
        (DWORD)pid);
    if (process == NULL)
        return (int)GetLastError();
    BOOL ok = AssignProcessToJobObject(handle->handle, process);
    DWORD error = ok ? ERROR_SUCCESS : GetLastError();
    CloseHandle(process);
    return (int)error;
}

FFI_PLUGIN_EXPORT int job_terminate(JobHandle *handle)
{
    if (handle == NULL || handle->handle == NULL)
        return ERROR_INVALID_HANDLE;
    return TerminateJobObject(handle->handle, 1) ? ERROR_SUCCESS : (int)GetLastError();
}

FFI_PLUGIN_EXPORT void job_close(JobHandle *handle)
{
    if (handle == NULL)
        return;
    if (handle->handle != NULL)
        CloseHandle(handle->handle);
    free(handle);
}
