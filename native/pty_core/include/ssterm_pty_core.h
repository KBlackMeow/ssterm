#ifndef SSTERM_PTY_CORE_H
#define SSTERM_PTY_CORE_H

#include <stddef.h>
#include <stdint.h>

typedef struct SstermPtyCore SstermPtyCore;

// `arguments` is an argv-style UTF-8 array excluding `executable`. All input
// pointers are borrowed only for the duration of create().
SstermPtyCore *ssterm_pty_create(
    const char *executable,
    const char *const *arguments,
    size_t argument_count,
    const char *working_directory,
    uint16_t columns,
    uint16_t rows);
// `environment` contains UTF-8 `KEY=VALUE` entries. It supplements the
// inherited environment and is borrowed only for the duration of this call.
SstermPtyCore *ssterm_pty_create_with_environment(
    const char *executable,
    const char *const *arguments,
    size_t argument_count,
    const char *working_directory,
    const char *const *environment,
    size_t environment_count,
    uint16_t columns,
    uint16_t rows);
void ssterm_pty_destroy(SstermPtyCore *pty);
int64_t ssterm_pty_read(SstermPtyCore *pty, uint8_t *buffer, size_t length);
int32_t ssterm_pty_write(SstermPtyCore *pty, const uint8_t *buffer, size_t length);
int32_t ssterm_pty_resize(SstermPtyCore *pty, uint16_t columns, uint16_t rows);
int32_t ssterm_pty_kill(SstermPtyCore *pty);
int32_t ssterm_pty_wait(SstermPtyCore *pty, int32_t *exit_code);
uint32_t ssterm_pty_pid(SstermPtyCore *pty);
const char *ssterm_pty_error(void);

#endif
