//! Root-only K4 custody/recovery qualification. Trusted temporary byte fixtures,
//! no guest filesystem inspection and no provider credentials or processes.
use jeryu_runner_microvm::{NodeConfig, source_registry::SourceBundleRegistry};
use jeryu_runner_protocol::wire::v2::*;
use sha2::{Digest, Sha256};
use std::{
    fs,
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::Path,
};
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
const ROOT: &str = "/var/lib/jeryu-live-fixture";

fn main() -> Result<()> {
    let root = Path::new(ROOT);
    let node = NodeConfig {
        runner_id: "fixture-node".into(),
        runner_epoch: 1,
        control_plane_lease_key: fs::read(root.join("lease-authority.pub"))?
            .try_into()
            .map_err(|_| "public key length")?,
        state_dir: root.join("node"),
        capacity: 4,
        cpu_budget_vcpus: 4,
        memory_budget_mib: 2048,
        disk_budget_gib: 16,
        uid_base: jeryu_runner_microvm::journal::LEGACY_UID_BASE,
    }
    .open()?;
    let temporary = tempfile::tempdir_in(root)?;
    let store = temporary.path();
    let registry = SourceBundleRegistry::open(store, 1, node.clone())?;
    let mut bytes = vec![42; 503];
    bytes.resize(512, 0);
    let upload = metadata(&bytes, 503);
    let mut stage = registry.begin(upload.clone())?;
    for chunk in bytes.chunks(7) {
        stage.write_chunk(chunk)?;
    }
    let receipt = stage.finish()?;
    receipt.validate_for(&upload)?;
    let target = store.join(&upload.digest[7..]).join("source-bundle");
    let inode = fs::metadata(&target)?.ino();
    let mut repeat = registry.begin(upload.clone())?;
    repeat.write_chunk(&bytes)?;
    repeat.finish()?.validate_for(&upload)?;
    assert_eq!(fs::metadata(&target)?.ino(), inode);
    assert_eq!(fs::metadata(&target)?.mode() & 0o222, 0);
    assert_eq!(fs::read(&target)?, bytes);
    empty_stage(store)?;

    let mut held = Vec::new();
    for _ in 0..4 {
        held.push(registry.begin(upload.clone())?);
    }
    assert!(
        matches!(registry.begin(upload.clone()), Err(e) if e.code() == "bundle_registry_capacity_unavailable")
    );
    drop(held.pop());
    drop(registry.begin(upload.clone())?);
    drop(held);
    empty_stage(store)?;
    let mut excessive = upload.clone();
    excessive.bundle_bytes = 1 << 30;
    excessive.stored_bytes = 1 << 30;
    assert!(
        matches!(registry.begin(excessive), Err(e) if e.code() == "bundle_registry_capacity_unavailable")
    );
    empty_stage(store)?;

    let mut truncated = registry.begin(upload.clone())?;
    truncated.write_chunk(&bytes[..511])?;
    assert!(matches!(truncated.finish(), Err(e) if e.code() == "bundle_length_invalid"));
    let mut extra = registry.begin(upload.clone())?;
    assert_eq!(
        extra.write_chunk(&[0; 513]).unwrap_err().code(),
        "bundle_length_invalid"
    );
    drop(extra);
    let mut padded = registry.begin(upload.clone())?;
    let mut wrong = bytes.clone();
    wrong[503] = 1;
    assert_eq!(
        padded.write_chunk(&wrong).unwrap_err().code(),
        "bundle_padding_invalid"
    );
    drop(padded);
    wrong[503] = 0;
    wrong[502] ^= 1;
    let mut mismatch = registry.begin(upload.clone())?;
    mismatch.write_chunk(&wrong)?;
    assert!(matches!(mismatch.finish(), Err(e) if e.code() == "bundle_digest_mismatch"));
    empty_stage(store)?;

    let collision_bytes = vec![22; 512];
    let collision = metadata(&collision_bytes, 512);
    let collision_dir = store.join(&collision.digest[7..]);
    fs::create_dir(&collision_dir)?;
    let collision_file = collision_dir.join("source-bundle");
    fs::write(&collision_file, [9; 512])?;
    fs::set_permissions(&collision_file, fs::Permissions::from_mode(0o444))?;
    let mut collided = registry.begin(collision)?;
    collided.write_chunk(&collision_bytes)?;
    assert!(matches!(collided.finish(), Err(e) if e.code() == "bundle_registry_collision"));
    assert_eq!(fs::read(&collision_file)?, vec![9; 512]);
    empty_stage(store)?;
    drop(registry);

    let crash = tempfile::tempdir_in(root)?;
    let registry = SourceBundleRegistry::open(crash.path(), 1, node.clone())?;
    drop(registry);
    let staging = crash.path().join(".source-staging");
    let valid_id = "1".repeat(32);
    let corrupt_id = "2".repeat(32);
    private_write(
        &staging.join(format!("{valid_id}.json")),
        &upload.to_json()?,
    )?;
    private_write(&staging.join(format!("{valid_id}.bin")), &bytes)?;
    private_write(
        &staging.join(format!("{corrupt_id}.json")),
        b"invalid journal",
    )?;
    private_write(&staging.join(format!("{corrupt_id}.bin")), b"do not delete")?;
    private_write(&staging.join("unknown.bin"), b"unknown ownership")?;
    let blocked = SourceBundleRegistry::open(crash.path(), 1, node)?;
    assert!(!staging.join(format!("{valid_id}.json")).exists());
    assert!(!staging.join(format!("{valid_id}.bin")).exists());
    assert_eq!(
        fs::read(staging.join(format!("{corrupt_id}.bin")))?,
        b"do not delete"
    );
    assert_eq!(fs::read(staging.join("unknown.bin"))?, b"unknown ownership");
    assert!(
        matches!(blocked.begin(upload), Err(e) if e.code() == "bundle_registry_reconciliation_required")
    );
    drop(blocked);
    println!(
        "source_registry=passed immutable_idempotence=true capacity_bounded=true body_negatives=true collision_preserved=true valid_orphan_recovered=true unknown_or_corrupt_preserved=true no_provider=true"
    );
    Ok(())
}
fn metadata(bytes: &[u8], raw: u64) -> BundleUpload {
    BundleUpload {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "bundle-upload".into(),
        request_id: "registry-fixture".into(),
        role: BundleRole::SourceBundle,
        digest: format!("sha256:{}", hex::encode(Sha256::digest(bytes))),
        stored_bytes: bytes.len() as u64,
        bundle_bytes: raw,
    }
}
fn private_write(path: &Path, bytes: &[u8]) -> Result<()> {
    fs::write(path, bytes)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(())
}
fn empty_stage(store: &Path) -> Result<()> {
    for entry in fs::read_dir(store.join(".source-staging"))? {
        assert_eq!(entry?.file_name(), "registry.lock");
    }
    Ok(())
}
