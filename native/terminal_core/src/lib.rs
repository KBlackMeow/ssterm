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
    private: bool,
    osc: Vec<u8>,
    utf8: Vec<u8>,
    cursor_style: CursorStyle,
    auto_wrap: bool,
    title: CString,
    working_directory: CString,
    bells: u32,
    dirty_start: usize,
    dirty_end: usize,
    title_changed: bool,
    cwd_changed: bool,
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
            private: false,
            osc: Vec::with_capacity(64),
            utf8: Vec::with_capacity(4),
            cursor_style: CursorStyle::default(),
            auto_wrap: true,
            title: CString::default(),
            working_directory: CString::default(),
            bells: 0,
            dirty_start: rows,
            dirty_end: 0,
            title_changed: false,
            cwd_changed: false,
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
        row * self.columns + col
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
            self.scrollback[offset..offset + self.columns]
                .copy_from_slice(&self.cells[..self.columns]);
        }
        let source_start = (top + 1) * self.columns;
        let source_end = (bottom + 1) * self.columns;
        self.cells
            .copy_within(source_start..source_end, top * self.columns);
        let begin = bottom * self.columns;
        self.cells[begin..].fill(TerminalCell::default());
        self.dirty_start = min(self.dirty_start, top);
        self.dirty_end = max(self.dirty_end, bottom);
    }

    fn scroll_down_region(&mut self, top: usize, bottom: usize) {
        if top > bottom {
            return;
        }
        if top < bottom {
            let destination_start = (top + 1) * self.columns;
            self.cells
                .copy_within(top * self.columns..bottom * self.columns, destination_start);
        }
        self.cells[top * self.columns..(top + 1) * self.columns].fill(TerminalCell::default());
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
        self.cells[index] = self.styled_cell(value as u32, width as u8);
        if width == 2 && self.cursor_col + 1 < self.columns {
            self.cells[index + 1] = self.styled_cell(0, 0);
        }
        self.mark_dirty(self.cursor_row);
        self.cursor_col += width;
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
        self.cells[start..end].fill(cell);
    }

    fn erase_chars(&mut self, count: usize) {
        let start = self.index(self.cursor_row, self.cursor_col);
        let end = min(
            start.saturating_add(count),
            self.index(self.cursor_row, self.columns),
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
            b'\n' | 0x0b | 0x0c => self.line_feed(),
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
        match final_byte {
            b'A' => self.cursor_row = self.cursor_row.saturating_sub(amount),
            b'B' => self.cursor_row = min(self.cursor_row + amount, self.rows - 1),
            b'C' => self.cursor_col = min(self.cursor_col + amount, self.columns - 1),
            b'D' => self.cursor_col = self.cursor_col.saturating_sub(amount),
            b'E' => {
                self.cursor_row = min(self.cursor_row + amount, self.rows - 1);
                self.cursor_col = 0;
            }
            b'F' => {
                self.cursor_row = self.cursor_row.saturating_sub(amount);
                self.cursor_col = 0;
            }
            b'G' | b'`' => {
                self.cursor_col = min(self.parameter(0, 1).saturating_sub(1), self.columns - 1);
            }
            b'H' | b'f' => {
                self.cursor_row = min(self.parameter(0, 1).saturating_sub(1), self.rows - 1);
                self.cursor_col = min(self.parameter(1, 1).saturating_sub(1), self.columns - 1);
            }
            b'd' => self.cursor_row = min(self.parameter(0, 1).saturating_sub(1), self.rows - 1),
            b'J' => match self.params.first().copied().unwrap_or(0) {
                0 => {
                    let start = self.index(self.cursor_row, self.cursor_col);
                    self.erase_range(start, self.cells.len());
                    self.dirty_start = min(self.dirty_start, self.cursor_row);
                    self.dirty_end = self.rows - 1;
                }
                1 => {
                    let end = self.index(self.cursor_row, self.cursor_col) + 1;
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
                }
                _ => {}
            },
            b'K' => {
                let row_start = self.index(self.cursor_row, 0);
                let row_end = row_start + self.columns;
                let cursor = self.index(self.cursor_row, self.cursor_col);
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
            b'r' if !self.private => {
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
            b'u' => self.restore_cursor(),
            b'h' | b'l' if self.private => {
                let enabled = final_byte == b'h';
                let modes = self.params.clone();
                for mode in modes {
                    self.set_dec_mode(mode, enabled);
                }
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
        std::mem::swap(&mut self.cursor_col, &mut self.alt_cursor_col);
        std::mem::swap(&mut self.cursor_row, &mut self.alt_cursor_row);
        self.using_alt = false;
        self.mark_all_dirty();
    }

    fn clear_alt_buffer(&mut self) {
        if self.using_alt {
            self.cells.fill(TerminalCell::default());
            self.cursor_col = 0;
            self.cursor_row = 0;
        } else {
            self.alt_cells.fill(TerminalCell::default());
            self.alt_cursor_col = 0;
            self.alt_cursor_row = 0;
        }
    }

    fn set_dec_mode(&mut self, mode: u16, enabled: bool) {
        match mode {
            7 => self.auto_wrap = enabled,
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

    fn finish_osc(&mut self) {
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
            _ => {}
        }
    }

    pub fn feed(&mut self, input: &[u8]) -> TerminalUpdate {
        self.reset_update();
        for &byte in input {
            match self.state {
                ParseState::Ground => match byte {
                    0x1b => {
                        self.emit_utf8(true);
                        self.state = ParseState::Escape;
                    }
                    0x00..=0x1f | 0x7f => self.control(byte),
                    _ => {
                        self.utf8.push(byte);
                        self.emit_utf8(false);
                    }
                },
                ParseState::Escape => match byte {
                    b'[' => {
                        self.params.clear();
                        self.params.push(0);
                        self.private = false;
                        self.state = ParseState::Csi;
                    }
                    b']' => {
                        self.osc.clear();
                        self.state = ParseState::Osc;
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
                        self.cursor_row = self.cursor_row.saturating_sub(1);
                        self.mark_dirty(self.cursor_row);
                        self.state = ParseState::Ground;
                    }
                    _ => self.state = ParseState::Ground,
                },
                ParseState::Csi => match byte {
                    b'?' if self.params.len() == 1 && self.params[0] == 0 => self.private = true,
                    b'0'..=b'9' => {
                        let last = self.params.len() - 1;
                        self.params[last] = self.params[last]
                            .saturating_mul(10)
                            .saturating_add(u16::from(byte - b'0'));
                    }
                    b';' => self.params.push(0),
                    0x40..=0x7e => {
                        self.csi(byte);
                        self.state = ParseState::Ground;
                    }
                    _ => {}
                },
                ParseState::Osc => match byte {
                    0x07 => {
                        self.finish_osc();
                        self.state = ParseState::Ground;
                    }
                    0x1b => self.state = ParseState::OscEscape,
                    _ => self.osc.push(byte),
                },
                ParseState::OscEscape => {
                    if byte == b'\\' {
                        self.finish_osc();
                        self.state = ParseState::Ground;
                    } else {
                        self.osc.push(0x1b);
                        self.osc.push(byte);
                        self.state = ParseState::Osc;
                    }
                }
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
        let mut cells = vec![TerminalCell::default(); columns * rows];
        let mut alt_cells = vec![TerminalCell::default(); columns * rows];
        for row in 0..min(rows, self.rows) {
            for col in 0..min(columns, self.columns) {
                cells[row * columns + col] = self.cells[self.index(row, col)];
                alt_cells[row * columns + col] = self.alt_cells[self.index(row, col)];
            }
        }
        self.columns = columns;
        self.rows = rows;
        self.margin_top = 0;
        self.margin_bottom = rows - 1;
        self.cells = cells;
        self.alt_cells = alt_cells;
        self.cursor_col = min(self.cursor_col, columns - 1);
        self.cursor_row = min(self.cursor_row, rows - 1);
        self.alt_cursor_col = min(self.alt_cursor_col, columns - 1);
        self.alt_cursor_row = min(self.alt_cursor_row, rows - 1);
        // Native reflow is not exposed yet. A history row has the old width,
        // so discard it rather than returning malformed cells to Flutter.
        self.scrollback =
            vec![TerminalCell::default(); columns.saturating_mul(self.max_scrollback_rows)];
        self.scrollback_head = 0;
        self.scrollback_len = 0;
        self.mark_all_dirty();
    }

    fn row_text(&self, row: usize) -> String {
        if row >= self.rows {
            return String::new();
        }
        let begin = row * self.columns;
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
