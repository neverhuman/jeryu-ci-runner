use super::*;
use std::fs;
use std::os::unix::fs::symlink;

mod native;

#[test]
fn ciphertext_verification_is_bounded_uses_held_bytes_and_refuses_corruption() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("image");
    let bytes = vec![42; 56];
    let mut manifest = manifest();
    manifest.ciphertext_digest = digest(&bytes);
    fs::write(&path, &bytes).unwrap();
    let mut held = File::open(&path).unwrap();
    fs::rename(&path, temp.path().join("retained")).unwrap();
    fs::write(&path, b"foreign sentinel").unwrap();
    CheckpointStore::verify_ciphertext(&mut held, &manifest, 56).unwrap();
    for (length, byte) in [(55, 42), (57, 42), (56, 43)] {
        fs::write(temp.path().join("retained"), vec![byte; length]).unwrap();
        let mut image = File::open(temp.path().join("retained")).unwrap();
        assert_eq!(
            CheckpointStore::verify_ciphertext(&mut image, &manifest, 56)
                .unwrap_err()
                .code(),
            "checkpoint_image_invalid"
        );
    }
    assert_eq!(fs::read(&path).unwrap(), b"foreign sentinel");
    manifest.format = CheckpointFormat::LegacyDenseV1;
    manifest.plaintext_bytes = u64::MAX;
    assert_eq!(
        CheckpointStore::image_maximum(&manifest)
            .unwrap_err()
            .code(),
        "checkpoint_image_invalid"
    );
}

fn manifest() -> CheckpointManifest {
    let digest = format!("sha256:{}", "a".repeat(64));
    CheckpointManifest {
        format: CheckpointFormat::SparseV2,
        checkpoint_id: "a".repeat(32),
        context: SessionContext {
            session_id: "session".into(),
            generation: 1,
            run_id: "run".into(),
            owner_id: "user/alice".into(),
            repository: "test/repo".into(),
            source_revision: "a".repeat(40),
            runner_id: "node".into(),
            runner_epoch: 1,
            lease_id: "lease".into(),
            lease_epoch: 1,
            job_digest: digest.clone(),
            environment_digest: digest.clone(),
            runtime_digest: digest.clone(),
            policy_revision: digest.clone(),
        },
        workspace: None,
        plaintext_bytes: 1024,
        plaintext_digest: digest.clone(),
        ciphertext_digest: digest,
        filesystem_flushed: true,
        created_at_unix_millis: 1000,
        expires_at_unix_millis: 1000 + 7 * 24 * 60 * 60 * 1000,
    }
}

#[test]
fn manifest_digest_and_context_come_from_the_held_file_after_directory_substitution() {
    let temp = tempfile::tempdir().unwrap();
    let original = temp.path().join("checkpoint");
    let retained = temp.path().join("retained");
    let foreign = temp.path().join("foreign");
    fs::create_dir(&original).unwrap();
    fs::create_dir(&foreign).unwrap();
    let manifest = manifest();
    let encoded = manifest.to_json().unwrap();
    fs::write(original.join("manifest.json"), &encoded).unwrap();
    fs::write(foreign.join("manifest.json"), b"foreign sentinel").unwrap();
    let sentinel = fs::metadata(foreign.join("manifest.json")).unwrap();
    let held = File::open(original.join("manifest.json")).unwrap();
    fs::rename(&original, &retained).unwrap();
    symlink(&foreign, &original).unwrap();
    let (reference, decoded) =
        CheckpointStore::read_manifest(held, &manifest.checkpoint_id).unwrap();
    assert_eq!(decoded, manifest);
    assert_eq!(reference.manifest_digest, digest(&encoded));
    assert_eq!(reference.checkpoint_id, manifest.checkpoint_id);
    assert_eq!(
        fs::read(foreign.join("manifest.json")).unwrap(),
        b"foreign sentinel"
    );
    let after = fs::metadata(foreign.join("manifest.json")).unwrap();
    assert_eq!(
        (
            sentinel.dev(),
            sentinel.ino(),
            sentinel.uid(),
            sentinel.mode()
        ),
        (after.dev(), after.ino(), after.uid(), after.mode())
    );
}

#[test]
fn manifest_reads_reject_wrong_checkpoint_identity_and_growth_beyond_the_bound() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("manifest.json");
    let manifest = manifest();
    fs::write(&path, manifest.to_json().unwrap()).unwrap();
    assert_eq!(
        CheckpointStore::read_manifest(File::open(&path).unwrap(), &"b".repeat(32))
            .unwrap_err()
            .code(),
        "checkpoint_manifest_mismatch"
    );
    // A held descriptor can observe later growth, so the read itself also
    // enforces the bound rather than relying only on admission's stat result.
    let held = File::open(&path).unwrap();
    fs::write(&path, vec![b' '; 32 * 1024 + 1]).unwrap();
    assert_eq!(
        CheckpointStore::read_manifest(held, &manifest.checkpoint_id)
            .unwrap_err()
            .code(),
        "checkpoint_custody_denied"
    );
    fs::write(&path, b"{bad json").unwrap();
    assert_eq!(
        CheckpointStore::read_manifest(File::open(&path).unwrap(), &manifest.checkpoint_id)
            .unwrap_err()
            .code(),
        "checkpoint_manifest_invalid"
    );
}
