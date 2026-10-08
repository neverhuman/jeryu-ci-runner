//! Incremental framing survives polling timeouts after partial headers/payloads.
use super::{GuestMessage, MAX_FRAME_BYTES, invalid};
use std::{
    io::{ErrorKind, Read},
    marker::PhantomData,
};

pub struct FrameReader<T> {
    header: [u8; 4],
    header_used: usize,
    bytes: Vec<u8>,
    used: usize,
    message: PhantomData<T>,
}

impl<T> Default for FrameReader<T> {
    fn default() -> Self {
        Self {
            header: [0; 4],
            header_used: 0,
            bytes: vec![],
            used: 0,
            message: PhantomData,
        }
    }
}

impl<T: GuestMessage> FrameReader<T> {
    /// `None` is a polling timeout; EOF and malformed frames are hard failures.
    pub fn poll(&mut self, reader: &mut impl Read) -> std::io::Result<Option<T>> {
        loop {
            let buffer = if self.header_used < 4 {
                &mut self.header[self.header_used..]
            } else {
                &mut self.bytes[self.used..]
            };
            let size = match reader.read(buffer) {
                Ok(0) => {
                    return Err(std::io::Error::new(
                        ErrorKind::UnexpectedEof,
                        "guest_transport_closed",
                    ));
                }
                Ok(size) => size,
                Err(error)
                    if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) =>
                {
                    return Ok(None);
                }
                Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            };
            if self.header_used < 4 {
                self.header_used += size;
                if self.header_used == 4 {
                    let length = u32::from_be_bytes(self.header) as usize;
                    if length == 0 || length > MAX_FRAME_BYTES {
                        return Err(invalid());
                    }
                    self.bytes.resize(length, 0);
                }
            } else {
                self.used += size;
                if self.used == self.bytes.len() {
                    let message: T = serde_json::from_slice(&self.bytes).map_err(|_| invalid())?;
                    message.validate_message()?;
                    self.header_used = 0;
                    self.used = 0;
                    self.bytes.clear();
                    return Ok(Some(message));
                }
            }
        }
    }
}
