//! Pinned VT parser, no scrollback or host callbacks. Replies are bounded.
use jeryu_runner_protocol::wire::v2::ScreenSnapshot;

#[derive(Default)]
struct Queries {
    replies: Vec<u8>,
    overflow: bool,
    headless: bool,
}
impl Queries {
    fn reply(&mut self, bytes: &[u8]) {
        if !self.headless {
            return;
        }
        if self.replies.len() + bytes.len() > 1024 {
            self.overflow = true;
        } else {
            self.replies.extend_from_slice(bytes);
        }
    }
}
impl vt100::Callbacks for Queries {
    fn unhandled_csi(
        &mut self,
        screen: &mut vt100::Screen,
        i1: Option<u8>,
        i2: Option<u8>,
        params: &[&[u16]],
        c: char,
    ) {
        let value = params.first().and_then(|p| p.first()).copied().unwrap_or(0);
        if i2.is_some() || params.len() > 1 {
            return;
        }
        match (i1, value, c) {
            (None, 6, 'n') => {
                let (row, col) = screen.cursor_position();
                self.reply(format!("\x1b[{};{}R", row + 1, col + 1).as_bytes());
            }
            (None, 5, 'n') => self.reply(b"\x1b[0n"),
            (None, 0, 'c') => self.reply(b"\x1b[?1;2c"),
            (Some(b'>'), 0, 'c') => self.reply(b"\x1b[>0;1;0c"),
            _ => (),
        }
    }
    fn unhandled_escape(&mut self, _: &mut vt100::Screen, i1: Option<u8>, i2: Option<u8>, b: u8) {
        if i1.is_none() && i2.is_none() && b == b'Z' {
            self.reply(b"\x1b[?1;2c");
        }
    }
}
pub struct Terminal {
    parser: vt100::Parser<Queries>,
    clipped_size: bool,
    sequence: u64,
    escape: bool,
    osc_bytes: Option<usize>,
}
impl Terminal {
    pub fn new() -> Self {
        Self {
            parser: vt100::Parser::new_with_callbacks(24, 80, 0, Queries::default()),
            clipped_size: false,
            sequence: 0,
            escape: false,
            osc_bytes: None,
        }
    }
    pub fn process(
        &mut self,
        bytes: &[u8],
        sequence: u64,
        headless: bool,
    ) -> std::io::Result<Vec<u8>> {
        // vte's std feature uses a growable OSC buffer. Reject oversized OSC
        // before feeding the parser, including a string split across frames.
        for byte in bytes {
            if self.escape {
                self.escape = *byte == 0x1b;
                if *byte == b']' {
                    self.osc_bytes = Some(0);
                }
            } else if *byte == 0x1b {
                self.osc_bytes = None;
                self.escape = true;
            } else if let Some(size) = &mut self.osc_bytes {
                if matches!(*byte, 7 | 0x18 | 0x1a) {
                    self.osc_bytes = None;
                } else {
                    *size += 1;
                    if *size > 4096 {
                        return Err(std::io::Error::other("guest_vt_osc_capacity"));
                    }
                }
            }
        }
        self.parser.callbacks_mut().headless = headless;
        self.parser.process(bytes);
        self.sequence = sequence;
        if self.parser.callbacks().overflow {
            return Err(std::io::Error::other("guest_vt_reply_capacity"));
        }
        Ok(std::mem::take(&mut self.parser.callbacks_mut().replies))
    }
    pub fn resize(&mut self, rows: u16, cols: u16) {
        self.clipped_size = rows > 200 || cols > 400;
        self.parser
            .screen_mut()
            .set_size(rows.clamp(1, 200), cols.clamp(1, 400));
    }
    pub fn snapshot(&self) -> ScreenSnapshot {
        let screen = self.parser.screen();
        let (rows, cols) = screen.size();
        let (row, col) = screen.cursor_position();
        let mut text = screen.contents();
        let mut size = text.len().min(65536);
        while !text.is_char_boundary(size) {
            size -= 1;
        }
        let truncated = self.clipped_size || size < text.len();
        text.truncate(size);
        ScreenSnapshot {
            sequence: self.sequence,
            rows,
            cols,
            cursor_row: row.min(rows - 1),
            cursor_col: col.min(cols - 1),
            text,
            truncated,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn split_utf8_queries_and_real_terminal_passthrough() {
        let mut vt = Terminal::new();
        assert!(
            vt.process(b"\x1b[2J\x1b[H\xe2\x82", 1, true)
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            vt.process(b"\xac\x1b[6n\x1b[5n\x1b[c\x1b[>c\x1bZ", 2, true)
                .unwrap(),
            b"\x1b[1;2R\x1b[0n\x1b[?1;2c\x1b[>0;1;0c\x1b[?1;2c"
        );
        assert_eq!(vt.snapshot().text, "€");
        assert!(
            vt.process(b"\x1b[6n\x1b[5n\x1b[c", 3, false)
                .unwrap()
                .is_empty()
        );
        assert!(
            vt.process(b"\x1b]52;c;c2VjcmV0\x07", 4, true)
                .unwrap()
                .is_empty()
        );
        assert_eq!(vt.snapshot().text, "€");
        vt.resize(4096, 4096);
        let screen = vt.snapshot();
        assert_eq!((screen.rows, screen.cols), (200, 400));
        assert!(screen.truncated);
        screen.validate().unwrap();
    }
    #[test]
    fn query_flood_exhaustion_is_an_error_not_an_unbounded_queue() {
        assert!(
            Terminal::new()
                .process(&b"\x1b[6n".repeat(1000), 1, true)
                .is_err()
        );
        let mut terminal = Terminal::new();
        terminal.process(b"\x1b]52;c;", 1, true).unwrap();
        terminal.process(&vec![b'x'; 3000], 2, true).unwrap();
        assert!(terminal.process(&vec![b'x'; 3000], 3, true).is_err());
    }
}
