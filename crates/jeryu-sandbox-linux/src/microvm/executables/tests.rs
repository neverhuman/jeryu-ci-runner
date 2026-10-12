use super::*;
use std::io::{Read, Seek, SeekFrom};

#[test]
fn executable_snapshot_keeps_bytes_after_path_swap_and_refuses_writes() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("firecracker");
    std::fs::write(&path, b"admitted executable").unwrap();
    let mut source = File::open(&path).unwrap();
    source.seek(SeekFrom::Start(5)).unwrap();
    let mut snapshot = sealed_executable(&source, 64).unwrap();
    assert_eq!(source.stream_position().unwrap(), 5);
    std::fs::rename(&path, directory.path().join("retained")).unwrap();
    std::fs::write(&path, b"substituted").unwrap();
    snapshot.seek(SeekFrom::Start(0)).unwrap();
    let mut bytes = Vec::new();
    snapshot.read_to_end(&mut bytes).unwrap();
    assert_eq!(bytes, b"admitted executable");
    assert!(snapshot.write_all(b"changed").is_err());
    assert!(snapshot.set_len(1).is_err());
    assert!(snapshot.set_len(128).is_err());
    assert!(sealed_executable(&source, 2).is_err());
}

#[test]
fn private_handoff_rejects_standard_duplicate_and_cloexec_descriptors() {
    assert!(inherited_executables([0, 1]).is_err());
    assert!(inherited_executables([64, 64]).is_err());
    let source = tempfile::tempfile().unwrap();
    let first = duplicate(&source, 64).unwrap();
    let second = duplicate(&source, 64).unwrap();
    assert!(inherited_executables([first.as_raw_fd(), second.as_raw_fd()]).is_err());
    // Rejection never closes descriptors still owned by the caller.
    assert!(first.metadata().is_ok());
    assert!(second.metadata().is_ok());
}

#[test]
fn guardian_exec_uses_the_held_binary_after_its_name_is_replaced() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("node");
    std::fs::copy("/bin/echo", &path).unwrap();
    let executable = File::open(&path).unwrap();
    std::fs::rename(&path, directory.path().join("retained-node")).unwrap();
    std::fs::write(&path, b"invalid substituted executable").unwrap();
    let (parent, child) = std::os::unix::net::UnixStream::pair().unwrap();
    let mut fence = tempfile::tempfile().unwrap();
    let mut spawned = spawn_guardian_files(
        &executable,
        child.into(),
        fence.try_clone().unwrap(),
        &executable,
        &executable,
    )
    .unwrap();
    drop(parent);
    assert!(spawned.child.wait().unwrap().success());
    fence.seek(SeekFrom::Start(0)).unwrap();
    let mut output = String::new();
    fence.read_to_string(&mut output).unwrap();
    assert_eq!(output, "--vm-guardian\n");
    assert_eq!(
        std::fs::read(&path).unwrap(),
        b"invalid substituted executable"
    );
}
