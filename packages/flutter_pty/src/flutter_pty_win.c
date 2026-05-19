#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <Windows.h>

#include "flutter_pty.h"

#include "include/dart_api.h"
#include "include/dart_api_dl.h"
#include "include/dart_native_api.h"

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

    Dart_Port port;

    HANDLE hMutex;

    BOOL ackRead;

} ReadLoopOptions;

static DWORD WINAPI read_loop(LPVOID arg)
{
    ReadLoopOptions *options = (ReadLoopOptions *)arg;

    char buffer[1024];

    while (1)
    {
        DWORD readlen = 0;

        if (options->ackRead)
        {
            WaitForSingleObject(options->hMutex, INFINITE);
        }

        BOOL ok = ReadFile(options->fd, buffer, sizeof(buffer), &readlen, NULL);

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

    return 0;
}

static void start_read_thread(HANDLE fd, Dart_Port port, HANDLE mutex, BOOL ackRead)
{
    ReadLoopOptions *options = malloc(sizeof(ReadLoopOptions));

    options->fd = fd;
    options->port = port;
    options->hMutex = mutex;
    options->ackRead = ackRead;

    DWORD thread_id;

    HANDLE thread = CreateThread(NULL, 0, read_loop, options, 0, &thread_id);

    if (thread == NULL)
    {
        free(options);
    }
}

typedef struct WaitExitOptions
{
    HANDLE pid;

    Dart_Port port;

    HANDLE hMutex;
} WaitExitOptions;

static DWORD WINAPI wait_exit_thread(LPVOID arg)
{
    WaitExitOptions *options = (WaitExitOptions *)arg;

    DWORD exit_code = 0;

    WaitForSingleObject(options->pid, INFINITE);

    GetExitCodeProcess(options->pid, &exit_code);

    CloseHandle(options->pid);
    CloseHandle(options->hMutex);

    Dart_PostInteger_DL(options->port, exit_code);

    return 0;
}

static void start_wait_exit_thread(HANDLE pid, Dart_Port port, HANDLE mutex)
{
    WaitExitOptions *options = malloc(sizeof(WaitExitOptions));

    options->pid = pid;
    options->port = port;
    options->hMutex = mutex;

    DWORD thread_id;

    HANDLE thread = CreateThread(NULL, 0, wait_exit_thread, options, 0, &thread_id);

    if (thread == NULL)
    {
        free(options);
    }
}

typedef struct PtyHandle
{
    PHANDLE inputWriteSide;

    PHANDLE outputReadSide;

    HPCON hPty;

    DWORD dwProcessId;

    BOOL ackRead;

    HANDLE hMutex;

} PtyHandle;

char *error_message = NULL;

FFI_PLUGIN_EXPORT PtyHandle *pty_create(PtyOptions *options)
{
    HANDLE inputReadSide = NULL;
    HANDLE inputWriteSide = NULL;

    HANDLE outputReadSide = NULL;
    HANDLE outputWriteSide = NULL;

    if (!CreatePipe(&inputReadSide, &inputWriteSide, NULL, 0))
    {
        error_message = "Failed to create input pipe";
        return NULL;
    }

    if (!CreatePipe(&outputReadSide, &outputWriteSide, NULL, 0))
    {
        error_message = "Failed to create output pipe";
        return NULL;
    }

    COORD size;

    size.X = options->cols;
    size.Y = options->rows;

    HPCON hPty;

    HRESULT result = CreatePseudoConsole(size, inputReadSide, outputWriteSide, 0, &hPty);

    if (FAILED(result))
    {
        error_message = "Failed to create pseudo console";
        return NULL;
    }

    STARTUPINFOEX startupInfo;

    ZeroMemory(&startupInfo, sizeof(startupInfo));
    startupInfo.StartupInfo.cb = sizeof(startupInfo);

    startupInfo.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startupInfo.StartupInfo.hStdInput = NULL;
    startupInfo.StartupInfo.hStdOutput = NULL;
    startupInfo.StartupInfo.hStdError = NULL;

    SIZE_T bytesRequired;
    InitializeProcThreadAttributeList(NULL, 1, 0, &bytesRequired);
    startupInfo.lpAttributeList = (PPROC_THREAD_ATTRIBUTE_LIST)malloc(bytesRequired);

    BOOL ok = InitializeProcThreadAttributeList(startupInfo.lpAttributeList, 1, 0, &bytesRequired);

    if (!ok)
    {
        error_message = "Failed to initialize proc thread attribute list";
        return NULL;
    }

    ok = UpdateProcThreadAttribute(startupInfo.lpAttributeList,
                                   0,
                                   PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                   hPty,
                                   sizeof(hPty),
                                   NULL,
                                   NULL);

    if (!ok)
    {
        error_message = "Failed to update proc thread attribute list";
        return NULL;
    }

    LPWSTR command = build_command(options->executable, options->arguments);

    LPWSTR environment_block = build_environment(options->environment);

    LPWSTR working_directory = build_working_directory(options->working_directory);

    PROCESS_INFORMATION processInfo;
    ZeroMemory(&processInfo, sizeof(processInfo));

    ok = CreateProcessW(NULL,
                        command,
                        NULL,
                        NULL,
                        FALSE,
                        EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
                        environment_block,
                        working_directory,
                        &startupInfo.StartupInfo,
                        &processInfo);

    if (command != NULL)
    {
        free(command);
    }

    if (environment_block != NULL)
    {
        free(environment_block);
    }

    if (working_directory != NULL)
    {
        free(working_directory);
    }

    if (!ok)
    {
        error_message = "Failed to create process";
        DWORD error = GetLastError();
        printf("error no: %d\n", error);
        return NULL;
    }

    // free(startupInfo.lpAttributeList);

    // CloseHandle(processInfo.hThread);

    HANDLE mutex = CreateSemaphore(
        NULL, // default security attributes
        1,    // initial count
        1,    // maximum count
        NULL);

    start_read_thread(outputReadSide, options->stdout_port, mutex, options->ackRead);

    start_wait_exit_thread(processInfo.hProcess, options->exit_port, mutex);

    PtyHandle *pty = malloc(sizeof(PtyHandle));

    if (pty == NULL)
    {
        error_message = "Failed to allocate pty handle";
        return NULL;
    }

    pty->inputWriteSide = inputWriteSide;
    pty->outputReadSide = outputReadSide;
    pty->hPty = hPty;
    pty->dwProcessId = processInfo.dwProcessId;
    pty->ackRead = options->ackRead;
    pty->hMutex = mutex;

    return pty;
}

FFI_PLUGIN_EXPORT void pty_write(PtyHandle *handle, char *buffer, int length)
{
    DWORD bytesWritten;

    WriteFile(handle->inputWriteSide, buffer, length, &bytesWritten, NULL);

    FlushFileBuffers(handle->inputWriteSide);

    return;
}

FFI_PLUGIN_EXPORT void pty_ack_read(PtyHandle *handle)
{
    if (handle->ackRead)
    {
        ReleaseSemaphore(handle->hMutex, 1, NULL);
    }
}

FFI_PLUGIN_EXPORT int pty_resize(PtyHandle *handle, int rows, int cols)
{
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
    return error_message;
}
