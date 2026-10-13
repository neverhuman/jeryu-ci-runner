//! Authenticated canonical sparse disks. Holes are implicit zero blocks, never
//! filesystem paths. Each record binds its offset, length, sequence and kind.
use ring::{
    aead,
    rand::{SecureRandom, SystemRandom},
};
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
};
use zeroize::Zeroizing;

const CHUNK: u64 = 1024 * 1024;
const MAX_BYTES: u64 = 1024 * 1024 * 1024 * 1024;
const MAGIC: &[u8; 8] = b"JERYUCP2";
const DOMAIN: &[u8] = b"jeryu.checkpoint.sparse.v2\0";
const PLAIN_DOMAIN: &[u8] = b"jeryu.checkpoint.sparse.plaintext.v2\0";
const TAG: usize = 16;

pub(super) fn maximum_size(bytes: u64) -> std::io::Result<u64> {
    if bytes == 0 || bytes > MAX_BYTES {
        return Err(failed());
    }
    bytes
        .checked_add(bytes.div_ceil(CHUNK).checked_mul(32).ok_or_else(failed)?)
        .and_then(|n| n.checked_add(56))
        .ok_or_else(failed)
}

pub(super) fn encrypt(
    source: &mut File,
    target: &mut impl Write,
    raw_key: &[u8; 32],
    bytes: u64,
    binding: &[u8],
) -> std::io::Result<(String, String)> {
    encrypt_using(source, target, raw_key, bytes, binding, next_data)
}

/// An unsupported extent operation switches only traversal to dense; it never
/// rewinds the output, digest or nonce sequence, including after partial output.
fn encrypt_using(
    source: &mut File,
    target: &mut impl Write,
    raw_key: &[u8; 32],
    bytes: u64,
    binding: &[u8],
    mut extent: impl FnMut(&File, u64, u64) -> std::io::Result<Option<u64>>,
) -> std::io::Result<(String, String)> {
    maximum_size(bytes)?;
    if source.metadata()?.len() != bytes {
        return Err(failed());
    }
    let mut header = [0; 24];
    header[..8].copy_from_slice(MAGIC);
    header[8..16].copy_from_slice(&bytes.to_be_bytes());
    SystemRandom::new()
        .fill(&mut header[16..])
        .map_err(|_| failed())?;
    let key = key(raw_key)?;
    let aad = associated(&header, binding);
    let mut plain_hash = plaintext_hash(bytes);
    let mut cipher_hash = Sha256::new();
    target.write_all(&header)?;
    cipher_hash.update(header);
    let mut cursor = 0;
    let mut sequence = 0_u32;
    let mut dense = false;
    while cursor < bytes {
        let offset = if dense {
            cursor
        } else {
            match extent(source, cursor, bytes) {
                Ok(Some(offset)) => offset,
                Ok(None) => break,
                Err(e) if unsupported(&e) => {
                    dense = true;
                    cursor
                }
                Err(e) => return Err(e),
            }
        };
        if offset < cursor || offset >= bytes || offset % CHUNK != 0 {
            return Err(failed());
        }
        let length = (bytes - offset).min(CHUNK) as usize;
        let mut buffer = Zeroizing::new(Vec::with_capacity(length + TAG));
        buffer.resize(length, 0);
        source.seek(SeekFrom::Start(offset))?;
        source.read_exact(&mut buffer)?;
        cursor = offset + length as u64;
        if buffer.iter().all(|&b| b == 0) {
            continue;
        }
        let meta = descriptor(offset, length as u32, sequence);
        plain_hash.update(&meta[..12]);
        plain_hash.update(buffer.as_slice());
        key.seal_in_place_append_tag(
            nonce(&header, sequence),
            aead::Aad::from(record_aad(&aad, &meta, 0)),
            &mut *buffer,
        )
        .map_err(|_| failed())?;
        target.write_all(&meta)?;
        target.write_all(buffer.as_slice())?;
        cipher_hash.update(meta);
        cipher_hash.update(buffer.as_slice());
        sequence = sequence.checked_add(1).ok_or_else(failed)?;
    }
    if source.metadata()?.len() != bytes {
        return Err(failed());
    }
    let meta = descriptor(bytes, 0, sequence);
    let mut end = Vec::new();
    key.seal_in_place_append_tag(
        nonce(&header, sequence),
        aead::Aad::from(record_aad(&aad, &meta, 1)),
        &mut end,
    )
    .map_err(|_| failed())?;
    target.write_all(&meta)?;
    target.write_all(&end)?;
    cipher_hash.update(meta);
    cipher_hash.update(&end);
    Ok((digest(plain_hash), digest(cipher_hash)))
}

pub(super) fn decrypt(
    source: &mut impl Read,
    target: &mut File,
    raw_key: &[u8; 32],
    bytes: u64,
    binding: &[u8],
    expected_plain: &str,
    expected_cipher: &str,
) -> std::io::Result<()> {
    decode(
        source,
        Some(target),
        raw_key,
        bytes,
        binding,
        expected_plain,
        expected_cipher,
    )
}

/// Authenticate the same bounded format without materializing any plaintext.
pub(super) fn verify(
    source: &mut impl Read,
    raw_key: &[u8; 32],
    bytes: u64,
    binding: &[u8],
    expected_plain: &str,
    expected_cipher: &str,
) -> std::io::Result<()> {
    decode(
        source,
        None,
        raw_key,
        bytes,
        binding,
        expected_plain,
        expected_cipher,
    )
}

fn decode(
    source: &mut impl Read,
    mut target: Option<&mut File>,
    raw_key: &[u8; 32],
    bytes: u64,
    binding: &[u8],
    expected_plain: &str,
    expected_cipher: &str,
) -> std::io::Result<()> {
    maximum_size(bytes)?;
    let mut header = [0; 24];
    source.read_exact(&mut header)?;
    if &header[..8] != MAGIC || header[8..16] != bytes.to_be_bytes() {
        return Err(failed());
    }
    let key = key(raw_key)?;
    let aad = associated(&header, binding);
    let mut plain_hash = plaintext_hash(bytes);
    let mut cipher_hash = Sha256::new();
    cipher_hash.update(header);
    if let Some(target) = &mut target {
        // The caller owns this new exact successor disk; clear prior contents.
        target.set_len(0)?;
        target.set_len(bytes)?;
    }
    let mut sequence = 0_u32;
    let mut previous_end = 0;
    loop {
        let mut meta = [0; 16];
        source.read_exact(&mut meta)?;
        cipher_hash.update(meta);
        let offset = u64::from_be_bytes(meta[..8].try_into().map_err(|_| failed())?);
        let length = u32::from_be_bytes(meta[8..12].try_into().map_err(|_| failed())?) as usize;
        let seq = u32::from_be_bytes(meta[12..].try_into().map_err(|_| failed())?);
        if seq != sequence {
            return Err(failed());
        }
        let end = length == 0;
        if end {
            if offset != bytes {
                return Err(failed());
            }
        } else if u64::from(sequence) >= bytes.div_ceil(CHUNK)
            || offset < previous_end
            || offset >= bytes
            || offset % CHUNK != 0
            || length as u64 != (bytes - offset).min(CHUNK)
        {
            return Err(failed());
        }
        let mut buffer = Zeroizing::new(vec![0; length + TAG]);
        source.read_exact(&mut buffer)?;
        cipher_hash.update(buffer.as_slice());
        let plain = key
            .open_in_place(
                nonce(&header, sequence),
                aead::Aad::from(record_aad(&aad, &meta, u8::from(end))),
                buffer.as_mut_slice(),
            )
            .map_err(|_| failed())?;
        if plain.len() != length {
            return Err(failed());
        }
        if end {
            break;
        }
        if plain.iter().all(|&b| b == 0) {
            return Err(failed());
        }
        plain_hash.update(&meta[..12]);
        plain_hash.update(&plain);
        if let Some(target) = &mut target {
            target.seek(SeekFrom::Start(offset))?;
            target.write_all(plain)?;
        }
        previous_end = offset + length as u64;
        sequence = sequence.checked_add(1).ok_or_else(failed)?;
    }
    let mut trailing = [0];
    if source.read(&mut trailing)? != 0
        || digest(plain_hash) != expected_plain
        || digest(cipher_hash) != expected_cipher
    {
        return Err(failed());
    }
    Ok(())
}

/// Filesystem extent hints only select blocks to inspect; block contents decide
/// the canonical format. Never follow guest filesystem metadata on the host.
fn next_data(source: &File, cursor: u64, bytes: u64) -> std::io::Result<Option<u64>> {
    use nix::{
        errno::Errno,
        unistd::{Whence, lseek},
    };
    let data = match lseek(source, cursor as i64, Whence::SeekData) {
        Ok(data) => u64::try_from(data).map_err(|_| failed())?,
        Err(Errno::ENXIO) => return Ok(None),
        Err(e) => return Err(std::io::Error::from_raw_os_error(e as i32)),
    };
    let hole = lseek(source, data as i64, Whence::SeekHole)
        .map_err(|e| std::io::Error::from_raw_os_error(e as i32))?;
    let hole = u64::try_from(hole).map_err(|_| failed())?;
    if data < cursor || data >= bytes || hole <= data || hole > bytes {
        return Err(failed());
    }
    Ok(Some(data / CHUNK * CHUNK))
}
fn unsupported(error: &std::io::Error) -> bool {
    error.kind() == std::io::ErrorKind::Unsupported
        || matches!(
            error.raw_os_error(),
            Some(nix::libc::EINVAL | nix::libc::ENOSYS | nix::libc::EOPNOTSUPP | nix::libc::ESPIPE)
        )
}
fn key(raw: &[u8; 32]) -> std::io::Result<aead::LessSafeKey> {
    aead::UnboundKey::new(&aead::AES_256_GCM, raw)
        .map(aead::LessSafeKey::new)
        .map_err(|_| failed())
}
fn associated(header: &[u8; 24], binding: &[u8]) -> Vec<u8> {
    let mut aad = DOMAIN.to_vec();
    aad.extend_from_slice(header);
    aad.extend_from_slice(&(binding.len() as u64).to_be_bytes());
    aad.extend_from_slice(binding);
    aad
}
fn record_aad(aad: &[u8], meta: &[u8; 16], kind: u8) -> Vec<u8> {
    let mut bound = aad.to_vec();
    bound.extend_from_slice(meta);
    bound.push(kind);
    bound
}
fn nonce(header: &[u8; 24], sequence: u32) -> aead::Nonce {
    let mut nonce = [0; 12];
    nonce[..8].copy_from_slice(&header[16..]);
    nonce[8..].copy_from_slice(&sequence.to_be_bytes());
    aead::Nonce::assume_unique_for_key(nonce)
}
fn descriptor(offset: u64, length: u32, sequence: u32) -> [u8; 16] {
    let mut meta = [0; 16];
    meta[..8].copy_from_slice(&offset.to_be_bytes());
    meta[8..12].copy_from_slice(&length.to_be_bytes());
    meta[12..].copy_from_slice(&sequence.to_be_bytes());
    meta
}
fn plaintext_hash(bytes: u64) -> Sha256 {
    let mut h = Sha256::new();
    h.update(PLAIN_DOMAIN);
    h.update(bytes.to_be_bytes());
    h
}
fn digest(hash: Sha256) -> String {
    format!("sha256:{}", hex::encode(hash.finalize()))
}
fn failed() -> std::io::Error {
    std::io::Error::other("checkpoint_integrity_failed")
}
#[cfg(test)]
mod tests;
