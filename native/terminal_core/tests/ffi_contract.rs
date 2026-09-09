use ssterm_terminal_core::{
    ssterm_terminal_create, ssterm_terminal_destroy, ssterm_terminal_feed, ssterm_terminal_row_text,
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
