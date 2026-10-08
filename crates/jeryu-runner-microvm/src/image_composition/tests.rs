use super::*;
use rustix::fs::{Mode, OFlags, open};
use std::{
    fs,
    os::unix::fs::{MetadataExt, PermissionsExt, symlink},
};

fn directory(path: &Path) -> rustix::fd::OwnedFd {
    open(path, OFlags::RDONLY | OFlags::DIRECTORY, Mode::empty()).unwrap()
}

#[test]
fn root_custody_requires_physical_root_owned_directories_without_shared_write() {
    for mode in [0o040755, 0o040700, 0o040555] {
        assert!(io::trusted_metadata_for_test(0, mode));
        assert!(!io::trusted_metadata_for_test(1000, mode));
    }
    for mode in [0o040775, 0o040757, 0o100444, 0o120777] {
        assert!(!io::trusted_metadata_for_test(0, mode));
    }
    assert!(io::trusted_root(Path::new("/")).is_ok());
    assert!(io::trusted_root(Path::new("relative")).is_err());
    assert!(io::trusted_root(Path::new("/../")).is_err());
}

#[test]
fn public_composition_rejects_untrusted_staging_without_mutating_sentinel() {
    let staging = tempfile::tempdir().unwrap();
    let sentinel = staging.path().join("sentinel");
    fs::write(&sentinel, b"retained").unwrap();
    let before = fs::metadata(&sentinel).unwrap();
    for class in [RuntimeImageClass::Production, RuntimeImageClass::Test] {
        assert!(compose(staging.path(), class).is_err());
        assert_eq!(fs::read(&sentinel).unwrap(), b"retained");
        let after = fs::metadata(&sentinel).unwrap();
        assert_eq!((before.dev(), before.ino()), (after.dev(), after.ino()));
        assert!(!staging.path().join("etc").exists());
        assert!(!staging.path().join("usr").exists());
    }
}

#[test]
fn fixed_writes_force_exact_bytes_and_modes_and_reject_duplicates() {
    let staging = tempfile::tempdir().unwrap();
    let fd = directory(staging.path());
    for (name, bytes, mode) in [
        ("runtime-image-class", b"production\n".as_slice(), 0o444),
        ("agent", MOCK_AGENT, 0o555),
    ] {
        io::write_fixed(&fd, name, bytes, mode).unwrap();
        let path = staging.path().join(name);
        let before = fs::metadata(&path).unwrap();
        assert_eq!(fs::read(&path).unwrap(), bytes);
        assert_eq!(before.permissions().mode() & 0o777, mode);
        assert!(io::write_fixed(&fd, name, b"replacement", mode).is_err());
        let after = fs::metadata(&path).unwrap();
        assert_eq!((before.dev(), before.ino()), (after.dev(), after.ino()));
        assert_eq!(fs::read(&path).unwrap(), bytes);
    }
}

#[test]
fn dangling_entries_and_intermediate_links_are_never_followed_or_replaced() {
    let staging = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let fd = directory(staging.path());
    symlink(outside.path().join("missing"), staging.path().join("mock")).unwrap();
    assert!(io::entry_exists(&fd, "mock").unwrap());
    assert!(io::write_fixed(&fd, "mock", b"replacement", 0o555).is_err());
    assert!(staging.path().join("mock").is_symlink());
    assert!(!outside.path().join("missing").exists());
    symlink(outside.path(), staging.path().join("usr")).unwrap();
    assert!(io::directories(&fd, &["usr"], true).is_err());
    assert!(!outside.path().join("lib").exists());
}

#[test]
fn anchored_writes_survive_directory_name_replacement_without_touching_sibling() {
    let base = tempfile::tempdir().unwrap();
    let original = base.path().join("original");
    let moved = base.path().join("moved");
    let sibling = base.path().join("sibling");
    fs::create_dir(&original).unwrap();
    fs::create_dir(&sibling).unwrap();
    fs::write(sibling.join("marker"), b"retained").unwrap();
    let sentinel = fs::metadata(sibling.join("marker")).unwrap();
    let fd = directory(&original);
    fs::rename(&original, &moved).unwrap();
    symlink(&sibling, &original).unwrap();
    io::write_fixed(&fd, "marker", b"test\n", 0o444).unwrap();
    assert_eq!(fs::read(moved.join("marker")).unwrap(), b"test\n");
    assert_eq!(fs::read(sibling.join("marker")).unwrap(), b"retained");
    let after = fs::metadata(sibling.join("marker")).unwrap();
    assert_eq!((sentinel.dev(), sentinel.ino()), (after.dev(), after.ino()));
}
