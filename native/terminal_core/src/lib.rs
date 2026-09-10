//! A deliberately small, dependency-free terminal data core.
//!
//! Flutter remains responsible for painting, selection and input. This crate
//! owns byte-oriented parsing and the hot screen/scrollback mutation path so
//! those operations can be profiled and evolved independently from the UI.

use std::cmp::{max, min};
use std::ffi::CString;
use std::os::raw::c_char;

#[derive(Clone, Copy, Default, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct TerminalUpdate {
    pub dirty_row_start: u32,
    pub dirty_row_end: u32,
    pub cursor_col: u32,
    pub cursor_row: u32,
    pub bell_count: u32,
    pub title_changed: u32,
    pub working_directory_changed: u32,
}

/// One renderer-facing screen cell. Its field layout mirrors xterm's cell
/// data, allowing Flutter to compare native and Dart buffers cell-for-cell.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(C)]
pub struct TerminalCell {
    pub codepoint: u32,
    pub foreground: u32,
    pub background: u32,
    pub attributes: u32,
    pub underline_color: u32,
    pub width: u8,
    pub reserved: [u8; 3],
}

#[derive(Clone, Copy, Default, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct TerminalSnapshot {
    pub columns: u32,
    pub rows: u32,
    pub scrollback_rows: u32,
    pub cursor_col: u32,
    pub cursor_row: u32,
    pub using_alternate_screen: u32,
    pub mode_flags: u32,
    pub mouse_mode: u32,
    pub mouse_report_mode: u32,
    pub cursor_shape: u32,
    pub generation: u64,
    pub scrollback_sequence: u64,
    pub history_epoch: u64,
}

const MODE_INSERT: u32 = 1 << 0;
const MODE_LINE_FEED: u32 = 1 << 1;
const MODE_CURSOR_KEYS: u32 = 1 << 2;
const MODE_REVERSE_DISPLAY: u32 = 1 << 3;
const MODE_ORIGIN: u32 = 1 << 4;
const MODE_AUTO_WRAP: u32 = 1 << 5;
const MODE_CURSOR_BLINK: u32 = 1 << 6;
const MODE_CURSOR_VISIBLE: u32 = 1 << 7;
const MODE_APP_KEYPAD: u32 = 1 << 8;
const MODE_REPORT_FOCUS: u32 = 1 << 9;
const MODE_ALT_MOUSE_SCROLL: u32 = 1 << 10;
const MODE_BRACKETED_PASTE: u32 = 1 << 11;

#[derive(Clone, Copy, Default)]
struct CursorStyle {
    foreground: u32,
    background: u32,
    attributes: u32,
    underline_color: u32,
}

const ATTR_BOLD: u32 = 1 << 0;
const ATTR_FAINT: u32 = 1 << 1;
const ATTR_ITALIC: u32 = 1 << 2;
const ATTR_UNDERLINE: u32 = 1 << 3;
const ATTR_BLINK: u32 = 1 << 4;
const ATTR_INVERSE: u32 = 1 << 5;
const ATTR_INVISIBLE: u32 = 1 << 6;
const ATTR_STRIKETHROUGH: u32 = 1 << 7;
const ATTR_OVERLINE: u32 = 1 << 8;
const COLOR_NAMED: u32 = 1 << 25;
const COLOR_PALETTE: u32 = 2 << 25;
const COLOR_RGB: u32 = 3 << 25;

#[derive(Clone, Copy, PartialEq, Eq)]
enum ParseState {
    Ground,
    Escape,
    Csi,
    Osc,
    OscEscape,
    Dcs,
    DcsEscape,
    CharsetG0,
    CharsetG1,
    EscapeIgnore,
}

pub struct TerminalCore {
    columns: usize,
    rows: usize,
    cursor_col: usize,
    cursor_row: usize,
    margin_top: usize,
    margin_bottom: usize,
    cells: Vec<TerminalCell>,
    alt_cells: Vec<TerminalCell>,
    screen_head: usize,
    alt_screen_head: usize,
    using_alt: bool,
    alt_cursor_col: usize,
    alt_cursor_row: usize,
    saved_cursor_col: usize,
    saved_cursor_row: usize,
    scrollback: Vec<TerminalCell>,
    scrollback_head: usize,
    scrollback_len: usize,
    max_scrollback_rows: usize,
    state: ParseState,
    params: Vec<u16>,
    csi_prefix: u8,
    csi_intermediate: u8,
    osc: Vec<u8>,
    dcs: Vec<u8>,
    utf8: Vec<u8>,
    cursor_style: CursorStyle,
    auto_wrap: bool,
    insert_mode: bool,
    line_feed_mode: bool,
    cursor_keys_mode: bool,
    reverse_display_mode: bool,
    origin_mode: bool,
    cursor_blink_mode: bool,
    cursor_visible_mode: bool,
    app_keypad_mode: bool,
    report_focus_mode: bool,
    alt_buffer_mouse_scroll_mode: bool,
    bracketed_paste_mode: bool,
    mouse_mode: u32,
    mouse_report_mode: u32,
    cursor_shape: u32,
    g0_dec_graphics: bool,
    g1_dec_graphics: bool,
    use_g1_charset: bool,
    response: Vec<u8>,
    background_rgb: u32,
    title: CString,
    working_directory: CString,
    bells: u32,
    dirty_start: usize,
    dirty_end: usize,
    title_changed: bool,
    cwd_changed: bool,
    generation: u64,
    scrollback_sequence: u64,
    history_epoch: u64,
}

impl TerminalCore {
    pub fn new(columns: usize, rows: usize) -> Self {
        Self::with_scrollback(columns, rows, 1000)
    }

    pub fn with_scrollback(columns: usize, rows: usize, max_scrollback_rows: usize) -> Self {
        let columns = max(columns, 1);
        let rows = max(rows, 1);
        Self {
            columns,
            rows,
            cursor_col: 0,
            cursor_row: 0,
            margin_top: 0,
            margin_bottom: rows - 1,
            cells: vec![TerminalCell::default(); columns * rows],
            alt_cells: vec![TerminalCell::default(); columns * rows],
            screen_head: 0,
            alt_screen_head: 0,
            using_alt: false,
            alt_cursor_col: 0,
            alt_cursor_row: 0,
            saved_cursor_col: 0,
            saved_cursor_row: 0,
            scrollback: vec![TerminalCell::default(); columns.saturating_mul(max_scrollback_rows)],
            scrollback_head: 0,
            scrollback_len: 0,
            max_scrollback_rows,
            state: ParseState::Ground,
            params: Vec::with_capacity(8),
            csi_prefix: 0,
            csi_intermediate: 0,
            osc: Vec::with_capacity(64),
            dcs: Vec::with_capacity(64),
            utf8: Vec::with_capacity(4),
            cursor_style: CursorStyle::default(),
            auto_wrap: true,
            insert_mode: false,
            line_feed_mode: false,
            cursor_keys_mode: false,
            reverse_display_mode: false,
            origin_mode: false,
            cursor_blink_mode: false,
            cursor_visible_mode: true,
            app_keypad_mode: false,
            report_focus_mode: false,
            alt_buffer_mouse_scroll_mode: false,
            bracketed_paste_mode: false,
            mouse_mode: 0,
            mouse_report_mode: 0,
            cursor_shape: 0,
            g0_dec_graphics: false,
            g1_dec_graphics: false,
            use_g1_charset: false,
            response: Vec::with_capacity(128),
            background_rgb: 0x1e1e1e,
            title: CString::default(),
            working_directory: CString::default(),
            bells: 0,
            dirty_start: rows,
            dirty_end: 0,
            title_changed: false,
            cwd_changed: false,
            generation: 0,
            scrollback_sequence: 0,
            history_epoch: 0,
        }
    }

    fn reset_update(&mut self) {
        self.dirty_start = self.rows;
        self.dirty_end = 0;
        self.bells = 0;
        self.title_changed = false;
        self.cwd_changed = false;
    }

    fn mark_dirty(&mut self, row: usize) {
        self.dirty_start = min(self.dirty_start, row);
        self.dirty_end = max(self.dirty_end, row);
    }

    fn index(&self, row: usize, col: usize) -> usize {
        ((self.screen_head + row) % self.rows) * self.columns + col
    }

    fn scroll_up_region(&mut self, top: usize, bottom: usize) {
        if top == 0 && bottom == self.rows - 1 && !self.using_alt && self.max_scrollback_rows > 0 {
            let row = if self.scrollback_len < self.max_scrollback_rows {
                let row = (self.scrollback_head + self.scrollback_len) % self.max_scrollback_rows;
                self.scrollback_len += 1;
                row
            } else {
                let row = self.scrollback_head;
                self.scrollback_head = (self.scrollback_head + 1) % self.max_scrollback_rows;
                row
            };
            let offset = row * self.columns;
            let first = self.index(0, 0);
            self.scrollback[offset..offset + self.columns]
                .copy_from_slice(&self.cells[first..first + self.columns]);
            self.scrollback_sequence = self.scrollback_sequence.wrapping_add(1);
        }
        if top == 0 && bottom == self.rows - 1 {
            self.screen_head = (self.screen_head + 1) % self.rows;
        } else {
            for row in top..bottom {
                for column in 0..self.columns {
                    let destination = self.index(row, column);
                    let source = self.index(row + 1, column);
                    self.cells.swap(destination, source);
                }
            }
        }
        let begin = self.index(bottom, 0);
        self.cells[begin..begin + self.columns].fill(TerminalCell::default());
        self.dirty_start = min(self.dirty_start, top);
        self.dirty_end = max(self.dirty_end, bottom);
    }

    fn scroll_down_region(&mut self, top: usize, bottom: usize) {
        if top > bottom {
            return;
        }
        if top == 0 && bottom == self.rows - 1 {
            self.screen_head = (self.screen_head + self.rows - 1) % self.rows;
        } else if top < bottom {
            for row in (top + 1..=bottom).rev() {
                for column in 0..self.columns {
                    let destination = self.index(row, column);
                    let source = self.index(row - 1, column);
                    self.cells.swap(destination, source);
                }
            }
        }
        let begin = self.index(top, 0);
        self.cells[begin..begin + self.columns].fill(TerminalCell::default());
        self.dirty_start = min(self.dirty_start, top);
        self.dirty_end = max(self.dirty_end, bottom);
    }

    fn line_feed(&mut self) {
        if self.cursor_row == self.margin_bottom {
            self.scroll_up_region(self.margin_top, self.margin_bottom);
        } else {
            self.cursor_row = min(self.cursor_row + 1, self.rows - 1);
        }
        self.mark_dirty(self.cursor_row);
    }

    fn put_char(&mut self, value: char) {
        let value = self.translate_charset(value);
        // Wide glyphs deliberately occupy two cells in this initial ABI. The
        // second cell is a space so Flutter can safely paint one scalar per
        // reported cell while the renderer integration is rolled out.
        let width = if char_width(value) == 2 { 2 } else { 1 };
        // VT terminals defer wrapping until the *next printable character*.
        // Cursor motions after the final cell (for example CSI D) therefore
        // operate on the pending column instead of a line already scrolled.
        if self.cursor_col >= self.columns {
            self.cursor_col = 0;
            self.line_feed();
        }
        if self.cursor_col + width > self.columns {
            self.cursor_col = 0;
            self.line_feed();
        }
        let index = self.index(self.cursor_row, self.cursor_col);
        if self.insert_mode {
            let row_end = self.index(self.cursor_row, 0) + self.columns;
            let shift = min(width, row_end - index);
            if shift != 0 {
                self.cells
                    .copy_within(index..row_end - shift, index + shift);
            }
        }
        self.cells[index] = self.styled_cell(value as u32, width as u8);
        if width == 2 && self.cursor_col + 1 < self.columns {
            self.cells[index + 1] = self.styled_cell(0, 0);
        }
        self.mark_dirty(self.cursor_row);
        self.cursor_col += width;
    }

    fn translate_charset(&self, value: char) -> char {
        let dec_graphics = if self.use_g1_charset {
            self.g1_dec_graphics
        } else {
            self.g0_dec_graphics
        };
        if !dec_graphics {
            return value;
        }
        match value {
            '`' => '◆',
            'a' => '▒',
            'f' => '°',
            'g' => '±',
            'j' => '┘',
            'k' => '┐',
            'l' => '┌',
            'm' => '└',
            'n' => '┼',
            'o' => '⎺',
            'p' => '⎻',
            'q' => '─',
            'r' => '⎼',
            's' => '⎽',
            't' => '├',
            'u' => '┤',
            'v' => '┴',
            'w' => '┬',
            'x' => '│',
            'y' => '≤',
            'z' => '≥',
            '{' => 'π',
            '|' => '≠',
            '}' => '£',
            '~' => '·',
            _ => value,
        }
    }

    fn styled_cell(&self, codepoint: u32, width: u8) -> TerminalCell {
        TerminalCell {
            codepoint,
            foreground: self.cursor_style.foreground,
            background: self.cursor_style.background,
            attributes: self.cursor_style.attributes,
            underline_color: self.cursor_style.underline_color,
            width,
            reserved: [0; 3],
        }
    }

    fn erase_cell(&self) -> TerminalCell {
        TerminalCell {
            codepoint: 0,
            foreground: self.cursor_style.foreground,
            background: self.cursor_style.background,
            attributes: 0,
            underline_color: 0,
            width: 0,
            reserved: [0; 3],
        }
    }

    fn erase_range(&mut self, start: usize, end: usize) {
        let cell = self.erase_cell();
        for logical in start..end {
            let row = logical / self.columns;
            let column = logical % self.columns;
            let index = self.index(row, column);
            self.cells[index] = cell;
        }
    }

    fn erase_chars(&mut self, count: usize) {
        let start = self.cursor_row * self.columns + self.cursor_col;
        let end = min(
            start.saturating_add(count),
            (self.cursor_row + 1) * self.columns,
        );
        self.erase_range(start, end);
        self.mark_dirty(self.cursor_row);
    }

    fn insert_blank_chars(&mut self, count: usize) {
        let row_start = self.index(self.cursor_row, 0);
        let start = row_start + self.cursor_col;
        let count = min(count, self.columns - self.cursor_col);
        if count == 0 {
            return;
        }
        self.cells
            .copy_within(start..row_start + self.columns - count, start + count);
        let cell = self.erase_cell();
        self.cells[start..start + count].fill(cell);
        self.mark_dirty(self.cursor_row);
    }

    fn delete_chars(&mut self, count: usize) {
        let row_start = self.index(self.cursor_row, 0);
        let start = row_start + self.cursor_col;
        let count = min(count, self.columns - self.cursor_col);
        if count == 0 {
            return;
        }
        self.cells
            .copy_within(start + count..row_start + self.columns, start);
        let cell = self.erase_cell();
        self.cells[row_start + self.columns - count..row_start + self.columns].fill(cell);
        self.mark_dirty(self.cursor_row);
    }

    fn insert_lines(&mut self, count: usize) {
        if self.cursor_row < self.margin_top || self.cursor_row > self.margin_bottom {
            return;
        }
        let count = min(count, self.margin_bottom - self.cursor_row + 1);
        for _ in 0..count {
            self.scroll_down_region(self.cursor_row, self.margin_bottom);
        }
    }

    fn delete_lines(&mut self, count: usize) {
        if self.cursor_row < self.margin_top || self.cursor_row > self.margin_bottom {
            return;
        }
        let count = min(count, self.margin_bottom - self.cursor_row + 1);
        for _ in 0..count {
            self.scroll_up_region(self.cursor_row, self.margin_bottom);
        }
    }

    /// Emits complete UTF-8 scalars while retaining an incomplete scalar at a
    /// PTY chunk boundary. Terminal streams are bytes, not strings: treating
    /// every chunk as a complete string corrupts CJK and emoji output.
    fn emit_utf8(&mut self, force_invalid: bool) {
        if self.utf8.is_empty() {
            return;
        }
        match std::str::from_utf8(&self.utf8) {
            Ok(text) => {
                let text = text.to_owned();
                self.utf8.clear();
                for value in text.chars() {
                    self.put_char(value);
                }
            }
            Err(error) if error.error_len().is_none() && !force_invalid => {}
            Err(error) => {
                // Keep any valid prefix, replace the malformed sequence, and
                // retry the remaining bytes. This matches replacement-decoder
                // behaviour without losing bytes after an invalid scalar.
                let valid = error.valid_up_to();
                let prefix = String::from_utf8_lossy(&self.utf8[..valid]).into_owned();
                let consumed = valid + error.error_len().unwrap_or(self.utf8.len() - valid);
                self.utf8.drain(..consumed);
                for value in prefix.chars() {
                    self.put_char(value);
                }
                self.put_char('\u{fffd}');
                self.emit_utf8(force_invalid);
            }
        }
    }

    fn control(&mut self, byte: u8) {
        self.emit_utf8(true);
        match byte {
            0x07 => self.bells += 1,
            0x08 => self.cursor_col = self.cursor_col.saturating_sub(1),
            0x09 => self.cursor_col = min(((self.cursor_col / 8) + 1) * 8, self.columns - 1),
            0x0e => self.use_g1_charset = true,
            0x0f => self.use_g1_charset = false,
            b'\n' | 0x0b | 0x0c => {
                self.line_feed();
                if self.line_feed_mode {
                    self.cursor_col = 0;
                }
            }
            b'\r' => self.cursor_col = 0,
            _ => {}
        }
    }

    fn parameter(&self, position: usize, fallback: usize) -> usize {
        self.params
            .get(position)
            .copied()
            .filter(|value| *value != 0)
            .map(usize::from)
            .unwrap_or(fallback)
    }

    fn csi(&mut self, final_byte: u8) {
        let amount = self.parameter(0, 1);
        let row_top = if self.origin_mode { self.margin_top } else { 0 };
        let row_bottom = if self.origin_mode {
            self.margin_bottom
        } else {
            self.rows - 1
        };
        match final_byte {
            b'A' => self.cursor_row = max(self.cursor_row.saturating_sub(amount), row_top),
            b'B' | b'e' => self.cursor_row = min(self.cursor_row + amount, row_bottom),
            b'C' => self.cursor_col = min(self.cursor_col + amount, self.columns - 1),
            b'a' => self.cursor_col = min(self.cursor_col + amount, self.columns - 1),
            b'D' => self.cursor_col = self.cursor_col.saturating_sub(amount),
            b'E' => {
                self.cursor_row = min(self.cursor_row + amount, row_bottom);
                self.cursor_col = 0;
            }
            b'F' => {
                self.cursor_row = max(self.cursor_row.saturating_sub(amount), row_top);
                self.cursor_col = 0;
            }
            b'G' | b'`' => {
                self.cursor_col = min(self.parameter(0, 1).saturating_sub(1), self.columns - 1);
            }
            b'H' | b'f' => {
                self.cursor_row = min(row_top + self.parameter(0, 1).saturating_sub(1), row_bottom);
                self.cursor_col = min(self.parameter(1, 1).saturating_sub(1), self.columns - 1);
            }
            b'd' => {
                self.cursor_row = min(row_top + self.parameter(0, 1).saturating_sub(1), row_bottom)
            }
            b'J' => match self.params.first().copied().unwrap_or(0) {
                0 => {
                    let start = self.cursor_row * self.columns + self.cursor_col;
                    self.erase_range(start, self.cells.len());
                    self.dirty_start = min(self.dirty_start, self.cursor_row);
                    self.dirty_end = self.rows - 1;
                }
                1 => {
                    let end = self.cursor_row * self.columns + self.cursor_col + 1;
                    self.erase_range(0, end);
                    self.dirty_start = 0;
                    self.dirty_end = max(self.dirty_end, self.cursor_row);
                }
                2 => {
                    self.erase_range(0, self.cells.len());
                    self.mark_all_dirty();
                }
                3 => {
                    self.scrollback_head = 0;
                    self.scrollback_len = 0;
                    self.history_epoch = self.history_epoch.wrapping_add(1);
                }
                _ => {}
            },
            b'K' => {
                let row_start = self.cursor_row * self.columns;
                let row_end = row_start + self.columns;
                let cursor = row_start + self.cursor_col;
                match self.params.first().copied().unwrap_or(0) {
                    0 => self.erase_range(cursor, row_end),
                    1 => self.erase_range(row_start, cursor + 1),
                    2 => self.erase_range(row_start, row_end),
                    _ => {}
                }
                self.mark_dirty(self.cursor_row);
            }
            b'@' => self.insert_blank_chars(amount),
            b'P' => self.delete_chars(amount),
            b'X' => self.erase_chars(amount),
            b'L' => self.insert_lines(amount),
            b'M' => self.delete_lines(amount),
            b'S' => {
                for _ in 0..amount {
                    self.scroll_up_region(self.margin_top, self.margin_bottom);
                }
            }
            b'T' => {
                for _ in 0..amount {
                    self.scroll_down_region(self.margin_top, self.margin_bottom);
                }
            }
            b'r' if self.csi_prefix == 0 => {
                let top = min(self.parameter(0, 1).saturating_sub(1), self.rows - 1);
                let bottom = min(
                    self.parameter(1, self.rows).saturating_sub(1),
                    self.rows - 1,
                );
                if top < bottom {
                    self.margin_top = top;
                    self.margin_bottom = bottom;
                    self.cursor_row = 0;
                    self.cursor_col = 0;
                }
            }
            b'm' => self.sgr(),
            b's' => self.save_cursor(),
            b'u' if self.csi_prefix == 0 => self.restore_cursor(),
            b'h' | b'l' if self.csi_prefix == b'?' => {
                let enabled = final_byte == b'h';
                let modes = self.params.clone();
                for mode in modes {
                    self.set_dec_mode(mode, enabled);
                }
            }
            b'h' | b'l' if self.csi_prefix == 0 => {
                let enabled = final_byte == b'h';
                let modes = self.params.clone();
                for mode in modes {
                    match mode {
                        4 => self.insert_mode = enabled,
                        20 => self.line_feed_mode = enabled,
                        _ => {}
                    }
                }
            }
            b'c' if self.csi_prefix == 0 && self.parameter(0, 0) == 0 => {
                self.response.extend_from_slice(b"\x1b[?1;2c");
            }
            b'n' if self.csi_prefix == 0 => match self.parameter(0, 0) {
                5 => self.response.extend_from_slice(b"\x1b[0n"),
                6 => self.response.extend_from_slice(
                    format!(
                        "\x1b[{};{}R",
                        self.cursor_row + 1,
                        min(self.cursor_col, self.columns - 1) + 1
                    )
                    .as_bytes(),
                ),
                _ => {}
            },
            b'u' if self.csi_prefix == b'?' => {
                self.response.extend_from_slice(b"\x1b[?0u");
            }
            b'q' if self.csi_prefix == b'>' => {
                self.response.extend_from_slice(b"\x1bP>|SSTerm\x1b\\");
            }
            b'q' if self.csi_intermediate == b' ' => {
                self.cursor_shape = self.parameter(0, 0) as u32;
            }
            _ => {}
        }
    }

    fn sgr(&mut self) {
        if self.params.is_empty() {
            self.cursor_style = CursorStyle::default();
            return;
        }
        let mut index = 0;
        while index < self.params.len() {
            let value = self.params[index] as u32;
            match value {
                0 => self.cursor_style = CursorStyle::default(),
                1 => self.cursor_style.attributes |= ATTR_BOLD,
                2 => self.cursor_style.attributes |= ATTR_FAINT,
                3 => self.cursor_style.attributes |= ATTR_ITALIC,
                4 => self.cursor_style.attributes |= ATTR_UNDERLINE,
                5 => self.cursor_style.attributes |= ATTR_BLINK,
                7 => self.cursor_style.attributes |= ATTR_INVERSE,
                8 => self.cursor_style.attributes |= ATTR_INVISIBLE,
                9 => self.cursor_style.attributes |= ATTR_STRIKETHROUGH,
                21 => self.cursor_style.attributes &= !ATTR_BOLD,
                22 => self.cursor_style.attributes &= !(ATTR_BOLD | ATTR_FAINT),
                23 => self.cursor_style.attributes &= !ATTR_ITALIC,
                24 => self.cursor_style.attributes &= !ATTR_UNDERLINE,
                25 => self.cursor_style.attributes &= !ATTR_BLINK,
                27 => self.cursor_style.attributes &= !ATTR_INVERSE,
                28 => self.cursor_style.attributes &= !ATTR_INVISIBLE,
                29 => self.cursor_style.attributes &= !ATTR_STRIKETHROUGH,
                30..=37 => self.cursor_style.foreground = COLOR_NAMED | (value - 30),
                39 => self.cursor_style.foreground = 0,
                40..=47 => self.cursor_style.background = COLOR_NAMED | (value - 40),
                49 => self.cursor_style.background = 0,
                53 => self.cursor_style.attributes |= ATTR_OVERLINE,
                55 => self.cursor_style.attributes &= !ATTR_OVERLINE,
                90..=97 => self.cursor_style.foreground = COLOR_NAMED | (value - 90 + 8),
                100..=107 => self.cursor_style.background = COLOR_NAMED | (value - 100 + 8),
                38 | 48 | 58 => {
                    let target = value;
                    if index + 2 < self.params.len() && self.params[index + 1] == 5 {
                        let color = COLOR_PALETTE | self.params[index + 2] as u32;
                        self.set_extended_color(target, color);
                        index += 2;
                    } else if index + 4 < self.params.len() && self.params[index + 1] == 2 {
                        let color = COLOR_RGB
                            | ((self.params[index + 2] as u32) << 16)
                            | ((self.params[index + 3] as u32) << 8)
                            | self.params[index + 4] as u32;
                        self.set_extended_color(target, color);
                        index += 4;
                    }
                }
                59 => self.cursor_style.underline_color = 0,
                _ => {}
            }
            index += 1;
        }
    }

    fn set_extended_color(&mut self, target: u32, color: u32) {
        match target {
            38 => self.cursor_style.foreground = color,
            48 => self.cursor_style.background = color,
            58 => self.cursor_style.underline_color = color,
            _ => {}
        }
    }

    fn mark_all_dirty(&mut self) {
        self.dirty_start = 0;
        self.dirty_end = self.rows - 1;
    }

    fn save_cursor(&mut self) {
        self.saved_cursor_col = self.cursor_col;
        self.saved_cursor_row = self.cursor_row;
    }

    fn restore_cursor(&mut self) {
        self.cursor_col = min(self.saved_cursor_col, self.columns);
        self.cursor_row = min(self.saved_cursor_row, self.rows - 1);
    }

    fn use_alt_buffer(&mut self) {
        if self.using_alt {
            return;
        }
        std::mem::swap(&mut self.cells, &mut self.alt_cells);
        std::mem::swap(&mut self.screen_head, &mut self.alt_screen_head);
        std::mem::swap(&mut self.cursor_col, &mut self.alt_cursor_col);
        std::mem::swap(&mut self.cursor_row, &mut self.alt_cursor_row);
        self.using_alt = true;
        self.mark_all_dirty();
    }

    fn use_main_buffer(&mut self) {
        if !self.using_alt {
            return;
        }
        std::mem::swap(&mut self.cells, &mut self.alt_cells);
        std::mem::swap(&mut self.screen_head, &mut self.alt_screen_head);
        std::mem::swap(&mut self.cursor_col, &mut self.alt_cursor_col);
        std::mem::swap(&mut self.cursor_row, &mut self.alt_cursor_row);
        self.using_alt = false;
        self.mark_all_dirty();
    }

    fn clear_alt_buffer(&mut self) {
        if self.using_alt {
            self.cells.fill(TerminalCell::default());
            self.screen_head = 0;
            self.cursor_col = 0;
            self.cursor_row = 0;
        } else {
            self.alt_cells.fill(TerminalCell::default());
            self.alt_screen_head = 0;
            self.alt_cursor_col = 0;
            self.alt_cursor_row = 0;
        }
    }

    fn set_dec_mode(&mut self, mode: u16, enabled: bool) {
        match mode {
            1 => self.cursor_keys_mode = enabled,
            5 => self.reverse_display_mode = enabled,
            6 => {
                self.origin_mode = enabled;
                self.cursor_col = 0;
                self.cursor_row = if enabled { self.margin_top } else { 0 };
            }
            7 => self.auto_wrap = enabled,
            12 => self.cursor_blink_mode = enabled,
            25 => self.cursor_visible_mode = enabled,
            1000 => self.mouse_mode = if enabled { 1 } else { 0 },
            1002 => self.mouse_mode = if enabled { 3 } else { 0 },
            1003 => self.mouse_mode = if enabled { 4 } else { 0 },
            1004 => self.report_focus_mode = enabled,
            1005 => self.mouse_report_mode = if enabled { 1 } else { 0 },
            1006 => self.mouse_report_mode = if enabled { 2 } else { 0 },
            1007 => self.alt_buffer_mouse_scroll_mode = enabled,
            1015 => self.mouse_report_mode = if enabled { 3 } else { 0 },
            2004 => self.bracketed_paste_mode = enabled,
            47 => {
                if enabled {
                    self.save_cursor();
                    self.use_alt_buffer();
                    self.cursor_style = CursorStyle::default();
                } else {
                    self.use_main_buffer();
                    self.restore_cursor();
                }
            }
            1047 => {
                if enabled {
                    self.use_alt_buffer();
                    self.cursor_style = CursorStyle::default();
                } else {
                    self.clear_alt_buffer();
                    self.use_main_buffer();
                }
            }
            1049 => {
                if enabled {
                    self.save_cursor();
                    self.clear_alt_buffer();
                    self.use_alt_buffer();
                    self.cursor_style = CursorStyle::default();
                } else {
                    self.use_main_buffer();
                    self.restore_cursor();
                    self.cursor_style = CursorStyle::default();
                }
            }
            _ => {}
        }
    }

    fn finish_osc(&mut self, terminator: u8) {
        let data = std::mem::take(&mut self.osc);
        let Ok(text) = std::str::from_utf8(&data) else {
            return;
        };
        let Some((code, value)) = text.split_once(';') else {
            return;
        };
        match code {
            "0" | "1" | "2" => {
                if let Ok(value) = CString::new(value) {
                    self.title = value;
                    self.title_changed = true;
                }
            }
            "7" => {
                if let Ok(value) = CString::new(value) {
                    self.working_directory = value;
                    self.cwd_changed = true;
                }
            }
            "11" if value == "?" => {
                let red = (self.background_rgb >> 16) & 0xff;
                let green = (self.background_rgb >> 8) & 0xff;
                let blue = self.background_rgb & 0xff;
                self.response.extend_from_slice(
                    format!(
                        "\x1b]11;rgb:{0:02x}{0:02x}/{1:02x}{1:02x}/{2:02x}{2:02x}",
                        red, green, blue
                    )
                    .as_bytes(),
                );
                if terminator == 0x07 {
                    self.response.push(0x07);
                } else {
                    self.response.extend_from_slice(b"\x1b\\");
                }
            }
            "1337" if value == "Capabilities" => {
                self.response
                    .extend_from_slice(b"\x1b]1337;Capabilities=T3MSc6Ts2B");
                if terminator == 0x07 {
                    self.response.push(0x07);
                } else {
                    self.response.extend_from_slice(b"\x1b\\");
                }
            }
            _ => {}
        }
    }

    fn finish_dcs(&mut self) {
        let data = std::mem::take(&mut self.dcs);
        let Some(query) = data.strip_prefix(b"+q") else {
            return;
        };
        if query == b"696e646e" {
            self.response
                .extend_from_slice(b"\x1bP1+r696e646e=1b5b257031256453\x1b\\");
        } else {
            self.response.extend_from_slice(b"\x1bP0+r\x1b\\");
        }
    }

    pub fn feed(&mut self, input: &[u8]) -> TerminalUpdate {
        self.reset_update();
        if !input.is_empty() {
            self.generation = self.generation.wrapping_add(1);
        }
        for &byte in input {
            match self.state {
                ParseState::Ground => match byte {
                    0x1b => {
                        self.emit_utf8(true);
                        self.state = ParseState::Escape;
                    }
                    0x00..=0x1f | 0x7f => self.control(byte),
                    0x20..=0x7e if self.utf8.is_empty() => self.put_char(char::from(byte)),
                    _ => {
                        self.utf8.push(byte);
                        self.emit_utf8(false);
                    }
                },
                ParseState::Escape => match byte {
                    b'[' => {
                        self.params.clear();
                        self.params.push(0);
                        self.csi_prefix = 0;
                        self.csi_intermediate = 0;
                        self.state = ParseState::Csi;
                    }
                    b']' => {
                        self.osc.clear();
                        self.state = ParseState::Osc;
                    }
                    b'P' => {
                        self.dcs.clear();
                        self.state = ParseState::Dcs;
                    }
                    b'(' => self.state = ParseState::CharsetG0,
                    b')' => self.state = ParseState::CharsetG1,
                    b'*' | b'+' | b'-' | b'.' | b'/' | b'%' | b'#' => {
                        self.state = ParseState::EscapeIgnore
                    }
                    b'7' => {
                        self.save_cursor();
                        self.state = ParseState::Ground;
                    }
                    b'8' => {
                        self.restore_cursor();
                        self.state = ParseState::Ground;
                    }
                    b'D' => {
                        self.line_feed();
                        self.state = ParseState::Ground;
                    }
                    b'E' => {
                        self.line_feed();
                        self.cursor_col = 0;
                        self.state = ParseState::Ground;
                    }
                    b'M' => {
                        if self.cursor_row == self.margin_top {
                            self.scroll_down_region(self.margin_top, self.margin_bottom);
                        } else {
                            self.cursor_row = self.cursor_row.saturating_sub(1);
                            self.mark_dirty(self.cursor_row);
                        }
                        self.state = ParseState::Ground;
                    }
                    b'=' => {
                        self.app_keypad_mode = true;
                        self.state = ParseState::Ground;
                    }
                    b'>' => {
                        self.app_keypad_mode = false;
                        self.state = ParseState::Ground;
                    }
                    _ => self.state = ParseState::Ground,
                },
                ParseState::Csi => match byte {
                    b'?' | b'>' if self.params.len() == 1 && self.params[0] == 0 => {
                        self.csi_prefix = byte
                    }
                    b'0'..=b'9' => {
                        let last = self.params.len() - 1;
                        self.params[last] = self.params[last]
                            .saturating_mul(10)
                            .saturating_add(u16::from(byte - b'0'));
                    }
                    b';' => self.params.push(0),
                    0x20..=0x2f => self.csi_intermediate = byte,
                    0x40..=0x7e => {
                        self.csi(byte);
                        self.state = ParseState::Ground;
                    }
                    _ => {}
                },
                ParseState::Osc => match byte {
                    0x07 => {
                        self.finish_osc(0x07);
                        self.state = ParseState::Ground;
                    }
                    0x1b => self.state = ParseState::OscEscape,
                    _ => self.osc.push(byte),
                },
                ParseState::OscEscape => {
                    if byte == b'\\' {
                        self.finish_osc(b'\\');
                        self.state = ParseState::Ground;
                    } else {
                        self.osc.push(0x1b);
                        self.osc.push(byte);
                        self.state = ParseState::Osc;
                    }
                }
                ParseState::Dcs => match byte {
                    0x1b => self.state = ParseState::DcsEscape,
                    _ => self.dcs.push(byte),
                },
                ParseState::DcsEscape => {
                    if byte == b'\\' {
                        self.finish_dcs();
                        self.state = ParseState::Ground;
                    } else {
                        self.dcs.push(0x1b);
                        self.dcs.push(byte);
                        self.state = ParseState::Dcs;
                    }
                }
                ParseState::CharsetG0 => {
                    self.g0_dec_graphics = byte == b'0';
                    self.state = ParseState::Ground;
                }
                ParseState::CharsetG1 => {
                    self.g1_dec_graphics = byte == b'0';
                    self.state = ParseState::Ground;
                }
                ParseState::EscapeIgnore => self.state = ParseState::Ground,
            }
        }
        self.emit_utf8(false);
        TerminalUpdate {
            dirty_row_start: if self.dirty_start == self.rows {
                u32::MAX
            } else {
                self.dirty_start as u32
            },
            dirty_row_end: self.dirty_end as u32,
            cursor_col: self.cursor_col as u32,
            cursor_row: self.cursor_row as u32,
            bell_count: self.bells,
            title_changed: self.title_changed as u32,
            working_directory_changed: self.cwd_changed as u32,
        }
    }

    pub fn resize(&mut self, columns: usize, rows: usize) {
        let columns = max(columns, 1);
        let rows = max(rows, 1);
        if columns != self.columns && !self.using_alt {
            self.resize_main_with_reflow(columns, rows);
            return;
        }
        let old_columns = self.columns;
        let old_rows = self.rows;
        let old_cells = self.cells.clone();
        let old_scrollback = std::mem::take(&mut self.scrollback);
        let old_scrollback_head = self.scrollback_head;
        let old_scrollback_len = self.scrollback_len;
        let mut cells = vec![TerminalCell::default(); columns * rows];
        let mut alt_cells = vec![TerminalCell::default(); columns * rows];
        let copy_columns = min(old_columns, columns);

        // Resizing the main screen changes the boundary between viewport and
        // scrollback. Mirror xterm's height semantics: first move the cursor
        // into the new viewport, then discard only rows below it. Moving every
        // top row into history regardless of cursor position creates visible
        // blank lines whenever a bottom-docked panel opens.
        let shrinking_main = !self.using_alt && rows < old_rows;
        let removed_main_rows = if shrinking_main {
            min(old_rows - rows, self.cursor_row.saturating_sub(rows - 1))
        } else {
            0
        };
        let popped_main_rows = if shrinking_main {
            old_rows - rows - removed_main_rows
        } else {
            0
        };
        let restored_history_rows = if !self.using_alt && rows > old_rows {
            min(rows - old_rows, old_scrollback_len)
        } else {
            0
        };
        let main_source_row_start = removed_main_rows;
        let main_current_rows = old_rows - main_source_row_start - popped_main_rows;
        let main_destination_row_start = restored_history_rows;

        // The alternate screen has no scrollback, but uses the same cursor
        // rule so height-only changes do not insert artificial blank rows.
        let alt_source_row_start = if rows < old_rows {
            min(
                old_rows - rows,
                self.alt_cursor_row.saturating_sub(rows - 1),
            )
        } else {
            0
        };
        let alt_copied_rows = min(rows, old_rows - alt_source_row_start);

        for row in 0..restored_history_rows {
            let old_row = (old_scrollback_head + old_scrollback_len - restored_history_rows + row)
                % self.max_scrollback_rows;
            let old_offset = old_row * old_columns;
            let destination_offset = row * columns;
            cells[destination_offset..destination_offset + copy_columns]
                .copy_from_slice(&old_scrollback[old_offset..old_offset + copy_columns]);
        }
        for row in 0..main_current_rows {
            let source_row = main_source_row_start + row;
            let destination_row = main_destination_row_start + row;
            for col in 0..copy_columns {
                cells[destination_row * columns + col] = self.cells[self.index(source_row, col)];
            }
        }
        for row in 0..alt_copied_rows {
            let source_row = alt_source_row_start + row;
            let destination_row = row;
            for col in 0..min(columns, self.columns) {
                let alt_index =
                    ((self.alt_screen_head + source_row) % old_rows) * self.columns + col;
                alt_cells[destination_row * columns + col] = self.alt_cells[alt_index];
            }
        }
        self.columns = columns;
        self.rows = rows;
        self.margin_top = 0;
        self.margin_bottom = rows - 1;
        self.cells = cells;
        self.alt_cells = alt_cells;
        self.screen_head = 0;
        self.alt_screen_head = 0;
        self.cursor_col = min(self.cursor_col, columns - 1);
        self.cursor_row = min(
            self.cursor_row.saturating_sub(main_source_row_start) + main_destination_row_start,
            rows - 1,
        );
        self.alt_cursor_col = min(self.alt_cursor_col, columns - 1);
        self.alt_cursor_row = min(
            self.alt_cursor_row.saturating_sub(alt_source_row_start),
            rows - 1,
        );
        self.scrollback =
            vec![TerminalCell::default(); columns.saturating_mul(self.max_scrollback_rows)];
        self.scrollback_head = 0;
        let history_source_len = if shrinking_main {
            old_scrollback_len + removed_main_rows
        } else {
            old_scrollback_len - restored_history_rows
        };
        self.scrollback_len = min(history_source_len, self.max_scrollback_rows);
        if self.max_scrollback_rows != 0 {
            let retained_start = history_source_len - self.scrollback_len;
            for row in 0..self.scrollback_len {
                let source_row = retained_start + row;
                let destination_offset = row * columns;
                if source_row < old_scrollback_len {
                    let old_row = (old_scrollback_head + source_row) % self.max_scrollback_rows;
                    let old_offset = old_row * old_columns;
                    self.scrollback[destination_offset..destination_offset + copy_columns]
                        .copy_from_slice(&old_scrollback[old_offset..old_offset + copy_columns]);
                } else {
                    let screen_row = source_row - old_scrollback_len;
                    let source_offset = ((self.screen_head + screen_row) % old_rows) * old_columns;
                    self.scrollback[destination_offset..destination_offset + copy_columns]
                        .copy_from_slice(&old_cells[source_offset..source_offset + copy_columns]);
                }
            }
        }
        self.history_epoch = self.history_epoch.wrapping_add(1);
        self.mark_all_dirty();
        self.generation = self.generation.wrapping_add(1);
    }

    /// Reflow the main screen and its history when the viewport width changes.
    ///
    /// The Flutter mirror deliberately disables its own reflow for SSH because
    /// Rust owns the authoritative screen. Copying only `min(old, new)` cells
    /// here would therefore permanently drop the right side of every line
    /// during a side-by-side split. Reflowing the complete transcript keeps
    /// those cells as wrapped rows instead.
    fn resize_main_with_reflow(&mut self, columns: usize, rows: usize) {
        let old_columns = self.columns;
        let old_rows = self.rows;
        let old_scrollback_len = self.scrollback_len;
        let old_scrollback_head = self.scrollback_head;
        let cursor_source_row = old_scrollback_len + self.cursor_row;
        let cursor_source_col = min(self.cursor_col, old_columns - 1);
        let mut cursor_row = 0;
        let mut cursor_col = 0;
        let mut reflowed = Vec::<Vec<TerminalCell>>::new();
        let mut screen_source_rows = self.cursor_row + 1;
        for row in 0..old_rows {
            let start = self.index(row, 0);
            if self.cells[start..start + old_columns]
                .iter()
                .any(|cell| *cell != TerminalCell::default())
            {
                screen_source_rows = max(screen_source_rows, row + 1);
            }
        }
        let source_row_count = old_scrollback_len + screen_source_rows;
        let mut logical = Vec::<TerminalCell>::new();
        let mut logical_cursor_offset = None;

        for source_row in 0..source_row_count {
            let source = if source_row < old_scrollback_len {
                let history_row = (old_scrollback_head + source_row) % self.max_scrollback_rows;
                &self.scrollback[history_row * old_columns..(history_row + 1) * old_columns]
            } else {
                let screen_row = source_row - old_scrollback_len;
                let start = self.index(screen_row, 0);
                &self.cells[start..start + old_columns]
            };

            let mut length = source
                .iter()
                .rposition(|cell| *cell != TerminalCell::default())
                .map_or(0, |index| index + 1);
            if source_row == cursor_source_row {
                length = max(length, cursor_source_col + 1);
                logical_cursor_offset = Some(logical.len() + cursor_source_col);
            }

            logical.extend_from_slice(&source[..length]);

            // A full row is normally an auto-wrap continuation. Coalescing it
            // with the following row lets a later width increase reconstruct
            // text that was wrapped for a temporary side-by-side split.
            if length != old_columns || source_row + 1 == source_row_count {
                let chunk_count = max(1, (logical.len() + columns - 1) / columns);
                let output_start = reflowed.len();
                for chunk in 0..chunk_count {
                    let mut target = vec![TerminalCell::default(); columns];
                    let start = chunk * columns;
                    let end = min(start + columns, logical.len());
                    if start < end {
                        target[..end - start].copy_from_slice(&logical[start..end]);
                    }
                    reflowed.push(target);
                }
                if let Some(offset) = logical_cursor_offset.take() {
                    cursor_row = output_start + offset / columns;
                    cursor_col = offset % columns;
                }
                logical.clear();
            }
        }

        let screen_start = reflowed.len().saturating_sub(rows);
        let history_len = min(screen_start, self.max_scrollback_rows);
        let history_start = screen_start - history_len;
        let mut cells = vec![TerminalCell::default(); columns * rows];
        for row in 0..min(rows, reflowed.len() - screen_start) {
            cells[row * columns..(row + 1) * columns]
                .copy_from_slice(&reflowed[screen_start + row]);
        }
        let mut scrollback =
            vec![TerminalCell::default(); columns.saturating_mul(self.max_scrollback_rows)];
        for row in 0..history_len {
            scrollback[row * columns..(row + 1) * columns]
                .copy_from_slice(&reflowed[history_start + row]);
        }

        // The alternate buffer has no history. Its applications generally
        // redraw after SIGWINCH, so retain the newest visible rows while the
        // resize is in flight rather than attempting to manufacture wrapping.
        let alt_copied_rows = min(rows, old_rows);
        let alt_source_start = old_rows - alt_copied_rows;
        let mut alt_cells = vec![TerminalCell::default(); columns * rows];
        let copy_columns = min(old_columns, columns);
        for row in 0..alt_copied_rows {
            let source_row = alt_source_start + row;
            let source_offset = ((self.alt_screen_head + source_row) % old_rows) * old_columns;
            let destination_offset = row * columns;
            alt_cells[destination_offset..destination_offset + copy_columns]
                .copy_from_slice(&self.alt_cells[source_offset..source_offset + copy_columns]);
        }

        self.columns = columns;
        self.rows = rows;
        self.margin_top = 0;
        self.margin_bottom = rows - 1;
        self.cells = cells;
        self.alt_cells = alt_cells;
        self.screen_head = 0;
        self.alt_screen_head = 0;
        self.cursor_col = cursor_col;
        self.cursor_row = min(cursor_row.saturating_sub(screen_start), rows - 1);
        self.alt_cursor_col = min(self.alt_cursor_col, columns - 1);
        self.alt_cursor_row = min(
            self.alt_cursor_row.saturating_sub(alt_source_start),
            rows - 1,
        );
        self.scrollback = scrollback;
        self.scrollback_head = 0;
        self.scrollback_len = history_len;
        self.history_epoch = self.history_epoch.wrapping_add(1);
        self.mark_all_dirty();
        self.generation = self.generation.wrapping_add(1);
    }

    fn snapshot_metadata(&self) -> TerminalSnapshot {
        let mode_flags = (self.insert_mode as u32) * MODE_INSERT
            | (self.line_feed_mode as u32) * MODE_LINE_FEED
            | (self.cursor_keys_mode as u32) * MODE_CURSOR_KEYS
            | (self.reverse_display_mode as u32) * MODE_REVERSE_DISPLAY
            | (self.origin_mode as u32) * MODE_ORIGIN
            | (self.auto_wrap as u32) * MODE_AUTO_WRAP
            | (self.cursor_blink_mode as u32) * MODE_CURSOR_BLINK
            | (self.cursor_visible_mode as u32) * MODE_CURSOR_VISIBLE
            | (self.app_keypad_mode as u32) * MODE_APP_KEYPAD
            | (self.report_focus_mode as u32) * MODE_REPORT_FOCUS
            | (self.alt_buffer_mouse_scroll_mode as u32) * MODE_ALT_MOUSE_SCROLL
            | (self.bracketed_paste_mode as u32) * MODE_BRACKETED_PASTE;
        TerminalSnapshot {
            columns: self.columns as u32,
            rows: self.rows as u32,
            scrollback_rows: self.scrollback_len as u32,
            cursor_col: min(self.cursor_col, self.columns.saturating_sub(1)) as u32,
            cursor_row: self.cursor_row as u32,
            using_alternate_screen: self.using_alt as u32,
            mode_flags,
            mouse_mode: self.mouse_mode,
            mouse_report_mode: self.mouse_report_mode,
            cursor_shape: self.cursor_shape,
            generation: self.generation,
            scrollback_sequence: self.scrollback_sequence,
            history_epoch: self.history_epoch,
        }
    }

    fn row_text(&self, row: usize) -> String {
        if row >= self.rows {
            return String::new();
        }
        let begin = self.index(row, 0);
        self.cells[begin..begin + self.columns]
            .iter()
            .filter_map(|cell| match cell.codepoint {
                0 => None,
                _ => char::from_u32(cell.codepoint),
            })
            .collect::<String>()
            .trim_end()
            .to_owned()
    }
}

fn char_width(value: char) -> usize {
    match value as u32 {
        0x1100..=0x115f
        | 0x2329..=0x232a
        | 0x2e80..=0xa4cf
        | 0xac00..=0xd7a3
        | 0xf900..=0xfaff
        | 0xfe10..=0xfe19
        | 0xfe30..=0xfe6f
        | 0xff00..=0xff60
        | 0xffe0..=0xffe6
        | 0x1f300..=0x1faff => 2,
        _ => 1,
    }
}

fn pack_xterm_cells(cells: &[TerminalCell], output: &mut [u32]) {
    const WORDS_PER_CELL: usize = 5;
    const WIDTH_SHIFT: u32 = 22;
    for (index, cell) in cells.iter().enumerate() {
        let offset = index * WORDS_PER_CELL;
        output[offset] = cell.foreground;
        output[offset + 1] = cell.background;
        output[offset + 2] = cell.attributes;
        output[offset + 3] = cell.codepoint | (u32::from(cell.width) << WIDTH_SHIFT);
        output[offset + 4] = cell.underline_color;
    }
}

#[no_mangle]
pub extern "C" fn ssterm_terminal_create(columns: u32, rows: u32) -> *mut TerminalCore {
    Box::into_raw(Box::new(TerminalCore::new(columns as usize, rows as usize)))
}
#[no_mangle]
pub extern "C" fn ssterm_terminal_create_with_scrollback(
    columns: u32,
    rows: u32,
    max_scrollback_rows: u32,
) -> *mut TerminalCore {
    Box::into_raw(Box::new(TerminalCore::with_scrollback(
        columns as usize,
        rows as usize,
        max_scrollback_rows as usize,
    )))
}
#[no_mangle]
/// # Safety
///
/// `terminal` must be null or a unique pointer returned by one of this
/// library's terminal creation functions. It must not be used afterwards.
pub unsafe extern "C" fn ssterm_terminal_destroy(terminal: *mut TerminalCore) {
    if !terminal.is_null() {
        drop(Box::from_raw(terminal));
    }
}
#[no_mangle]
/// # Safety
///
/// `terminal` must point to a live terminal from this library. `bytes` must
/// be null only when `length` is zero; otherwise it must reference `length`
/// readable bytes for this call's duration.
pub unsafe extern "C" fn ssterm_terminal_feed(
    terminal: *mut TerminalCore,
    bytes: *const u8,
    length: usize,
) -> TerminalUpdate {
    if terminal.is_null() || (bytes.is_null() && length != 0) {
        return TerminalUpdate::default();
    }
    (*terminal).feed(std::slice::from_raw_parts(bytes, length))
}
#[no_mangle]
/// # Safety
///
/// `terminal` must be null or point to a live terminal created by this
/// library, with no concurrent access to that terminal.
pub unsafe extern "C" fn ssterm_terminal_resize(
    terminal: *mut TerminalCore,
    columns: u32,
    rows: u32,
) {
    if let Some(terminal) = terminal.as_mut() {
        terminal.resize(columns as usize, rows as usize);
    }
}
#[no_mangle]
pub unsafe extern "C" fn ssterm_terminal_set_background_rgb(terminal: *mut TerminalCore, rgb: u32) {
    if let Some(terminal) = terminal.as_mut() {
        terminal.background_rgb = rgb & 0x00ff_ffff;
    }
}

#[no_mangle]
pub unsafe extern "C" fn ssterm_terminal_take_response(
    terminal: *mut TerminalCore,
    destination: *mut u8,
    destination_capacity: usize,
) -> usize {
    let Some(terminal) = terminal.as_mut() else {
        return 0;
    };
    let required = terminal.response.len();
    if required == 0 || destination.is_null() || destination_capacity < required {
        return required;
    }
    std::ptr::copy_nonoverlapping(terminal.response.as_ptr(), destination, required);
    terminal.response.clear();
    required
}
#[no_mangle]
/// # Safety
///
/// `terminal` must be null or a live terminal from this library. When non-null,
/// `destination` must reference writable `destination_length` bytes.
pub unsafe extern "C" fn ssterm_terminal_row_text(
    terminal: *const TerminalCore,
    row: u32,
    destination: *mut c_char,
    destination_length: usize,
) -> usize {
    let Some(terminal) = terminal.as_ref() else {
        return 0;
    };
    let text = terminal.row_text(row as usize);
    let needed = text.len();
    if !destination.is_null() && destination_length > needed {
        std::ptr::copy_nonoverlapping(text.as_ptr().cast(), destination, needed);
        *destination.add(needed) = 0;
    }
    needed
}
#[no_mangle]
/// # Safety
///
/// `terminal` must be null or point to a live terminal created by this
/// library and must not be concurrently mutated.
pub unsafe extern "C" fn ssterm_terminal_cell(
    terminal: *const TerminalCore,
    row: u32,
    column: u32,
) -> TerminalCell {
    let Some(terminal) = terminal.as_ref() else {
        return TerminalCell::default();
    };
    if row as usize >= terminal.rows || column as usize >= terminal.columns {
        return TerminalCell::default();
    }
    terminal.cells[terminal.index(row as usize, column as usize)]
}

#[no_mangle]
pub unsafe extern "C" fn ssterm_terminal_snapshot(
    terminal: *const TerminalCore,
    metadata: *mut TerminalSnapshot,
    destination: *mut TerminalCell,
    destination_capacity: usize,
) -> usize {
    let Some(terminal) = terminal.as_ref() else {
        return 0;
    };
    if let Some(metadata) = metadata.as_mut() {
        *metadata = terminal.snapshot_metadata();
    }

    let required = terminal.cells.len();
    if destination.is_null() || destination_capacity < required {
        return required;
    }
    for row in 0..terminal.rows {
        let source = terminal.index(row, 0);
        std::ptr::copy_nonoverlapping(
            terminal.cells[source..source + terminal.columns].as_ptr(),
            destination.add(row * terminal.columns),
            terminal.columns,
        );
    }
    required
}

#[no_mangle]
pub unsafe extern "C" fn ssterm_terminal_snapshot_xterm_cells(
    terminal: *const TerminalCore,
    metadata: *mut TerminalSnapshot,
    destination: *mut u32,
    destination_word_capacity: usize,
) -> usize {
    let Some(terminal) = terminal.as_ref() else {
        return 0;
    };
    if let Some(metadata) = metadata.as_mut() {
        *metadata = terminal.snapshot_metadata();
    }

    const WORDS_PER_CELL: usize = 5;
    let required = terminal.cells.len() * WORDS_PER_CELL;
    if destination.is_null() || destination_word_capacity < required {
        return required;
    }

    let output = std::slice::from_raw_parts_mut(destination, required);
    let words_per_row = terminal.columns * WORDS_PER_CELL;
    for row in 0..terminal.rows {
        let source = terminal.index(row, 0);
        pack_xterm_cells(
            &terminal.cells[source..source + terminal.columns],
            &mut output[row * words_per_row..(row + 1) * words_per_row],
        );
    }
    required
}

#[no_mangle]
pub unsafe extern "C" fn ssterm_terminal_history_xterm_cells(
    terminal: *const TerminalCore,
    start_row: u32,
    row_count: u32,
    destination: *mut u32,
    destination_word_capacity: usize,
) -> usize {
    let Some(terminal) = terminal.as_ref() else {
        return 0;
    };
    let start = min(start_row as usize, terminal.scrollback_len);
    let rows = min(row_count as usize, terminal.scrollback_len - start);
    const WORDS_PER_CELL: usize = 5;
    let required = rows * terminal.columns * WORDS_PER_CELL;
    if required == 0 || destination.is_null() || destination_word_capacity < required {
        return required;
    }
    let output = std::slice::from_raw_parts_mut(destination, required);
    let words_per_row = terminal.columns * WORDS_PER_CELL;
    for logical_row in 0..rows {
        let ring_row =
            (terminal.scrollback_head + start + logical_row) % terminal.max_scrollback_rows;
        let cell_start = ring_row * terminal.columns;
        pack_xterm_cells(
            &terminal.scrollback[cell_start..cell_start + terminal.columns],
            &mut output[logical_row * words_per_row..(logical_row + 1) * words_per_row],
        );
    }
    required
}
#[no_mangle]
/// # Safety
///
/// `terminal` must be null or point to a live terminal created by this
/// library and must not be concurrently mutated.
pub unsafe extern "C" fn ssterm_terminal_scrollback_rows(terminal: *const TerminalCore) -> u32 {
    let Some(terminal) = terminal.as_ref() else {
        return 0;
    };
    terminal.scrollback_len as u32
}
#[no_mangle]
/// # Safety
///
/// `terminal` must be null or point to a live terminal created by this
/// library. The returned string is borrowed and invalid after mutation or
/// destruction of that terminal.
pub unsafe extern "C" fn ssterm_terminal_title(terminal: *const TerminalCore) -> *const c_char {
    terminal
        .as_ref()
        .map(|value| value.title.as_ptr())
        .unwrap_or(std::ptr::null())
}
#[no_mangle]
/// # Safety
///
/// `terminal` must be null or point to a live terminal created by this
/// library. The returned string is borrowed and invalid after mutation or
/// destruction of that terminal.
pub unsafe extern "C" fn ssterm_terminal_working_directory(
    terminal: *const TerminalCore,
) -> *const c_char {
    terminal
        .as_ref()
        .map(|value| value.working_directory.as_ptr())
        .unwrap_or(std::ptr::null())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn handles_text_controls_and_scroll() {
        let mut terminal = TerminalCore::new(4, 2);
        terminal.feed(b"abcd\r\nefgh");
        assert_eq!(terminal.row_text(0), "abcd");
        assert_eq!(terminal.row_text(1), "efgh");
        assert_eq!(terminal.cursor_row, 1);
    }
    #[test]
    fn preserves_split_escape_and_osc7() {
        let mut terminal = TerminalCore::new(10, 2);
        terminal.feed(b"a\x1b[");
        terminal.feed(b"2;3Hb\x1b]7;file:///tmp\x1b");
        let update = terminal.feed(b"\\");
        assert_eq!(terminal.row_text(1), "b");
        assert!(update.working_directory_changed != 0);
        assert_eq!(terminal.working_directory.to_str().unwrap(), "file:///tmp");
    }
    #[test]
    fn resize_keeps_visible_cells() {
        let mut terminal = TerminalCore::new(4, 2);
        terminal.feed(b"abcd");
        terminal.resize(2, 3);
        assert_eq!(terminal.row_text(0), "ab");
    }

    #[test]
    fn resize_keeps_initial_screen_content_at_the_first_row() {
        let mut terminal = TerminalCore::new(4, 3);
        terminal.feed(b"aaaa\r\nbbbb\r\ncccc");
        terminal.resize(4, 5);
        assert_eq!(terminal.row_text(0), "aaaa");
        assert_eq!(terminal.row_text(1), "bbbb");
        assert_eq!(terminal.row_text(2), "cccc");
        assert_eq!(terminal.cursor_row, 2);
    }

    #[test]
    fn resize_restores_rows_hidden_by_a_shorter_viewport() {
        let mut terminal = TerminalCore::with_scrollback(4, 4, 8);
        terminal.feed(b"aaaa\r\nbbbb\r\ncccc\r\ndddd");

        terminal.resize(4, 2);
        assert_eq!(terminal.row_text(0), "cccc");
        assert_eq!(terminal.row_text(1), "dddd");
        assert_eq!(terminal.scrollback_len, 2);

        terminal.resize(4, 4);
        assert_eq!(terminal.row_text(0), "aaaa");
        assert_eq!(terminal.row_text(1), "bbbb");
        assert_eq!(terminal.row_text(2), "cccc");
        assert_eq!(terminal.row_text(3), "dddd");
        assert_eq!(terminal.scrollback_len, 0);
        assert_eq!(terminal.cursor_row, 3);
    }

    #[test]
    fn resize_shorter_keeps_top_content_when_cursor_is_already_visible() {
        let mut terminal = TerminalCore::with_scrollback(4, 4, 8);
        terminal.feed(b"top");

        terminal.resize(4, 2);
        assert_eq!(terminal.row_text(0), "top");
        assert_eq!(terminal.row_text(1), "");
        assert_eq!(terminal.scrollback_len, 0);
        assert_eq!(terminal.cursor_row, 0);
    }

    #[test]
    fn resize_reflows_columns_instead_of_discarding_the_right_side() {
        let mut terminal = TerminalCore::with_scrollback(8, 2, 8);
        terminal.feed(b"abcdefgh");

        terminal.resize(4, 2);
        assert_eq!(terminal.row_text(0), "abcd");
        assert_eq!(terminal.row_text(1), "efgh");
        assert_eq!(terminal.scrollback_len, 0);

        terminal.resize(8, 2);
        assert_eq!(terminal.row_text(0), "abcdefgh");
        assert_eq!(terminal.row_text(1), "");
    }
    #[test]
    fn preserves_utf8_across_pty_chunks() {
        let mut terminal = TerminalCore::new(8, 1);
        terminal.feed(&[0xe4, 0xbd]); // first two bytes of 你
        assert_eq!(terminal.row_text(0), "");
        terminal.feed(&[0xa0]);
        assert_eq!(terminal.row_text(0), "你");
    }

    #[test]
    fn retains_bounded_scrollback_rows() {
        let mut terminal = TerminalCore::with_scrollback(2, 2, 1);
        terminal.feed(b"aa\r\nbb\r\ncc");
        assert_eq!(terminal.scrollback_len, 1);
        assert_eq!(terminal.scrollback[0].codepoint, 'a' as u32);
    }

    #[test]
    fn erase_scrollback_does_not_erase_visible_cells() {
        let mut terminal = TerminalCore::with_scrollback(2, 2, 2);
        terminal.feed(b"aa\r\nbb\r\ncc");
        assert_eq!(terminal.scrollback_len, 1);
        terminal.feed(b"\x1b[3J");
        assert_eq!(terminal.scrollback_len, 0);
        assert_eq!(terminal.row_text(0), "bb");
        assert_eq!(terminal.row_text(1), "cc");
    }

    #[test]
    fn answers_shell_queries_and_tracks_input_modes() {
        let mut terminal = TerminalCore::new(10, 2);
        terminal.feed(b"\x1b[?1h\x1b[?25l\x1b[?1003h\x1b[?1006h\x1b[?2004h\x1b[?u\x1b[0c");
        let snapshot = terminal.snapshot_metadata();
        assert_ne!(snapshot.mode_flags & MODE_CURSOR_KEYS, 0);
        assert_eq!(snapshot.mode_flags & MODE_CURSOR_VISIBLE, 0);
        assert_ne!(snapshot.mode_flags & MODE_BRACKETED_PASTE, 0);
        assert_eq!(snapshot.mouse_mode, 4);
        assert_eq!(snapshot.mouse_report_mode, 2);
        assert_eq!(terminal.response, b"\x1b[?0u\x1b[?1;2c");
    }

    #[test]
    fn answers_split_fish_dcs_and_background_queries() {
        let mut terminal = TerminalCore::new(10, 2);
        terminal.background_rgb = 0x123456;
        terminal.feed(b"\x1bP+q696e");
        terminal.feed(b"646e\x1b\\\x1b]11;?\x07");
        assert_eq!(
            terminal.response,
            b"\x1bP1+r696e646e=1b5b257031256453\x1b\\\x1b]11;rgb:1212/3434/5656\x07"
        );
    }

    #[test]
    fn keeps_logical_rows_ordered_after_screen_ring_wraps() {
        let mut terminal = TerminalCore::with_scrollback(2, 2, 8);
        terminal.feed(b"aa\r\nbb\r\ncc\r\ndd\r\nee");
        assert_eq!(terminal.row_text(0), "dd");
        assert_eq!(terminal.row_text(1), "ee");
        assert_eq!(terminal.scrollback_len, 3);
        assert_ne!(terminal.screen_head, 0);
    }

    #[test]
    fn supports_dec_special_graphics_and_origin_mode() {
        let mut terminal = TerminalCore::new(8, 4);
        terminal.feed(b"\x1b(0lqk\x1b(B\x1b[2;4r\x1b[?6hX");
        assert_eq!(terminal.row_text(0), "┌─┐");
        assert_eq!(terminal.row_text(1), "X");
        assert_eq!(terminal.cells[terminal.index(1, 0)].codepoint, 'X' as u32);
        assert_eq!(terminal.cells[terminal.index(0, 0)].codepoint, '┌' as u32);
    }

    #[test]
    fn respects_scroll_regions_and_line_edits() {
        let mut terminal = TerminalCore::new(8, 3);
        terminal.feed(b"one\r\ntwo\r\nthree");
        terminal.feed(b"\x1b[2;3r\x1b[3;1H\n");
        assert_eq!(terminal.row_text(0), "one");
        assert_eq!(terminal.row_text(1), "three");
        assert_eq!(terminal.row_text(2), "");

        terminal.feed(b"\x1b[2;1H\x1b[L");
        assert_eq!(terminal.row_text(1), "");
        assert_eq!(terminal.row_text(2), "three");
        terminal.feed(b"\x1b[M");
        assert_eq!(terminal.row_text(1), "three");
        assert_eq!(terminal.row_text(2), "");

        terminal.feed(b"\x1b[3;3r\x1b[3;1Hlast\x1b[L");
        assert_eq!(terminal.row_text(2), "");
    }

    #[test]
    fn accepts_arbitrary_incremental_pty_bytes_without_panicking() {
        let mut terminal = TerminalCore::new(80, 24);
        let mut state = 0x9e37_79b9_u32;
        let mut bytes = [0_u8; 257];
        for round in 0..256 {
            for byte in &mut bytes {
                // Deterministic xorshift corpus: CI gets fuzz-like coverage
                // without depending on a random seed or external crate.
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                *byte = state as u8;
            }
            let split = (round * 37) % bytes.len();
            terminal.feed(&bytes[..split]);
            terminal.feed(&bytes[split..]);
            assert!(terminal.cursor_row < terminal.rows);
            assert!(terminal.cursor_col <= terminal.columns);
        }
    }
}
