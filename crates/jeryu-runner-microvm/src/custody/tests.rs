use super::*;
use std::{
    fs,
    os::unix::fs::{MetadataExt, symlink},
};

#[test]
fn roles_reject_wrong_owners_links_types_and_permissions() {
    for role in [
        FileRole::Immutable { executable: false },
        FileRole::Configuration { private: true },
    ] {
        assert!(trusted_file(0, 0o100400, true, role));
        for (uid, mode, links) in [
            (1000, 0o100400, 1),
            (0, 0o100400, 2),
            (0, 0o040400, 1),
            (0, 0o120777, 1),
            (0, 0o100422, 1),
        ] {
            assert!(!trusted_file(uid, mode, links == 1, role));
        }
    }
    assert!(!trusted_file(
        0,
        0o100600,
        true,
        FileRole::Immutable { executable: false }
    ));
    assert!(trusted_file(
        0,
        0o100600,
        true,
        FileRole::Configuration { private: true }
    ));
    assert!(!trusted_file(
        0,
        0o100444,
        true,
        FileRole::Configuration { private: true }
    ));
    assert!(!trusted_file(
        0,
        0o100444,
        true,
        FileRole::Immutable { executable: true }
    ));
}

#[test]
fn traversal_and_leaf_links_are_refused_without_touching_sentinels() {
    for path in ["relative", "/../", "/tmp"] {
        assert!(Directory::open(Path::new(path)).is_err());
    }
    let temp = tempfile::tempdir().unwrap();
    let fd = open(
        temp.path(),
        OFlags::RDONLY | OFlags::DIRECTORY,
        Mode::empty(),
    )
    .unwrap();
    let directory = Directory { fd };
    let sentinel = temp.path().join("sentinel");
    fs::write(&sentinel, b"retained").unwrap();
    let before = fs::metadata(&sentinel).unwrap();
    symlink(&sentinel, temp.path().join("link")).unwrap();
    symlink(temp.path(), temp.path().join("linked-directory")).unwrap();
    assert!(
        directory
            .open_directory(Path::new("linked-directory"))
            .is_err()
    );
    for name in ["link", "../sentinel", "/sentinel", "a/b"] {
        assert!(
            directory
                .open_file(
                    Path::new(name),
                    FileRole::Configuration { private: false },
                    64
                )
                .is_err()
        );
    }
    assert!(
        directory
            .create_immutable(Path::new("link"), b"changed")
            .is_err()
    );
    assert_eq!(fs::read(&sentinel).unwrap(), b"retained");
    let after = fs::metadata(&sentinel).unwrap();
    assert_eq!(
        (before.ino(), before.uid(), before.mode()),
        (after.ino(), after.uid(), after.mode())
    );
}

#[test]
fn exclusive_writes_remain_anchored_after_parent_path_replacement() {
    let base = tempfile::tempdir().unwrap();
    let original = base.path().join("original");
    let moved = base.path().join("moved");
    let foreign = base.path().join("foreign");
    fs::create_dir(&original).unwrap();
    fs::create_dir(&foreign).unwrap();
    fs::write(foreign.join("uid-range.json"), b"foreign").unwrap();
    let directory = Directory {
        fd: open(&original, OFlags::RDONLY | OFlags::DIRECTORY, Mode::empty()).unwrap(),
    };
    fs::rename(&original, &moved).unwrap();
    symlink(&foreign, &original).unwrap();
    directory
        .create_immutable(Path::new("uid-range.json"), b"owned")
        .unwrap();
    assert!(
        directory
            .create_immutable(Path::new("uid-range.json"), b"replacement")
            .is_err()
    );
    assert_eq!(fs::read(moved.join("uid-range.json")).unwrap(), b"owned");
    assert_eq!(
        fs::read(foreign.join("uid-range.json")).unwrap(),
        b"foreign"
    );
}

#[test]
fn bounded_reads_detect_growth_and_do_not_reopen_replaced_names() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config");
    fs::write(&path, b"original").unwrap();
    let held = File::open(&path).unwrap();
    fs::rename(&path, temp.path().join("retained")).unwrap();
    fs::write(&path, b"replacement").unwrap();
    assert_eq!(read_bounded(held, 8).unwrap(), b"original");
    assert!(read_bounded(File::open(&path).unwrap(), 8).is_err());
}

#[test]
fn boot_copies_verify_bytes_force_modes_and_refuse_existing_destinations() {
    use sha2::{Digest, Sha256};
    let temp = tempfile::tempdir().unwrap();
    let directory = Directory {
        fd: open(
            temp.path(),
            OFlags::RDONLY | OFlags::DIRECTORY,
            Mode::empty(),
        )
        .unwrap(),
    };
    let bytes = b"verified artifact";
    let digest = format!("sha256:{}", hex::encode(Sha256::digest(bytes)));
    directory
        .copy_immutable(
            Path::new("kernel"),
            &mut bytes.as_slice(),
            &digest,
            bytes.len() as u64,
        )
        .unwrap();
    let before = fs::metadata(temp.path().join("kernel")).unwrap();
    assert_eq!(before.mode() & 0o777, 0o444);
    assert!(
        directory
            .copy_immutable(
                Path::new("kernel"),
                &mut b"replacement".as_slice(),
                &digest,
                bytes.len() as u64
            )
            .is_err()
    );
    assert_eq!(fs::read(temp.path().join("kernel")).unwrap(), bytes);
    assert_eq!(
        fs::metadata(temp.path().join("kernel")).unwrap().ino(),
        before.ino()
    );
    for (name, mut content, length) in [
        (
            "bad-hash",
            b"modified artifact".as_slice(),
            bytes.len() as u64,
        ),
        ("grown", bytes.as_slice(), 3),
        ("short", bytes.as_slice(), 1024),
    ] {
        assert!(
            directory
                .copy_immutable(Path::new(name), &mut content, &digest, length)
                .is_err()
        );
    }
}

fn fixture_directory(path: &Path) -> Directory {
    Directory {
        fd: open(path, OFlags::RDONLY | OFlags::DIRECTORY, Mode::empty()).unwrap(),
    }
}

#[test]
fn promotion_and_removal_use_held_directories_after_both_parent_paths_are_replaced() {
    let base = tempfile::tempdir().unwrap();
    for name in ["staging", "target", "foreign-staging", "foreign-target"] {
        fs::create_dir(base.path().join(name)).unwrap();
    }
    let original = base.path().join("staging");
    let target = base.path().join("target");
    let staging = fixture_directory(&original);
    let destination = fixture_directory(&target);
    let data = Path::new("data.bin");
    let name = Path::new("source-bundle");
    let mut held = staging.create_private(data).unwrap();
    held.write_all(b"verified source").unwrap();
    held.sync_all().unwrap();
    assert_eq!(held.metadata().unwrap().mode() & 0o777, 0o600);
    fs::write(
        base.path().join("foreign-staging/data.bin"),
        b"foreign source",
    )
    .unwrap();
    fs::write(
        base.path().join("foreign-target/source-bundle"),
        b"foreign target",
    )
    .unwrap();
    let source_before = fs::metadata(base.path().join("foreign-staging/data.bin")).unwrap();
    let target_before = fs::metadata(base.path().join("foreign-target/source-bundle")).unwrap();
    fs::rename(&original, base.path().join("retained-staging")).unwrap();
    fs::rename(&target, base.path().join("retained-target")).unwrap();
    symlink(base.path().join("foreign-staging"), &original).unwrap();
    symlink(base.path().join("foreign-target"), &target).unwrap();
    assert!(
        staging
            .promote_file(data, &held, &destination, name)
            .unwrap()
    );
    destination.require_file_identity(name, &held).unwrap();
    assert_eq!(
        fs::read(base.path().join("retained-target/source-bundle")).unwrap(),
        b"verified source"
    );
    assert!(!base.path().join("retained-staging/data.bin").exists());
    let duplicate = staging.create_private(data).unwrap();
    let before_duplicate = held.metadata().unwrap();
    assert!(
        !staging
            .promote_file(data, &duplicate, &destination, name)
            .unwrap()
    );
    staging.remove_file(data, &duplicate).unwrap();
    staging.sync().unwrap();
    assert_eq!(
        fs::read(base.path().join("retained-target/source-bundle")).unwrap(),
        b"verified source"
    );
    let after_duplicate = held.metadata().unwrap();
    assert_eq!(
        (
            before_duplicate.ino(),
            before_duplicate.uid(),
            before_duplicate.mode()
        ),
        (
            after_duplicate.ino(),
            after_duplicate.uid(),
            after_duplicate.mode()
        )
    );
    for (path, bytes, before) in [
        (
            "foreign-staging/data.bin",
            b"foreign source".as_slice(),
            source_before,
        ),
        (
            "foreign-target/source-bundle",
            b"foreign target".as_slice(),
            target_before,
        ),
    ] {
        let path = base.path().join(path);
        let after = fs::metadata(&path).unwrap();
        assert_eq!(fs::read(&path).unwrap(), bytes);
        assert_eq!(
            (before.dev(), before.ino(), before.uid(), before.mode()),
            (after.dev(), after.ino(), after.uid(), after.mode())
        );
    }
}

#[test]
fn substituted_leaves_and_hardlinks_do_not_authorize_promotion_or_removal() {
    let temp = tempfile::tempdir().unwrap();
    let directory = fixture_directory(temp.path());
    let data = Path::new("data");
    let held = directory.create_private(data).unwrap();
    fs::rename(temp.path().join(data), temp.path().join("retained")).unwrap();
    fs::write(temp.path().join(data), b"foreign replacement").unwrap();
    let before = fs::metadata(temp.path().join(data)).unwrap();
    assert!(
        directory
            .promote_file(data, &held, &directory, Path::new("target"))
            .is_err()
    );
    assert!(directory.remove_file(data, &held).is_err());
    assert!(!temp.path().join("target").exists());
    assert_eq!(
        fs::read(temp.path().join(data)).unwrap(),
        b"foreign replacement"
    );
    let after = fs::metadata(temp.path().join(data)).unwrap();
    assert_eq!(
        (before.ino(), before.uid(), before.mode()),
        (after.ino(), after.uid(), after.mode())
    );
    fs::hard_link(temp.path().join("retained"), temp.path().join("linked")).unwrap();
    assert!(
        directory
            .promote_file(
                Path::new("retained"),
                &held,
                &directory,
                Path::new("target")
            )
            .is_err()
    );
    assert!(directory.remove_file(Path::new("retained"), &held).is_err());
}

#[test]
fn private_creation_refuses_links_and_enumeration_keeps_its_bound() {
    let temp = tempfile::tempdir().unwrap();
    let directory = fixture_directory(temp.path());
    fs::write(temp.path().join("sentinel"), b"retained").unwrap();
    symlink(temp.path().join("sentinel"), temp.path().join("link")).unwrap();
    assert!(directory.create_private(Path::new("link")).is_err());
    assert!(directory.create_private(Path::new("../escape")).is_err());
    assert!(directory.entries_bounded(1).is_err());
    assert_eq!(directory.entries_bounded(2).unwrap().len(), 2);
    assert_eq!(fs::read(temp.path().join("sentinel")).unwrap(), b"retained");
}

#[test]
fn directory_promotion_preserves_collisions_and_removal_refuses_swaps_and_nonempty_objects() {
    let temp = tempfile::tempdir().unwrap();
    let root = fixture_directory(temp.path());
    for name in ["staging", "target"] {
        fs::create_dir(temp.path().join(name)).unwrap();
    }
    let staging = fixture_directory(&temp.path().join("staging"));
    fs::write(temp.path().join("target/sentinel"), b"retained").unwrap();
    let before = fs::metadata(temp.path().join("target/sentinel")).unwrap();
    assert!(
        !root
            .promote_directory(Path::new("staging"), &staging, Path::new("target"))
            .unwrap()
    );
    assert!(root.create_directory(Path::new("target")).is_err());
    let after = fs::metadata(temp.path().join("target/sentinel")).unwrap();
    assert_eq!(
        fs::read(temp.path().join("target/sentinel")).unwrap(),
        b"retained"
    );
    assert_eq!(
        (before.ino(), before.uid(), before.mode()),
        (after.ino(), after.uid(), after.mode())
    );
    assert!(
        root.promote_directory(Path::new("staging"), &staging, Path::new("committed"))
            .unwrap()
    );
    let committed = temp.path().join("committed");
    fs::rename(&committed, temp.path().join("retained")).unwrap();
    symlink(temp.path().join("target"), &committed).unwrap();
    assert!(
        root.remove_directory(Path::new("committed"), &staging)
            .is_err()
    );
    assert!(
        root.promote_directory(Path::new("committed"), &staging, Path::new("another"))
            .is_err()
    );
    fs::write(temp.path().join("retained/unknown"), b"ambiguous").unwrap();
    assert!(
        root.remove_directory(Path::new("retained"), &staging)
            .is_err()
    );
    assert_eq!(
        fs::read(temp.path().join("retained/unknown")).unwrap(),
        b"ambiguous"
    );
    fs::remove_file(temp.path().join("retained/unknown")).unwrap();
    root.remove_directory(Path::new("retained"), &staging)
        .unwrap();
    assert!(
        fs::symlink_metadata(&committed)
            .unwrap()
            .file_type()
            .is_symlink()
    );
}
