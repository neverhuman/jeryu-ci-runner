//! Bounded authenticated chunks. A fresh key per image and a monotonic nonce
//! sequence prevent nonce reuse. Header, context and length are authenticated.
use ring::{
    aead::{self, BoundKey},
    rand::{SecureRandom, SystemRandom},
};
use sha2::{Digest, Sha256};
use std::io::{Read, Write};
use zeroize::Zeroizing;
const CHUNK: usize = 1024 * 1024;
const MAGIC: &[u8; 8] = b"JERYUCP1";
const TAG: usize = 16;

struct Counter {
    prefix: [u8; 8],
    next: u64,
}
impl aead::NonceSequence for Counter {
    fn advance(&mut self) -> Result<aead::Nonce, ring::error::Unspecified> {
        let index = u32::try_from(self.next).map_err(|_| ring::error::Unspecified)?;
        self.next += 1;
        let mut bytes = [0; 12];
        bytes[..8].copy_from_slice(&self.prefix);
        bytes[8..].copy_from_slice(&index.to_be_bytes());
        Ok(aead::Nonce::assume_unique_for_key(bytes))
    }
}
pub(super) fn random_key() -> std::io::Result<Zeroizing<[u8; 32]>> {
    let mut key = Zeroizing::new([0; 32]);
    SystemRandom::new()
        .fill(key.as_mut())
        .map_err(|_| failed())?;
    Ok(key)
}
pub(super) fn encrypt(
    source: &mut impl Read,
    target: &mut impl Write,
    raw_key: &[u8; 32],
    bytes: u64,
    binding: &[u8],
) -> std::io::Result<(String, String)> {
    let mut prefix = [0; 8];
    SystemRandom::new()
        .fill(&mut prefix)
        .map_err(|_| failed())?;
    let mut header = Vec::from(MAGIC.as_slice());
    header.extend_from_slice(&bytes.to_be_bytes());
    header.extend_from_slice(&prefix);
    let mut aad = header.clone();
    aad.extend_from_slice(binding);
    let unbound = aead::UnboundKey::new(&aead::AES_256_GCM, raw_key).map_err(|_| failed())?;
    let mut key = aead::SealingKey::new(unbound, Counter { prefix, next: 0 });
    let mut plain_hash = Sha256::new();
    let mut cipher_hash = Sha256::new();
    target.write_all(&header)?;
    cipher_hash.update(&header);
    let mut remaining = bytes;
    while remaining != 0 {
        let length = remaining.min(CHUNK as u64) as usize;
        let mut buffer = Zeroizing::new(vec![0; length]);
        source.read_exact(&mut buffer)?;
        plain_hash.update(buffer.as_slice());
        key.seal_in_place_append_tag(aead::Aad::from(aad.as_slice()), &mut *buffer)
            .map_err(|_| failed())?;
        target.write_all(buffer.as_slice())?;
        cipher_hash.update(buffer.as_slice());
        remaining -= length as u64;
    }
    let mut trailing = [0];
    if source.read(&mut trailing)? != 0 {
        return Err(failed());
    }
    Ok((digest(plain_hash), digest(cipher_hash)))
}
pub(super) fn decrypt(
    source: &mut impl Read,
    target: &mut impl Write,
    raw_key: &[u8; 32],
    bytes: u64,
    binding: &[u8],
    expected_plain: &str,
    expected_cipher: &str,
) -> std::io::Result<()> {
    let mut header = [0; 24];
    source.read_exact(&mut header)?;
    if &header[..8] != MAGIC || header[8..16] != bytes.to_be_bytes() {
        return Err(failed());
    }
    let mut prefix = [0; 8];
    prefix.copy_from_slice(&header[16..]);
    let mut aad = header.to_vec();
    aad.extend_from_slice(binding);
    let unbound = aead::UnboundKey::new(&aead::AES_256_GCM, raw_key).map_err(|_| failed())?;
    let mut key = aead::OpeningKey::new(unbound, Counter { prefix, next: 0 });
    let mut plain_hash = Sha256::new();
    let mut cipher_hash = Sha256::new();
    cipher_hash.update(header);
    let mut remaining = bytes;
    while remaining != 0 {
        let length = remaining.min(CHUNK as u64) as usize;
        let mut buffer = Zeroizing::new(vec![0; length + TAG]);
        source.read_exact(&mut buffer)?;
        cipher_hash.update(buffer.as_slice());
        let plain = key
            .open_in_place(aead::Aad::from(aad.as_slice()), buffer.as_mut_slice())
            .map_err(|_| failed())?;
        if plain.len() != length {
            return Err(failed());
        }
        plain_hash.update(&plain);
        target.write_all(plain)?;
        remaining -= length as u64;
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
fn digest(hash: Sha256) -> String {
    format!("sha256:{}", hex::encode(hash.finalize()))
}
fn failed() -> std::io::Error {
    std::io::Error::other("checkpoint_integrity_failed")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    #[test]
    fn authenticated_chunks_reject_corruption_truncation_reordering_and_context_changes() {
        let source = vec![37; CHUNK * 2 + 19];
        let key = random_key().unwrap();
        let mut encrypted = vec![];
        let (plain, cipher) = encrypt(
            &mut source.as_slice(),
            &mut encrypted,
            &key,
            source.len() as u64,
            b"session-generation-1",
        )
        .unwrap();
        assert!(
            super::super::storage_charge(source.len() as u64).unwrap() >= encrypted.len() as u64
        );
        assert!(super::super::storage_charge(u64::MAX).is_err());
        let decode = |bytes: &[u8], binding: &[u8]| {
            let mut output = vec![];
            decrypt(
                &mut Cursor::new(bytes),
                &mut output,
                &key,
                source.len() as u64,
                binding,
                &plain,
                &cipher,
            )
            .map(|()| output)
        };
        assert_eq!(decode(&encrypted, b"session-generation-1").unwrap(), source);
        assert!(decode(&encrypted, b"session-generation-2").is_err());
        assert!(decode(&encrypted[..encrypted.len() - 1], b"session-generation-1").is_err());
        let mut changed = encrypted.clone();
        changed[50] ^= 1;
        assert!(decode(&changed, b"session-generation-1").is_err());
        let mut changed = encrypted.clone();
        changed[16] ^= 1;
        assert!(decode(&changed, b"session-generation-1").is_err());
        let mut changed = encrypted.clone();
        let first = encrypted[24..24 + CHUNK + TAG].to_vec();
        changed[24..24 + CHUNK + TAG]
            .copy_from_slice(&encrypted[24 + CHUNK + TAG..24 + 2 * (CHUNK + TAG)]);
        changed[24 + CHUNK + TAG..24 + 2 * (CHUNK + TAG)].copy_from_slice(&first);
        assert!(decode(&changed, b"session-generation-1").is_err());
        let mut changed = encrypted;
        changed.push(0);
        assert!(decode(&changed, b"session-generation-1").is_err());
    }
}
