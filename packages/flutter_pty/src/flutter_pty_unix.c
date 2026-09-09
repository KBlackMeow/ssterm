
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/wait.h>

#include "forkpty.h"
#include "flutter_pty.h"

#include "include/dart_api.h"
#include "include/dart_api_dl.h"
#include "include/dart_native_api.h"

// The Rust core is intentionally loaded at runtime. This keeps the existing
// plugin ABI untouched. Rust is the desktop default; setting
// SSTERM_USE_RUST_PTY=0 gives operations an immediate legacy-C fallback. The
// app bundle provides the dylib next to its executable.
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
    void *library;
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
static pthread_once_t rust_pty_api_once = PTHREAD_ONCE_INIT;

static void load_rust_pty_api(void)
{
#if defined(__APPLE__)
    rust_pty_api.library = dlopen("@executable_path/libssterm_pty_core.dylib", RTLD_NOW | RTLD_LOCAL);
#else
    rust_pty_api.library = dlopen("libssterm_pty_core.so", RTLD_NOW | RTLD_LOCAL);
#endif
    if (rust_pty_api.library == NULL)
    {
        return;
    }
    rust_pty_api.create = (RustPtyCreateFn)dlsym(rust_pty_api.library, "ssterm_pty_create_with_environment");
    rust_pty_api.destroy = (RustPtyDestroyFn)dlsym(rust_pty_api.library, "ssterm_pty_destroy");
    rust_pty_api.read = (RustPtyReadFn)dlsym(rust_pty_api.library, "ssterm_pty_read");
    rust_pty_api.write = (RustPtyWriteFn)dlsym(rust_pty_api.library, "ssterm_pty_write");
    rust_pty_api.resize = (RustPtyResizeFn)dlsym(rust_pty_api.library, "ssterm_pty_resize");
    rust_pty_api.kill = (RustPtyKillFn)dlsym(rust_pty_api.library, "ssterm_pty_kill");
    rust_pty_api.wait = (RustPtyWaitFn)dlsym(rust_pty_api.library, "ssterm_pty_wait");
    rust_pty_api.pid = (RustPtyPidFn)dlsym(rust_pty_api.library, "ssterm_pty_pid");
    rust_pty_api.error = (RustPtyErrorFn)dlsym(rust_pty_api.library, "ssterm_pty_error");
    if (rust_pty_api.create == NULL || rust_pty_api.destroy == NULL ||
        rust_pty_api.read == NULL || rust_pty_api.write == NULL || rust_pty_api.resize == NULL ||
        rust_pty_api.kill == NULL || rust_pty_api.wait == NULL ||
        rust_pty_api.pid == NULL || rust_pty_api.error == NULL)
    {
        dlclose(rust_pty_api.library);
        memset(&rust_pty_api, 0, sizeof(rust_pty_api));
    }
}

static bool use_rust_pty(void)
{
    const char *enabled = getenv("SSTERM_USE_RUST_PTY");
    if (enabled != NULL && strcmp(enabled, "0") == 0)
    {
        return false;
    }
    pthread_once(&rust_pty_api_once, load_rust_pty_api);
    return rust_pty_api.create != NULL;
}

static size_t string_vector_length(char **values)
{
    size_t length = 0;
    if (values == NULL)
    {
        return 0;
    }
    while (values[length] != NULL)
    {
        length++;
    }
    return length;
}

typedef struct PtyHandle
{
    int ptm;

    int pid;

    SstermPtyCore *rust_pty;

    bool uses_rust;

    pthread_t rust_read_thread;

    pthread_t rust_wait_thread;

    pthread_mutex_t mutex;

    bool ackRead;

    // Rust reader threads are owned and joined, so use a real condition gate
    // instead of the legacy cross-thread mutex-unlock handshake. This also
    // lets teardown wake a reader that is waiting for Dart acknowledgement.
    pthread_mutex_t rust_ack_mutex;

    pthread_cond_t rust_ack_condition;

    bool rust_read_permit;

    bool rust_read_stopping;

} PtyHandle;

typedef struct ReadLoopOptions
{
    int fd;

    SstermPtyCore *rust_pty;

    bool uses_rust;

    pthread_mutex_t *mutex;

    Dart_Port port;

    bool waitForReadAck;

    PtyHandle *handle;

} ReadLoopOptions;

char *error_message = NULL;
static char rust_error_message[512];

static void set_rust_error_message(const char *message)
{
    if (message == NULL)
    {
        error_message = "Rust PTY creation failed";
        return;
    }
    snprintf(rust_error_message, sizeof(rust_error_message), "%s", message);
    error_message = rust_error_message;
}

static void *read_loop(void *arg)
{
    ReadLoopOptions *options = (ReadLoopOptions *)arg;

    char buffer[1024];

    while (1)
    {
        if (options->waitForReadAck)
        {
            if (options->uses_rust)
            {
                PtyHandle *handle = options->handle;
                pthread_mutex_lock(&handle->rust_ack_mutex);
                while (!handle->rust_read_permit && !handle->rust_read_stopping)
                {
                    pthread_cond_wait(&handle->rust_ack_condition,
                                      &handle->rust_ack_mutex);
                }
                if (handle->rust_read_stopping)
                {
                    pthread_mutex_unlock(&handle->rust_ack_mutex);
                    break;
                }
                handle->rust_read_permit = false;
                pthread_mutex_unlock(&handle->rust_ack_mutex);
            }
            else
            {
                // Legacy C path keeps its established acknowledgement bridge.
                pthread_mutex_lock(options->mutex);
            }
        }
        ssize_t n = options->uses_rust
                        ? (ssize_t)rust_pty_api.read(options->rust_pty, (uint8_t *)buffer, sizeof(buffer))
                        : read(options->fd, buffer, sizeof(buffer));

        if (n < 0)
        {
            // TODO: handle error
            break;
        }

        if (n == 0)
        {
            break;
        }

        Dart_CObject result;
        result.type = Dart_CObject_kTypedData;
        result.value.as_typed_data.type = Dart_TypedData_kUint8;
        result.value.as_typed_data.length = n;
        result.value.as_typed_data.values = (uint8_t *)buffer;

        Dart_PostCObject_DL(options->port, &result);
    }

    free(options);
    return NULL;
}

static int start_read_thread(int fd, SstermPtyCore *rust_pty, bool uses_rust,
                             Dart_Port port, pthread_mutex_t *mutex, bool waitForReadAck,
                             PtyHandle *handle, pthread_t *thread)
{
    ReadLoopOptions *options = malloc(sizeof(ReadLoopOptions));

    options->fd = fd;

    options->rust_pty = rust_pty;

    options->uses_rust = uses_rust;

    options->port = port;

    options->mutex = mutex;

    options->waitForReadAck = waitForReadAck;

    options->handle = handle;

    if (pthread_create(thread, NULL, &read_loop, options) == 0)
    {
        if (!uses_rust)
        {
            pthread_detach(*thread);
        }
        return 0;
    }
    else
    {
        free(options);
        return -1;
    }
}

typedef struct WaitExitOptions
{
    int pid;

    SstermPtyCore *rust_pty;

    bool uses_rust;

    Dart_Port port;

} WaitExitOptions;

static void *wait_exit_thread(void *arg)
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
        int status;
        waitpid(options->pid, &status, 0);
        if (WIFEXITED(status))
        {
            Dart_PostInteger_DL(options->port, WEXITSTATUS(status));
        }
        else if (WIFSIGNALED(status))
        {
            Dart_PostInteger_DL(options->port, -WTERMSIG(status));
        }
    }

    free(options);
    return NULL;
}

static int start_wait_exit_thread(int pid, SstermPtyCore *rust_pty, bool uses_rust,
                                  Dart_Port port, pthread_t *thread)
{
    WaitExitOptions *options = malloc(sizeof(WaitExitOptions));

    options->pid = pid;

    options->rust_pty = rust_pty;

    options->uses_rust = uses_rust;

    options->port = port;

    if (pthread_create(thread, NULL, &wait_exit_thread, options) == 0)
    {
        if (!uses_rust)
        {
            pthread_detach(*thread);
        }
        return 0;
    }
    else
    {
        free(options);
        return -1;
    }
}

static void set_environment(char **environment)
{
    if (environment == NULL)
    {
        return;
    }

    while (*environment != NULL)
    {
        putenv(*environment);
        environment++;
    }
}

FFI_PLUGIN_EXPORT PtyHandle *pty_create(PtyOptions *options)
{
    if (use_rust_pty())
    {
        const size_t argument_count = string_vector_length(options->arguments);
        const size_t environment_count = string_vector_length(options->environment);
        // `options->arguments` is a conventional argv whose first entry is
        // the executable. Rust accepts only the remaining argument values.
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

        PtyHandle *handle = (PtyHandle *)calloc(1, sizeof(PtyHandle));
        if (handle == NULL)
        {
            rust_pty_api.destroy(rust_pty);
            error_message = "Unable to allocate Rust PTY handle";
            return NULL;
        }
        handle->ptm = -1;
        handle->rust_pty = rust_pty;
        handle->uses_rust = true;
        handle->pid = (int)rust_pty_api.pid(rust_pty);
        handle->ackRead = options->ackRead;
        pthread_mutex_init(&handle->mutex, NULL);
        pthread_mutex_init(&handle->rust_ack_mutex, NULL);
        pthread_cond_init(&handle->rust_ack_condition, NULL);
        handle->rust_read_permit = true;
        handle->rust_read_stopping = false;
        if (start_read_thread(-1, rust_pty, true, options->stdout_port,
                              &handle->mutex, options->ackRead, handle,
                              &handle->rust_read_thread) != 0 ||
            start_wait_exit_thread(handle->pid, rust_pty, true, options->exit_port,
                                   &handle->rust_wait_thread) != 0)
        {
            pthread_mutex_lock(&handle->rust_ack_mutex);
            handle->rust_read_stopping = true;
            pthread_cond_broadcast(&handle->rust_ack_condition);
            pthread_mutex_unlock(&handle->rust_ack_mutex);
            rust_pty_api.kill(rust_pty);
            // A successfully-started reader exits after kill; join it before
            // releasing the opaque Rust handle it is reading from.
            if (handle->rust_read_thread)
            {
                pthread_join(handle->rust_read_thread, NULL);
            }
            rust_pty_api.destroy(rust_pty);
            pthread_cond_destroy(&handle->rust_ack_condition);
            pthread_mutex_destroy(&handle->rust_ack_mutex);
            pthread_mutex_destroy(&handle->mutex);
            free(handle);
            error_message = "Unable to start Rust PTY bridge threads";
            return NULL;
        }
        return handle;
    }

    struct winsize ws;

    ws.ws_row = options->rows;
    ws.ws_col = options->cols;

    int ptm;

    int pid = pty_forkpty(&ptm, NULL, NULL, &ws);

    if (pid < 0)
    {
        error_message = "pty_forkpty failed";
        perror("pty_forkpty");
        return NULL;
    }

    if (pid == 0)
    {
        set_environment(options->environment);

        if (options->working_directory != NULL && strlen(options->working_directory) > 0)
        {
            chdir(options->working_directory);
        }

        int ok = execvp(options->executable, options->arguments);

        if (ok < 0)
        {
            perror("execvp");
        }
    }

    PtyHandle *handle = (PtyHandle *)malloc(sizeof(PtyHandle));

    handle->ptm = ptm;
    handle->pid = pid;
    pthread_mutex_init(&handle->mutex, NULL);
    handle->ackRead = options->ackRead;

    pthread_t ignored_read_thread;
    start_read_thread(ptm, NULL, false, options->stdout_port, &handle->mutex,
                      options->ackRead, handle, &ignored_read_thread);

    pthread_t ignored_wait_thread;
    start_wait_exit_thread(pid, NULL, false, options->exit_port, &ignored_wait_thread);

    return handle;
}

FFI_PLUGIN_EXPORT void pty_destroy(PtyHandle *handle)
{
    if (handle == NULL)
    {
        return;
    }

    if (handle->uses_rust)
    {
        pthread_mutex_lock(&handle->rust_ack_mutex);
        handle->rust_read_stopping = true;
        pthread_cond_broadcast(&handle->rust_ack_condition);
        pthread_mutex_unlock(&handle->rust_ack_mutex);
        rust_pty_api.kill(handle->rust_pty);
        pthread_join(handle->rust_read_thread, NULL);
        pthread_join(handle->rust_wait_thread, NULL);
        rust_pty_api.destroy(handle->rust_pty);
        pthread_cond_destroy(&handle->rust_ack_condition);
        pthread_mutex_destroy(&handle->rust_ack_mutex);
        pthread_mutex_destroy(&handle->mutex);
        free(handle);
        return;
    }

    // Kill the shell process with SIGKILL before closing the PTY master.
    // SIGTERM (sent by Dart-side Pty.kill()) is catchable/ignorable — if the
    // shell ignores it, the PTY slave stays open, the read_loop thread stays
    // blocked in read(), and the main-thread close() below would block forever
    // waiting for that read to drain (macOS kernel behaviour).  SIGKILL cannot
    // be caught; the slave closes immediately, read() returns EOF, and the
    // close() completes without blocking.
    kill(handle->pid, SIGKILL);

    close(handle->ptm);
    pthread_mutex_destroy(&handle->mutex);
    free(handle);
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
    write(handle->ptm, buffer, length);
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
            pthread_mutex_lock(&handle->rust_ack_mutex);
            handle->rust_read_permit = true;
            pthread_cond_signal(&handle->rust_ack_condition);
            pthread_mutex_unlock(&handle->rust_ack_mutex);
        }
        else
        {
            // Frees the legacy mutex so that the next chunk can be read.
            pthread_mutex_unlock(&handle->mutex);
        }
    }
}

FFI_PLUGIN_EXPORT int pty_resize(PtyHandle *handle, int rows, int cols)
{
    if (handle != NULL && handle->uses_rust)
    {
        return rust_pty_api.resize(handle->rust_pty, (uint16_t)cols, (uint16_t)rows);
    }
    struct winsize ws;

    ws.ws_row = rows;
    ws.ws_col = cols;

    return ioctl(handle->ptm, TIOCSWINSZ, &ws);
}

FFI_PLUGIN_EXPORT int pty_getpid(PtyHandle *handle)
{
    return handle->pid;
}

FFI_PLUGIN_EXPORT char *pty_error(void)
{
    return error_message;
}
