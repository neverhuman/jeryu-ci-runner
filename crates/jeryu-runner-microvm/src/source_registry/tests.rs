//! Integrate actual begin/write/finish/Drop and quota behavior in an admitted guest.
use super::*;
use sha2::{Digest, Sha256};
use std::{
    fs,
    os::unix::fs::{MetadataExt, symlink},
};

fn upload(byte: u8) -> (BundleUpload, Vec<u8>) {
    let bytes = vec![byte; 512];
    (
        BundleUpload {
            protocol_version: PROTOCOL_VERSION.into(),
            message_type: "bundle-upload".into(),
            request_id: "custody-fixture".into(),
            role: jeryu_runner_protocol::wire::v2::BundleRole::SourceBundle,
            digest: format!("sha256:{}", hex::encode(Sha256::digest(&bytes))),
            bundle_bytes: 512,
            stored_bytes: 512,
        },
        bytes,
    )
}

fn completed(registry: &Arc<SourceBundleRegistry>, byte: u8) -> UploadStage {
    let (upload, bytes) = upload(byte);
    let mut stage = registry.begin(upload).unwrap();
    stage.write_chunk(&bytes).unwrap();
    stage
}

fn usage(registry: &SourceBundleRegistry) -> (u64, usize, usize) {
    let usage = registry.usage.lock().unwrap();
    (usage.bytes, usage.objects, usage.active)
}

#[test]
#[ignore = "requires a separately admitted guest root, usable nested KVM and isolated node state"]
fn admitted_guest_registry_begin_finish_drop_collision_sync_failure_and_moved_file_custody() {
    crate::test_guest::require_admitted_guest();
    let temp = tempfile::tempdir_in("/root").unwrap();
    let node_root = temp.path().join("node");
    let source_root = temp.path().join("sources");
    fs::create_dir(&node_root).unwrap();
    fs::create_dir(&source_root).unwrap();
    let node = crate::supervisor::NodeConfig {
        runner_id: "custody-fixture".into(),
        runner_epoch: 1,
        control_plane_lease_key: ed25519_dalek::SigningKey::from_bytes(&[37; 32])
            .verifying_key()
            .to_bytes(),
        state_dir: node_root,
        capacity: 1,
        cpu_budget_vcpus: 1,
        memory_budget_mib: 512,
        disk_budget_gib: 4,
        uid_base: crate::journal::LEGACY_UID_BASE,
    }
    .open()
    .unwrap();
    let registry = SourceBundleRegistry::open(&source_root, 1, node.clone()).unwrap();
    let first = completed(&registry, 42).finish().unwrap();
    let charge = 512 + METADATA_CHARGE;
    assert_eq!(usage(&registry), (charge, 1, 0));
    assert_eq!(
        completed(&registry, 42).finish().unwrap().artifact,
        first.artifact
    );
    assert_eq!(usage(&registry), (charge, 1, 0));
    let (input, _) = upload(43);
    let mut abandoned = registry.begin(input).unwrap();
    let abandoned_id = abandoned.id.clone();
    abandoned.write_chunk(&[43; 17]).unwrap();
    drop(abandoned);
    assert!(
        !source_root
            .join(".source-staging")
            .join(format!("{abandoned_id}.json"))
            .exists()
    );
    assert_eq!(usage(&registry), (charge, 1, 0));

    let sync_failed = completed(&registry, 44);
    assert_eq!(
        sync_failed
            .finish_with_sync(|_, _, _, _| Err(failed("injected_registry_sync_failure")))
            .unwrap_err()
            .code(),
        "injected_registry_sync_failure"
    );
    assert_eq!(usage(&registry), (2 * charge, 2, 0));
    assert_eq!(
        completed(&registry, 44).finish().unwrap().artifact.digest,
        upload(44).0.digest
    );
    assert_eq!(usage(&registry), (2 * charge, 2, 0));
    assert!(registry.clean.load(Ordering::Acquire));

    let damaged = completed(&registry, 45);
    fs::write(
        source_root
            .join(".source-staging")
            .join(format!("{}.bin", damaged.id)),
        vec![46; 512],
    )
    .unwrap();
    assert_eq!(
        damaged.finish().unwrap_err().code(),
        "bundle_digest_mismatch"
    );
    assert_eq!(usage(&registry), (2 * charge, 2, 0));

    let target = source_root
        .join(&first.artifact.digest[7..])
        .join("source-bundle");
    fs::write(&target, vec![99; 512]).unwrap();
    let before = fs::metadata(&target).unwrap();
    assert_eq!(
        completed(&registry, 42).finish().unwrap_err().code(),
        "bundle_registry_collision"
    );
    assert_eq!(fs::read(&target).unwrap(), vec![99; 512]);
    let after = fs::metadata(&target).unwrap();
    assert_eq!(
        (before.ino(), before.uid(), before.mode()),
        (after.ino(), after.uid(), after.mode())
    );

    let staging_path = source_root.join(".source-staging");
    fs::rename(&staging_path, source_root.join("held-staging")).unwrap();
    let foreign = temp.path().join("foreign");
    fs::create_dir(&foreign).unwrap();
    fs::write(foreign.join("sentinel"), b"foreign retained").unwrap();
    let sentinel = fs::metadata(foreign.join("sentinel")).unwrap();
    symlink(&foreign, &staging_path).unwrap();
    completed(&registry, 47).finish().unwrap();
    assert_eq!(usage(&registry), (3 * charge, 3, 0));

    let moved = completed(&registry, 48);
    let moved_id = moved.id.clone();
    let held = source_root.join("held-staging");
    fs::rename(
        held.join(format!("{moved_id}.bin")),
        held.join("retained-ambiguous.bin"),
    )
    .unwrap();
    assert_eq!(
        moved.finish().unwrap_err().code(),
        "bundle_staging_custody_denied"
    );
    assert_eq!(usage(&registry), (4 * charge, 4, 0));
    assert!(!registry.clean.load(Ordering::Acquire));
    assert!(held.join(format!("{moved_id}.json")).exists());
    assert_eq!(
        fs::read(held.join("retained-ambiguous.bin")).unwrap(),
        vec![48; 512]
    );
    let (input, _) = upload(49);
    assert_eq!(
        registry.begin(input).err().unwrap().code(),
        "bundle_registry_reconciliation_required"
    );
    assert_eq!(
        fs::read(foreign.join("sentinel")).unwrap(),
        b"foreign retained"
    );
    let after = fs::metadata(foreign.join("sentinel")).unwrap();
    assert_eq!(
        (sentinel.ino(), sentinel.uid(), sentinel.mode()),
        (after.ino(), after.uid(), after.mode())
    );
    drop(registry);
    drop(node);
}
