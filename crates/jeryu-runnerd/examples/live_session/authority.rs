//! Development-only signer. Never linked into either service binary.
use ed25519_dalek::{Signer, SigningKey};
use jeryu_runner_protocol::wire::v2::SessionLease;
use std::{fs, os::unix::fs::MetadataExt, path::Path};

pub fn sign(lease: &mut SessionLease) -> Result<(), Box<dyn std::error::Error>> {
    let path = Path::new(super::ROOT).join("lease-authority.seed");
    let metadata = fs::symlink_metadata(&path)?;
    if !metadata.is_file() || metadata.uid() != 0 || metadata.mode() & 0o077 != 0 {
        return Err("fixture authority custody denied".into());
    }
    let seed: [u8; 32] = fs::read(path)?
        .try_into()
        .map_err(|_| "fixture authority length")?;
    let key = SigningKey::from_bytes(&seed);
    lease.context.job_digest = lease.job_digest()?;
    lease.signature = key
        .sign(&lease.signing_bytes()?)
        .to_bytes()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    Ok(())
}
