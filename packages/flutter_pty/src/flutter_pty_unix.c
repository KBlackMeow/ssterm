
#include <stdint.h>
#include <errno.h>
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

// Large output floods must not pay for one native-thread/Dart-isolate ACK
// round trip per kilobyte. read() still returns immediately with whatever is
// available, so this capacity does not add latency to interactive output.
// The Rust read() coalesces within its 1 ms poll window up to this size, so a
// larger buffer directly halves the port messages and FFI round trips of a
// sustained flood. One in-flight chunk also remains below OutputPipe's
// default 512 KiB queue high-water mark, preserving the existing
// backpressure bound for the Dart-parsing fallback.
#define PTY_READ_BUFFER_SIZE (128 * 1024)

// Keep several reads in flight so the native reader and Dart isolate run as
// a pipeline instead of serializing every chunk behind one ACK round trip.
// The window is deliberately bounded: even if each read fills the 128 KiB
// buffer, at most 4 MiB can be queued beyond Dart's last acknowledgement.
#define PTY_RUST_READ_WINDOW 32

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

typedef struct PtyWriteRequest
{
    struct PtyWriteRequest *next;
    size_t length;
    uint8_t data[1];
} PtyWriteRequest;

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

    // Rust reader threads are owned and joined, so use a condition-backed
    // credit window instead of the legacy cross-thread mutex-unlock handshake.
    // This also lets teardown wake a reader waiting for Dart capacity.
    pthread_mutex_t rust_ack_mutex;

    pthread_cond_t rust_ack_condition;

    size_t rust_read_credits;

    bool rust_read_stopping;

    // Writes can wait for a child that is itself waiting for Dart to ACK
    // output. Keep that wait off the Dart/Flutter thread and preserve order.
    pthread_mutex_t write_mutex;
    pthread_cond_t write_condition;
    pthread_t write_thread;
    PtyWriteRequest *write_head;
    PtyWriteRequest *write_tail;
    bool write_stopping;
    bool write_thread_started;

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

static void *write_loop(void *arg)
{
    PtyHandle *handle = (PtyHandle *)arg;
    for (;;)
    {
        pthread_mutex_lock(&handle->write_mutex);
        while (handle->write_head == NULL && !handle->write_stopping)
        {
            pthread_cond_wait(&handle->write_condition, &handle->write_mutex);
        }
        if (handle->write_stopping)
        {
            pthread_mutex_unlock(&handle->write_mutex);
            break;
        }
        PtyWriteRequest *request = handle->write_head;
        handle->write_head = request->next;
        if (handle->write_head == NULL) handle->write_tail = NULL;
        pthread_mutex_unlock(&handle->write_mutex);

        if (handle->uses_rust)
        {
            rust_pty_api.write(handle->rust_pty, request->data, request->length);
        }
        else
        {
            size_t offset = 0;
            while (offset < request->length)
            {
                ssize_t written = write(handle->ptm, request->data + offset,
                                        request->length - offset);
                if (written < 0 && errno == EINTR) continue;
                if (written <= 0) break;
                offset += (size_t)written;
            }
        }
        free(request);
    }
    return NULL;
}

static bool start_write_thread(PtyHandle *handle)
{
    pthread_mutex_init(&handle->write_mutex, NULL);
    pthread_cond_init(&handle->write_condition, NULL);
    if (pthread_create(&handle->write_thread, NULL, write_loop, handle) == 0)
    {
        handle->write_thread_started = true;
        return true;
    }
    pthread_cond_destroy(&handle->write_condition);
    pthread_mutex_destroy(&handle->write_mutex);
    return false;
}

static void stop_write_thread(PtyHandle *handle)
{
    if (!handle->write_thread_started) return;
    pthread_mutex_lock(&handle->write_mutex);
    handle->write_stopping = true;
    pthread_cond_signal(&handle->write_condition);
    pthread_mutex_unlock(&handle->write_mutex);
    pthread_join(handle->write_thread, NULL);
    while (handle->write_head != NULL)
    {
        PtyWriteRequest *request = handle->write_head;
        handle->write_head = request->next;
        free(request);
    }
    pthread_cond_destroy(&handle->write_condition);
    pthread_mutex_destroy(&handle->write_mutex);
    handle->write_thread_started = false;
}

static void *read_loop(void *arg)
{
    ReadLoopOptions *options = (ReadLoopOptions *)arg;

    char buffer[PTY_READ_BUFFER_SIZE];

    while (1)
    {
        if (options->waitForReadAck)
        {
            if (options->uses_rust)
            {
                PtyHandle *handle = options->handle;
                pthread_mutex_lock(&handle->rust_ack_mutex);
                while (handle->rust_read_credits == 0 && !handle->rust_read_stopping)
                {
                    pthread_cond_wait(&handle->rust_ack_condition,
                                      &handle->rust_ack_mutex);
                }
                if (handle->rust_read_stopping)
                {
                    pthread_mutex_unlock(&handle->rust_ack_mutex);
                    break;
                }
                handle->rust_read_credits--;
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
        handle->rust_read_credits = PTY_RUST_READ_WINDOW;
        handle->rust_read_stopping = false;
        if (start_read_thread(-1, rust_pty, true, options->stdout_port,
                              &handle->mutex, options->ackRead, handle,
                              &handle->rust_read_thread) != 0 ||
            start_wait_exit_thread(handle->pid, rust_pty, true, options->exit_port,
                                   &handle->rust_wait_thread) != 0 ||
            !start_write_thread(handle))
        {
            pthread_mutex_lock(&handle->rust_ack_mutex);
            handle->rust_read_stopping = true;
            pthread_cond_broadcast(&handle->rust_ack_condition);
            pthread_mutex_unlock(&handle->rust_ack_mutex);
            rust_pty_api.kill(rust_pty);
            stop_write_thread(handle);
            // A successfully-started reader exits after kill; join it before
            // releasing the opaque Rust handle it is reading from.
            if (handle->rust_read_thread)
            {
                pthread_join(handle->rust_read_thread, NULL);
            }
            if (handle->rust_wait_thread)
            {
                pthread_join(handle->rust_wait_thread, NULL);
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

    PtyHandle *handle = (PtyHandle *)calloc(1, sizeof(PtyHandle));
    if (handle == NULL)
    {
        kill(pid, SIGKILL);
        close(ptm);
        error_message = "Unable to allocate PTY handle";
        return NULL;
    }

    handle->ptm = ptm;
    handle->pid = pid;
    pthread_mutex_init(&handle->mutex, NULL);
    handle->ackRead = options->ackRead;
    if (!start_write_thread(handle))
    {
        kill(pid, SIGKILL);
        close(ptm);
        pthread_mutex_destroy(&handle->mutex);
        free(handle);
        error_message = "Unable to start PTY writer";
        return NULL;
    }

    pthread_t ignored_read_thread;
    start_read_thread(ptm, NULL, false, options->stdout_port, &handle->mutex,
                      options->ackRead, handle, &ignored_read_thread);

    pthread_t ignored_wait_thread;
    start_wait_exit_thread(pid, NULL, false, options->exit_port, &ignored_wait_thread);

    return handle;
}

static void *destroy_rust_pty(void *arg)
{
    PtyHandle *handle = (PtyHandle *)arg;

    // Both bridge threads may be blocked in native calls.  Waiting for them is
    // required before releasing rust_pty, but it must never happen on the
    // Flutter platform thread: an unusually slow PTY EOF would otherwise
    // freeze the whole application while a tab is closing.
    pthread_join(handle->rust_read_thread, NULL);
    pthread_join(handle->rust_wait_thread, NULL);
    stop_write_thread(handle);
    rust_pty_api.destroy(handle->rust_pty);
    pthread_cond_destroy(&handle->rust_ack_condition);
    pthread_mutex_destroy(&handle->rust_ack_mutex);
    pthread_mutex_destroy(&handle->mutex);
    free(handle);
    return NULL;
}

static void *destroy_legacy_pty(void *arg)
{
    PtyHandle *handle = (PtyHandle *)arg;
    kill(handle->pid, SIGKILL);
    stop_write_thread(handle);
    close(handle->ptm);
    pthread_mutex_destroy(&handle->mutex);
    free(handle);
    return NULL;
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

        pthread_t destroy_thread;
        if (pthread_create(&destroy_thread, NULL, destroy_rust_pty, handle) == 0)
        {
            pthread_detach(destroy_thread);
        }
        // If a cleanup thread cannot be created, deliberately retain the
        // handle.  The stop signal and SIGKILL above still end the session;
        // leaking this one allocation is safer than either blocking the UI or
        // freeing memory still used by the reader/waiter threads.
        return;
    }

    // Joining a blocked write must also stay off the Flutter thread.
    pthread_t destroy_thread;
    if (pthread_create(&destroy_thread, NULL, destroy_legacy_pty, handle) == 0)
    {
        pthread_detach(destroy_thread);
    }
    else
    {
        kill(handle->pid, SIGKILL);
        // Retain the handle rather than freeing memory used by its writer.
    }
}

FFI_PLUGIN_EXPORT void pty_write(PtyHandle *handle, char *buffer, int length)
{
    if (handle == NULL || buffer == NULL || length <= 0 ||
        (size_t)length > SIZE_MAX - sizeof(PtyWriteRequest)) return;
    PtyWriteRequest *request = malloc(sizeof(PtyWriteRequest) + (size_t)length);
    if (request == NULL) return;
    request->next = NULL;
    request->length = (size_t)length;
    memcpy(request->data, buffer, (size_t)length);

    pthread_mutex_lock(&handle->write_mutex);
    if (handle->write_stopping)
    {
        pthread_mutex_unlock(&handle->write_mutex);
        free(request);
        return;
    }
    if (handle->write_tail != NULL) handle->write_tail->next = request;
    else handle->write_head = request;
    handle->write_tail = request;
    pthread_cond_signal(&handle->write_condition);
    pthread_mutex_unlock(&handle->write_mutex);
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
            if (handle->rust_read_credits < PTY_RUST_READ_WINDOW)
            {
                handle->rust_read_credits++;
                pthread_cond_signal(&handle->rust_ack_condition);
            }
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
