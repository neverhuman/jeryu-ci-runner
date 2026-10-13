//! Journal crash recovery fixtures, separate from VMM/provider acceptance.
use super::*;
use crate::checkpoint::{CheckpointStore, RetainedDisk};
use std::{fs, os::unix::fs::PermissionsExt};
use zeroize::Zeroizing;

fn record() -> ResourceRecord {
    let digest = format!("sha256:{}", "a".repeat(64));
    ResourceRecord {
        resource_id: uuid::Uuid::new_v4().simple().to_string(),
        uid: 231104,
        vcpus: 1,
        artifact_bytes: 1024,
        memory_mib: 256,
        workspace_gib: 1,
        context: SessionContext {
            session_id: "session".into(),
            generation: 1,
            run_id: "run".into(),
            owner_id: "user/owner".into(),
            repository: "fixture/repo".into(),
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
        expires_at_unix_millis: 1,
        state: ResourceState::Cleaning,
        firecracker_digest: digest,
        vmm: None,
        deadline: None,
        retain_workspace: true,
        workspace_flushed: true,
        checkpoint: None,
        workspace: None,
    }
}

fn workspace(root: &Path, record: &ResourceRecord) -> File {
    let jail = root.join("j/firecracker").join(&record.resource_id);
    let directory = jail.join("root");
    fs::create_dir_all(&directory).unwrap();
    let path = directory.join("workspace");
    let mut image = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .unwrap();
    image.write_all(b"last plaintext survives refusal").unwrap();
    image.set_len(1 << 30).unwrap();
    fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
    let uid = nix::unistd::Uid::from_raw(record.uid);
    let gid = nix::unistd::Gid::from_raw(record.uid);
    for path in [&directory, &path] {
        nix::unistd::chown(path, Some(uid), Some(gid)).unwrap();
    }
    image.sync_all().unwrap();
    crate::custody::Directory::open(&jail)
        .unwrap()
        .open_workspace(record.uid, 1 << 30)
        .unwrap()
}

#[test]
#[ignore = "requires the separately admitted guest-root filesystem fixture lane"]
fn admitted_guest_persisted_checkpoint_corruption_refuses_cleanup_without_rewriting_journal() {
    crate::test_guest::require_admitted_guest();
    let temp = tempfile::tempdir_in("/root").unwrap();
    let root = temp.path();
    let journal = NodeJournal::open_with_uid_base(root, 231104).unwrap();
    let mut record = record();
    for parent in ["jeryu-guardians", "jeryu-microvm"] {
        assert!(
            !Path::new("/sys/fs/cgroup")
                .join(parent)
                .join(&record.resource_id)
                .exists()
        );
    }
    let store = CheckpointStore::open(root).unwrap();
    let image = workspace(root, &record);
    let reference = store
        .retain(
            &record.resource_id,
            &record.context,
            RetainedDisk {
                image,
                uid: record.uid,
                bytes: 1 << 30,
                filesystem_flushed: record.workspace_flushed,
                workspace: None,
            },
        )
        .unwrap();
    record.checkpoint = Some(reference.clone());
    journal.write(&record).unwrap();
    drop(crate::guardian::fence::create(root, &record).unwrap());
    // Reopen after the durable Some(checkpoint), before any plaintext deletion.
    drop(journal);
    let committed = root.join("checkpoints").join(&record.resource_id);
    let key_path = committed.join("key");
    let original_key = Zeroizing::new(fs::read(&key_path).unwrap());
    let mut damaged_key = Zeroizing::new(original_key.to_vec());
    damaged_key[0] ^= 1;
    fs::write(&key_path, damaged_key.as_slice()).unwrap();
    File::open(&key_path).unwrap().sync_all().unwrap();
    let preserved = [
        root.join("j/firecracker")
            .join(&record.resource_id)
            .join("root/workspace"),
        key_path.clone(),
        committed.join("image"),
        committed.join("manifest.json"),
        root.join("records")
            .join(format!("{}.json", record.resource_id)),
        root.join("fences")
            .join(format!("{}.lock", record.resource_id)),
    ]
    .map(|path| {
        let meta = fs::metadata(&path).unwrap();
        let identity = (meta.dev(), meta.ino(), meta.uid(), meta.mode(), meta.len());
        let hash = crate::artifacts::sha256_reader(&mut File::open(&path).unwrap()).unwrap();
        (path, identity, hash)
    });
    let journal = NodeJournal::open_with_uid_base(root, 231104).unwrap();
    assert_eq!(
        journal.cleanup(&record).unwrap_err().code(),
        "checkpoint_integrity_failed"
    );
    for (path, identity, hash) in preserved {
        let meta = fs::metadata(&path).unwrap();
        assert_eq!(
            (meta.dev(), meta.ino(), meta.uid(), meta.mode(), meta.len()),
            identity
        );
        assert!(crate::artifacts::sha256_reader(&mut File::open(path).unwrap()).unwrap() == hash);
    }
    // Repair only this synthetic fixture's key, then complete and repeat the ack.
    fs::write(&key_path, original_key.as_slice()).unwrap();
    File::open(&key_path).unwrap().sync_all().unwrap();
    assert_eq!(journal.cleanup(&record).unwrap(), Some(reference.clone()));
    assert!(journal.records().unwrap().is_empty());
    assert!(
        !root
            .join("j/firecracker")
            .join(&record.resource_id)
            .exists()
    );
    assert!(fs::read_dir(root.join("fences")).unwrap().next().is_none());
    assert_eq!(journal.cleanup(&record).unwrap(), Some(reference.clone()));
    assert_eq!(store.manifest(&reference).unwrap().context, record.context);
}
