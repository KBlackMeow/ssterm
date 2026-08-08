#ifndef FLUTTER_PTY_H_
#define FLUTTER_PTY_H_

#if _WIN32
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT
#endif

#if defined(__linux__) || defined(__GLIBC__) || defined(__GNU__)
#define _GNU_SOURCE /* GNU glibc grantpt() prototypes */
#endif

#include "include/dart_api_dl.h"

typedef struct PtyOptions
{
    int rows;

    int cols;

    char *executable;

    char **arguments;

    char **environment;

    char *working_directory;

    Dart_Port stdout_port;

    Dart_Port exit_port;

    bool ackRead;

} PtyOptions;

typedef struct PtyHandle PtyHandle;
typedef struct JobHandle JobHandle;

FFI_PLUGIN_EXPORT PtyHandle *pty_create(PtyOptions *options);

FFI_PLUGIN_EXPORT void pty_destroy(PtyHandle *handle);

FFI_PLUGIN_EXPORT void pty_write(PtyHandle *handle, char *buffer, int length);

FFI_PLUGIN_EXPORT void pty_ack_read(PtyHandle *handle);

FFI_PLUGIN_EXPORT int pty_resize(PtyHandle *handle, int rows, int cols);

FFI_PLUGIN_EXPORT int pty_getpid(PtyHandle *handle);

FFI_PLUGIN_EXPORT char *pty_error(void);

/// Windows Job Object helpers used by non-PTY Agent2 processes.  On other
/// platforms these return null/false so callers can retain a single FFI API.
FFI_PLUGIN_EXPORT JobHandle *job_create_kill_on_close(void);
FFI_PLUGIN_EXPORT int job_assign_pid(JobHandle *handle, int pid);
FFI_PLUGIN_EXPORT int job_terminate(JobHandle *handle);
FFI_PLUGIN_EXPORT void job_close(JobHandle *handle);

#endif
