// Compiled by tool/test_pty_paste.sh. Exercise the actual native FFI entry
// points while a real nano process fills the PTY's output buffer.
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "../../packages/flutter_pty/src/flutter_pty.c"

static atomic_uint output_chunks;
static atomic_ulong output_bytes;
static char ordered_output[4096];
static size_t ordered_length;
static pthread_mutex_t ordered_lock = PTHREAD_MUTEX_INITIALIZER;

static bool record_output(Dart_Port_DL port, Dart_CObject *object)
{
    if (port == 1 && object->type == Dart_CObject_kTypedData)
    {
        atomic_fetch_add(&output_chunks, 1);
        atomic_fetch_add(&output_bytes, object->value.as_typed_data.length);
    }
    if (port == 3 && object->type == Dart_CObject_kTypedData)
    {
        pthread_mutex_lock(&ordered_lock);
        size_t length = ordered_length;
        size_t incoming = object->value.as_typed_data.length;
        size_t available = sizeof(ordered_output) - length - 1;
        if (incoming > available) incoming = available;
        memcpy(ordered_output + length,
               object->value.as_typed_data.values, incoming);
        ordered_output[length + incoming] = '\0';
        ordered_length = length + incoming;
        pthread_mutex_unlock(&ordered_lock);
    }
    return true;
}

static bool record_exit(Dart_Port_DL port, int64_t value)
{
    (void)port;
    (void)value;
    return true;
}

static double now_seconds(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1e9;
}

static bool writes_keep_order(void)
{
    char *arguments[] = {"/bin/cat", NULL};
    char *environment[] = {"TERM=xterm-256color", NULL};
    PtyOptions options = {
        .rows = 24,
        .cols = 80,
        .executable = "/bin/cat",
        .arguments = arguments,
        .environment = environment,
        .working_directory = "/tmp",
        .stdout_port = 3,
        .exit_port = 4,
        .ackRead = false,
    };
    PtyHandle *pty = pty_create(&options);
    if (pty == NULL) return false;
    pty_write(pty, "first\n", 6);
    pty_write(pty, "second\n", 7);
    double deadline = now_seconds() + 2;
    bool ordered = false;
    while (now_seconds() < deadline)
    {
        pthread_mutex_lock(&ordered_lock);
        const char *first = strstr(ordered_output, "first");
        const char *second = strstr(ordered_output, "second");
        ordered = first != NULL && second != NULL && first < second;
        pthread_mutex_unlock(&ordered_lock);
        if (ordered) break;
        usleep(1000);
    }
    pty_destroy(pty);
    return ordered;
}

int main(int argc, char **argv)
{
    if (argc != 2)
    {
        fprintf(stderr, "usage: pty_paste_test NANO_PATH\n");
        return 2;
    }

    char path[] = "/tmp/ssterm-pty-paste-XXXXXX";
    int file = mkstemp(path);
    if (file < 0) return 2;
    close(file);

    Dart_PostCObject_DL = record_output;
    Dart_PostInteger_DL = record_exit;
    char *arguments[] = {argv[1], path, NULL};
    char *environment[] = {"TERM=xterm-256color", "LANG=en_US.UTF-8", NULL};
    PtyOptions options = {
        .rows = 24,
        .cols = 80,
        .executable = argv[1],
        .arguments = arguments,
        .environment = environment,
        .working_directory = "/tmp",
        .stdout_port = 1,
        .exit_port = 2,
        .ackRead = true,
    };
    PtyHandle *pty = pty_create(&options);
    if (pty == NULL)
    {
        fprintf(stderr, "PTY creation failed: %s\n", pty_error());
        unlink(path);
        return 2;
    }

    double deadline = now_seconds() + 2;
    while (atomic_load(&output_chunks) == 0 && now_seconds() < deadline)
        usleep(1000);
    unsigned acknowledged = 0;
    while (acknowledged < atomic_load(&output_chunks))
    {
        pty_ack_read(pty);
        acknowledged++;
    }

    // A small paste can cause hundreds of KB of nano redraws. With the old
    // synchronous write, this call waits for ACKs that only this thread can
    // send and never returns.
    const char line[] = "abcdefghij\n";
    const int lines = 10000;
    char *paste = malloc(lines * (sizeof(line) - 1));
    if (paste == NULL)
    {
        pty_destroy(pty);
        unlink(path);
        return 2;
    }
    for (int i = 0; i < lines; i++)
        memcpy(paste + i * (sizeof(line) - 1), line, sizeof(line) - 1);
    double started = now_seconds();
    pty_write(pty, paste, lines * (sizeof(line) - 1));
    double write_ms = (now_seconds() - started) * 1000;
    free(paste);

    deadline = now_seconds() + 8;
    while (atomic_load(&output_bytes) < 500000 && now_seconds() < deadline)
    {
        while (acknowledged < atomic_load(&output_chunks))
        {
            pty_ack_read(pty);
            acknowledged++;
        }
        usleep(1000);
    }
    unsigned long bytes = atomic_load(&output_bytes);
    pty_destroy(pty);
    unlink(path);
    bool ordered = writes_keep_order();
    printf("write_ms=%.1f output_bytes=%lu ordered=%s\n",
           write_ms, bytes, ordered ? "yes" : "no");
    return write_ms < 250 && bytes >= 500000 && ordered ? 0 : 1;
}
