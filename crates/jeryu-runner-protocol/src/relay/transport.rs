//! Concrete directions only. Decode failures never retain input or serde text.
use super::*;
use serde::de::DeserializeOwned;
use std::io::{Read, Write};
pub trait RelayMessage: Serialize + DeserializeOwned {
    fn validate_message(&self) -> Result<(), RelayErrorCode>;
}
impl RelayMessage for GuestRelayFrame {
    fn validate_message(&self) -> Result<(), RelayErrorCode> {
        self.validate()
    }
}
impl RelayMessage for NodeRelayFrame {
    fn validate_message(&self) -> Result<(), RelayErrorCode> {
        self.validate()
    }
}
pub fn read_frame<T: RelayMessage>(reader: &mut impl Read) -> std::io::Result<T> {
    let mut length = [0; 4];
    reader.read_exact(&mut length)?;
    let length = u32::from_be_bytes(length) as usize;
    if length == 0 || length > MAX_FRAME_BYTES {
        return Err(invalid());
    }
    let mut bytes = vec![0; length];
    reader.read_exact(&mut bytes)?;
    let frame: T = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    frame.validate_message().map_err(std::io::Error::other)?;
    Ok(frame)
}
pub fn write_frame<T: RelayMessage>(writer: &mut impl Write, frame: &T) -> std::io::Result<()> {
    frame.validate_message().map_err(std::io::Error::other)?;
    let bytes = serde_json::to_vec(frame).map_err(|_| invalid())?;
    if bytes.len() > MAX_FRAME_BYTES {
        return Err(invalid());
    }
    writer.write_all(&(bytes.len() as u32).to_be_bytes())?;
    writer.write_all(&bytes)?;
    writer.flush()
}
fn invalid() -> std::io::Error {
    std::io::Error::other(RelayErrorCode::RelayStreamInvalid)
}
