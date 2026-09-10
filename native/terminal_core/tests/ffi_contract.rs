use ssterm_terminal_core::{
    ssterm_terminal_create, ssterm_terminal_destroy, ssterm_terminal_feed,
    ssterm_terminal_row_text, ssterm_terminal_snapshot, ssterm_terminal_snapshot_xterm_cells,
    TerminalCell, TerminalSnapshot,
};

#[test]
fn c_abi_reports_dirty_rows_and_nul_terminated_text() {
    unsafe {
        let terminal = ssterm_terminal_create(12, 2);
        let update = ssterm_terminal_feed(terminal, b"hello".as_ptr(), 5);
        assert_eq!(update.dirty_row_start, 0);
        assert_eq!(update.cursor_col, 5);
        let mut output = [0i8; 16];
        assert_eq!(
            ssterm_terminal_row_text(terminal, 0, output.as_mut_ptr(), output.len()),
            5
        );
        assert_eq!(
            std::ffi::CStr::from_ptr(output.as_ptr()).to_str().unwrap(),
            "hello"
        );
        ssterm_terminal_destroy(terminal);
    }
}

#[test]
fn c_abi_exports_the_xterm_packed_cell_layout() {
    unsafe {
        let terminal = ssterm_terminal_create(2, 1);
        ssterm_terminal_feed(terminal, b"\x1b[1;31mA".as_ptr(), 8);
        let mut metadata = TerminalSnapshot::default();
        let mut words = [0u32; 10];
        assert_eq!(
            ssterm_terminal_snapshot_xterm_cells(
                terminal,
                &mut metadata,
                words.as_mut_ptr(),
                words.len(),
            ),
            10
        );
        assert_eq!(words[0], 1 << 25 | 1);
        assert_eq!(words[2], 1);
        assert_eq!(words[3], u32::from(b'A') | (1 << 22));
        ssterm_terminal_destroy(terminal);
    }
}

#[test]
fn c_abi_copies_a_complete_versioned_snapshot() {
    unsafe {
        let terminal = ssterm_terminal_create(4, 2);
        ssterm_terminal_feed(terminal, b"ab\r\ncd".as_ptr(), 6);

        let mut metadata = TerminalSnapshot::default();
        let required = ssterm_terminal_snapshot(terminal, &mut metadata, std::ptr::null_mut(), 0);
        assert_eq!(required, 8);
        assert_eq!(metadata.columns, 4);
        assert_eq!(metadata.rows, 2);
        assert_eq!(metadata.cursor_col, 2);
        assert_eq!(metadata.cursor_row, 1);
        assert_eq!(metadata.generation, 1);

        let sentinel = TerminalCell {
            codepoint: 99,
            ..TerminalCell::default()
        };
        let mut too_small = vec![sentinel; required - 1];
        assert_eq!(
            ssterm_terminal_snapshot(
                terminal,
                &mut metadata,
                too_small.as_mut_ptr(),
                too_small.len(),
            ),
            required
        );
        assert!(too_small.iter().all(|cell| cell.codepoint == 99));

        let mut cells = vec![TerminalCell::default(); required];
        assert_eq!(
            ssterm_terminal_snapshot(terminal, &mut metadata, cells.as_mut_ptr(), cells.len(),),
            required
        );
        assert_eq!(cells[0].codepoint, u32::from(b'a'));
        assert_eq!(cells[1].codepoint, u32::from(b'b'));
        assert_eq!(cells[4].codepoint, u32::from(b'c'));
        assert_eq!(cells[5].codepoint, u32::from(b'd'));

        ssterm_terminal_destroy(terminal);
    }
}
