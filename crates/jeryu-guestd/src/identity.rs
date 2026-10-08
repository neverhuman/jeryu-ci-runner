//! The only path read is the kernel's fixed reference to this booted binary.
use sha2::{Digest, Sha256};
use std::{
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
};

pub fn verify(expected: &str) -> std::io::Result<()> {
    check(&mut std::fs::File::open("/proc/self/exe")?, expected)
}
pub fn verify_class(
    class: jeryu_runner_protocol::wire::v2::RuntimeImageClass,
) -> std::io::Result<()> {
    for parent in ["/etc", "/etc/jeryu"] {
        let meta = std::fs::symlink_metadata(parent)?;
        if !meta.is_dir() || meta.uid() != 0 || meta.mode() & 0o022 != 0 {
            return Err(std::io::Error::other("guest_image_class_mismatch"));
        }
    }
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(nix::libc::O_NOFOLLOW)
        .open("/etc/jeryu/runtime-image-class")?;
    let meta = file.metadata()?;
    if !meta.is_file()
        || meta.uid() != 0
        || meta.nlink() != 1
        || meta.mode() & 0o222 != 0
        || meta.len() > 16
    {
        return Err(std::io::Error::other("guest_image_class_mismatch"));
    }
    check_class(file, class)
}
fn check_class(
    source: impl Read,
    class: jeryu_runner_protocol::wire::v2::RuntimeImageClass,
) -> std::io::Result<()> {
    let mut actual = Vec::with_capacity(16);
    source.take(17).read_to_end(&mut actual)?;
    let expected: &[u8] = match class {
        jeryu_runner_protocol::wire::v2::RuntimeImageClass::Production => b"production\n",
        jeryu_runner_protocol::wire::v2::RuntimeImageClass::Test => b"test\n",
    };
    if actual != expected {
        return Err(std::io::Error::other("guest_image_class_mismatch"));
    }
    Ok(())
}
fn check(source: &mut impl Read, expected: &str) -> std::io::Result<()> {
    let mut hash = Sha256::new();
    let mut buffer = [0; 65536];
    let mut bytes = 0_u64;
    loop {
        let length = source.read(&mut buffer)?;
        if length == 0 {
            break;
        }
        bytes += length as u64;
        if bytes > 64 * 1024 * 1024 {
            return Err(failed());
        }
        hash.update(&buffer[..length]);
    }
    let actual: String = hash
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    if bytes == 0 || expected != format!("sha256:{actual}") {
        return Err(failed());
    }
    Ok(())
}
fn failed() -> std::io::Error {
    std::io::Error::other("guestd_identity_mismatch")
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn altered_binary_fails_with_a_fixed_diagnostic() {
        let bytes = b"qualified-guestd";
        let digest: String = Sha256::digest(bytes)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        check(&mut bytes.as_slice(), &format!("sha256:{digest}")).unwrap();
        let error = check(
            &mut b"unqualified-sensitive-binary".as_slice(),
            &format!("sha256:{digest}"),
        )
        .unwrap_err();
        assert_eq!(error.to_string(), "guestd_identity_mismatch");
        assert!(check(&mut b"".as_slice(), &format!("sha256:{digest}")).is_err());
    }
    #[test]
    fn image_class_reads_are_bounded_and_errors_exclude_content() {
        use jeryu_runner_protocol::wire::v2::RuntimeImageClass::{Production, Test};
        check_class(b"test\n".as_slice(), Test).unwrap();
        check_class(b"production\n".as_slice(), Production).unwrap();
        for bytes in [b"test\n".as_slice(), b"unqualified-sensitive-image", b""] {
            assert_eq!(
                check_class(bytes, Production).unwrap_err().to_string(),
                "guest_image_class_mismatch"
            );
        }
        assert!(check_class(std::io::repeat(b't'), Test).is_err());
    }
}
