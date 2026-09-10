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

typedef struct {
  uint32_t columns;
  uint32_t rows;
  uint32_t scrollback_rows;
  uint32_t cursor_col;
  uint32_t cursor_row;
  uint32_t using_alternate_screen;
  uint32_t mode_flags;
  uint32_t mouse_mode;
  uint32_t mouse_report_mode;
  uint32_t cursor_shape;
  uint64_t generation;
  uint64_t scrollback_sequence;
  uint64_t history_epoch;
} SstermTerminalSnapshot;

SstermTerminalCore *ssterm_terminal_create(uint32_t columns, uint32_t rows);
SstermTerminalCore *ssterm_terminal_create_with_scrollback(
    uint32_t columns, uint32_t rows, uint32_t max_scrollback_rows);
void ssterm_terminal_destroy(SstermTerminalCore *terminal);
SstermTerminalUpdate ssterm_terminal_feed(
    SstermTerminalCore *terminal, const uint8_t *bytes, size_t length);
void ssterm_terminal_resize(
    SstermTerminalCore *terminal, uint32_t columns, uint32_t rows);
void ssterm_terminal_set_background_rgb(
    SstermTerminalCore *terminal, uint32_t rgb);

// Copies and consumes pending terminal query responses. Returns the required
// byte count without consuming when the destination is null or too small.
size_t ssterm_terminal_take_response(
    SstermTerminalCore *terminal, uint8_t *destination,
    size_t destination_capacity);

// Writes a UTF-8 rendering of one row, without trailing blank cells. The
// returned value is the bytes required excluding the NUL terminator. If the
// destination is null or too small, no partial UTF-8 sequence is written.
size_t ssterm_terminal_row_text(
    const SstermTerminalCore *terminal, uint32_t row, char *destination,
    size_t destination_length);
SstermTerminalCell ssterm_terminal_cell(
    const SstermTerminalCore *terminal, uint32_t row, uint32_t column);

// Copies the complete visible grid into caller-owned storage and returns the
// required number of cells. If `destination_capacity` is too small, metadata
// is still written but the destination is left untouched. Callers are expected
// to retain and reuse their allocation between frames.
size_t ssterm_terminal_snapshot(
    const SstermTerminalCore *terminal,
    SstermTerminalSnapshot *metadata,
    SstermTerminalCell *destination,
    size_t destination_capacity);

// Renderer fast path. Each cell is written as five uint32 words matching the
// vendored xterm BufferLine layout: foreground, background, attributes,
// encoded content (codepoint | width << 22), and underline color.
size_t ssterm_terminal_snapshot_xterm_cells(
    const SstermTerminalCore *terminal,
    SstermTerminalSnapshot *metadata,
    uint32_t *destination,
    size_t destination_word_capacity);
// Copies a chronological slice of retained main-screen history in the same
// packed layout. `start_row` is relative to the oldest retained row.
size_t ssterm_terminal_history_xterm_cells(
    const SstermTerminalCore *terminal, uint32_t start_row,
    uint32_t row_count, uint32_t *destination,
    size_t destination_word_capacity);
uint32_t ssterm_terminal_scrollback_rows(const SstermTerminalCore *terminal);
const char *ssterm_terminal_title(const SstermTerminalCore *terminal);
const char *ssterm_terminal_working_directory(const SstermTerminalCore *terminal);

#endif
