#ifndef SSTERM_TERMINAL_CORE_H
#define SSTERM_TERMINAL_CORE_H

#include <stddef.h>
#include <stdint.h>

typedef struct SstermTerminalCore SstermTerminalCore;

typedef struct {
  uint32_t dirty_row_start;
  uint32_t dirty_row_end;
  uint32_t cursor_col;
  uint32_t cursor_row;
  uint32_t bell_count;
  uint32_t title_changed;
  uint32_t working_directory_changed;
} SstermTerminalUpdate;

// A scalar cell for renderer/parity consumers. `codepoint == 0` denotes an
// unpainted cell (including the trailing half of a double-width scalar).
typedef struct {
  uint32_t codepoint;
  uint32_t foreground;
  uint32_t background;
  uint32_t attributes;
  uint32_t underline_color;
  uint8_t width;
  uint8_t reserved[3];
} SstermTerminalCell;

SstermTerminalCore *ssterm_terminal_create(uint32_t columns, uint32_t rows);
SstermTerminalCore *ssterm_terminal_create_with_scrollback(
    uint32_t columns, uint32_t rows, uint32_t max_scrollback_rows);
void ssterm_terminal_destroy(SstermTerminalCore *terminal);
SstermTerminalUpdate ssterm_terminal_feed(
    SstermTerminalCore *terminal, const uint8_t *bytes, size_t length);
void ssterm_terminal_resize(
    SstermTerminalCore *terminal, uint32_t columns, uint32_t rows);

// Writes a UTF-8 rendering of one row, without trailing blank cells. The
// returned value is the bytes required excluding the NUL terminator. If the
// destination is null or too small, no partial UTF-8 sequence is written.
size_t ssterm_terminal_row_text(
    const SstermTerminalCore *terminal, uint32_t row, char *destination,
    size_t destination_length);
SstermTerminalCell ssterm_terminal_cell(
    const SstermTerminalCore *terminal, uint32_t row, uint32_t column);
uint32_t ssterm_terminal_scrollback_rows(const SstermTerminalCore *terminal);
const char *ssterm_terminal_title(const SstermTerminalCore *terminal);
const char *ssterm_terminal_working_directory(const SstermTerminalCore *terminal);

#endif
