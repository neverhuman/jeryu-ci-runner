//! Actual checkpoint filesystem operations; not Firecracker/provider acceptance.
use super::*;
use std::os::unix::fs::PermissionsExt;

fn workspace(root: &Path, id: &str) -> File {
    let parent = root.join("j/firecracker").join(id);
    fs::create_dir_all(parent.join("root")).unwrap();
    let uid = nix::unistd::Uid::from_raw(231104);
    let gid = nix::unistd::Gid::from_raw(231104);
    let path = parent.join("root/workspace");
    let image = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .open(&path)
        .unwrap();
    image.set_len(1024).unwrap();
    image
        .set_permissions(fs::Permissions::from_mode(0o600))
        .unwrap();
    fs::set_permissions(parent.join("root"), fs::Permissions::from_mode(0o700)).unwrap();
    nix::unistd::chown(&path, Some(uid), Some(gid)).unwrap();
    nix::unistd::chown(&parent.join("root"), Some(uid), Some(gid)).unwrap();
    image.sync_all().unwrap();
    Directory::open(&parent)
        .unwrap()
        .open_workspace(uid.as_raw(), 1024)
        .unwrap()
}

fn disk(image: File) -> RetainedDisk<'static> {
    RetainedDisk {
        image,
        uid: 231104,
        bytes: 1024,
        filesystem_flushed: true,
        workspace: None,
    }
}

#[test]
#[ignore = "requires the separately admitted guest-root filesystem fixture lane"]
fn admitted_guest_checkpoint_retention_retry_fences_corruption_and_bounded_destruction() {
    crate::test_guest::require_admitted_guest();
    let temp = tempfile::tempdir_in("/root").unwrap();
    let root = temp.path();
    let store = CheckpointStore::open(root).unwrap();
    let id = uuid::Uuid::new_v4().simple().to_string();
    let context = manifest().context;
    let image = workspace(root, &id);
    let retry = image.try_clone().unwrap();
    let workspace_path = root.join("j/firecracker").join(&id).join("root/workspace");
    fs::rename(
        &workspace_path,
        workspace_path.with_file_name("retained-workspace"),
    )
    .unwrap();
    let sentinel = root.join("foreign-workspace");
    fs::write(&sentinel, b"foreign workspace retained").unwrap();
    let sentinel_before = fs::metadata(&sentinel).unwrap();
    symlink(&sentinel, &workspace_path).unwrap();
    let parent = Directory::open(workspace_path.parent().unwrap().parent().unwrap()).unwrap();
    assert!(parent.open_workspace(231104, 1024).is_err());
    assert_eq!(
        store
            .retain_with_sync(&id, &context, disk(image), |_| Err(failed(
                "injected_checkpoint_sync_failure"
            )))
            .unwrap_err()
            .code(),
        "injected_checkpoint_sync_failure"
    );
    // A same-length damaged key must fail retry before the journal is allowed
    // to delete the last plaintext. Check digests/identities without logging keys.
    let committed = root.join("checkpoints").join(&id);
    let key_path = committed.join("key");
    let original_key = zeroize::Zeroizing::new(fs::read(&key_path).unwrap());
    let mut damaged_key = zeroize::Zeroizing::new(original_key.to_vec());
    damaged_key[0] ^= 1;
    fs::write(&key_path, damaged_key.as_slice()).unwrap();
    let preserved = [
        workspace_path.with_file_name("retained-workspace"),
        key_path.clone(),
        committed.join("image"),
        committed.join("manifest.json"),
    ]
    .map(|path| {
        let meta = fs::metadata(&path).unwrap();
        let identity = (meta.dev(), meta.ino(), meta.uid(), meta.mode(), meta.len());
        let hash = digest(&fs::read(&path).unwrap());
        (path, identity, hash)
    });
    assert_eq!(
        store
            .retain(&id, &context, disk(retry.try_clone().unwrap()))
            .unwrap_err()
            .code(),
        "checkpoint_integrity_failed"
    );
    for (path, identity, hash) in preserved {
        let meta = fs::metadata(&path).unwrap();
        assert_eq!(
            (meta.dev(), meta.ino(), meta.uid(), meta.mode(), meta.len()),
            identity
        );
        assert_eq!(digest(&fs::read(&path).unwrap()), hash);
    }
    fs::write(&key_path, original_key.as_slice()).unwrap();
    let reference = store.retain(&id, &context, disk(retry)).unwrap();
    assert_eq!(fs::read(&sentinel).unwrap(), b"foreign workspace retained");
    let sentinel_after = fs::metadata(&sentinel).unwrap();
    assert_eq!(
        (
            sentinel_before.ino(),
            sentinel_before.uid(),
            sentinel_before.mode()
        ),
        (
            sentinel_after.ino(),
            sentinel_after.uid(),
            sentinel_after.mode()
        )
    );
    let kept = store.manifest(&reference).unwrap();
    assert!(kept.filesystem_flushed);
    assert_eq!(
        store.retained_bytes().unwrap(),
        storage_charge(1024).unwrap()
    );
    let path = root.join("checkpoints").join(&id);
    let key_digest = digest(&fs::read(path.join("key")).unwrap());
    let key_meta = fs::metadata(path.join("key")).unwrap();
    let mut foreign = context.clone();
    foreign.generation += 1;
    assert_eq!(
        store.destroy(&reference, &foreign).unwrap_err().code(),
        "checkpoint_cleanup_fenced"
    );
    fs::write(path.join("unknown"), b"retain unknown evidence").unwrap();
    assert!(store.destroy(&reference, &context).is_err());
    fs::remove_file(path.join("unknown")).unwrap();
    let cipher = fs::read(path.join("image")).unwrap();
    fs::write(path.join("image"), b"corrupt ciphertext").unwrap();
    assert_eq!(
        store.destroy(&reference, &context).unwrap_err().code(),
        "checkpoint_image_invalid"
    );
    assert_eq!(digest(&fs::read(path.join("key")).unwrap()), key_digest);
    let after = fs::metadata(path.join("key")).unwrap();
    assert_eq!(
        (key_meta.ino(), key_meta.uid(), key_meta.mode()),
        (after.ino(), after.uid(), after.mode())
    );
    fs::write(path.join("image"), &cipher).unwrap();
    fs::hard_link(path.join("key"), root.join("retained-key")).unwrap();
    assert_eq!(
        store.destroy(&reference, &context).unwrap_err().code(),
        "checkpoint_custody_denied"
    );
    fs::remove_file(root.join("retained-key")).unwrap();
    store.destroy(&reference, &context).unwrap();
    store.destroy(&reference, &context).unwrap();
    assert!(!path.exists());
    assert_eq!(store.retained_bytes().unwrap(), 0);

    let next = uuid::Uuid::new_v4().simple().to_string();
    let image = workspace(root, &next);
    let partial = root.join("checkpoints").join(format!("{next}.new"));
    fs::create_dir(&partial).unwrap();
    fs::write(partial.join("sentinel"), b"failed attempt retained").unwrap();
    let before = fs::metadata(partial.join("sentinel")).unwrap();
    assert_eq!(
        store
            .retain(&next, &context, disk(image))
            .unwrap_err()
            .code(),
        "checkpoint_staging_incomplete"
    );
    assert_eq!(
        store.retained_bytes().unwrap_err().code(),
        "checkpoint_staging_incomplete"
    );
    assert_eq!(
        fs::read(partial.join("sentinel")).unwrap(),
        b"failed attempt retained"
    );
    let after = fs::metadata(partial.join("sentinel")).unwrap();
    assert_eq!(
        (before.ino(), before.uid(), before.mode()),
        (after.ino(), after.uid(), after.mode())
    );
}
