//! Release signing for production runtime manifests. The signed bytes are
//! exactly `RuntimeManifest::to_json()`, the bytes a node verifies, and
//! `--verify` runs the node's own release check, `runtime_authority::production`.
//! The seed is read only from its file and never printed.
use ed25519_dalek::{Signer, SigningKey};
use jeryu_runner_microvm::runtime_authority;
use jeryu_runner_protocol::wire::v2::{RuntimeImageClass, RuntimeManifest};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    ffi::OsString,
    fs::{File, OpenOptions, Permissions},
    io::{ErrorKind, Read, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    process::ExitCode,
};
use zeroize::Zeroizing;

const USAGE: &str = "usage: jeryu-sign-runtime --manifest FILE --key SEED_FILE --out SIGNATURE_FILE
       jeryu-sign-runtime --verify --manifest FILE --public-key FILE --signature FILE
       jeryu-sign-runtime --public-key-of SEED_FILE --out PUBLIC_KEY_FILE";
/// The node refuses a configured file over 64 KiB, so nothing larger is signed.
const MAX_INPUT_BYTES: u64 = 64 * 1024;

struct Refusal(&'static str);

enum Mode {
    Help,
    Sign {
        manifest: PathBuf,
        key: PathBuf,
        out: PathBuf,
    },
    Verify {
        manifest: PathBuf,
        public_key: PathBuf,
        signature: PathBuf,
    },
    PublicKey {
        seed: PathBuf,
        out: PathBuf,
    },
}

fn main() -> ExitCode {
    let Some(mode) = parse(std::env::args_os().skip(1)) else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    let result = match mode {
        Mode::Help => {
            println!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Mode::Sign { manifest, key, out } => sign(&manifest, &key, &out).map(Some),
        Mode::Verify {
            manifest,
            public_key,
            signature,
        } => verify(&manifest, &public_key, &signature).map(Some),
        Mode::PublicKey { seed, out } => public_key_of(&seed, &out).map(|()| None),
    };
    match result {
        Ok(manifest_sha256) => {
            if let Some(digest) = manifest_sha256 {
                println!("manifest_sha256={digest}");
            }
            println!("ok");
            ExitCode::SUCCESS
        }
        Err(Refusal(code)) => {
            eprintln!("jeryu_sign_runtime_failed code={code}");
            ExitCode::FAILURE
        }
    }
}

/// Each flag takes one path and appears once; the set of flags picks the mode.
/// No flag takes key bytes, so a seed can never reach an argument list.
fn parse(mut arguments: impl Iterator<Item = OsString>) -> Option<Mode> {
    let mut paths = BTreeMap::new();
    let mut verify = false;
    while let Some(argument) = arguments.next() {
        let flag = match argument.to_str()? {
            "--help" | "-h" => return Some(Mode::Help),
            "--verify" if !verify => {
                verify = true;
                continue;
            }
            "--manifest" => "manifest",
            "--key" => "key",
            "--out" => "out",
            "--public-key" => "public-key",
            "--signature" => "signature",
            "--public-key-of" => "public-key-of",
            _ => return None,
        };
        let path = arguments
            .next()
            .filter(|value| !value.is_empty() && !value.to_string_lossy().starts_with("--"))?;
        if paths.insert(flag, PathBuf::from(path)).is_some() {
            return None;
        }
    }
    let flags: Vec<&str> = paths.keys().copied().collect();
    let mut take = |flag: &str| paths.remove(flag);
    match (verify, flags.as_slice()) {
        (false, ["key", "manifest", "out"]) => Some(Mode::Sign {
            manifest: take("manifest")?,
            key: take("key")?,
            out: take("out")?,
        }),
        (true, ["manifest", "public-key", "signature"]) => Some(Mode::Verify {
            manifest: take("manifest")?,
            public_key: take("public-key")?,
            signature: take("signature")?,
        }),
        (false, ["out", "public-key-of"]) => Some(Mode::PublicKey {
            seed: take("public-key-of")?,
            out: take("out")?,
        }),
        _ => None,
    }
}

fn sign(manifest: &Path, key: &Path, out: &Path) -> Result<String, Refusal> {
    let bytes = read_public(manifest, "runtime_sign_manifest_unreadable")?;
    let parsed =
        RuntimeManifest::from_json(&bytes).map_err(|_| Refusal("runtime_sign_manifest_invalid"))?;
    // The node verifies to_json() of what it parses. Signing only a file that
    // is already those bytes keeps the signed, pinned and installed bytes one.
    let canonical = parsed
        .to_json()
        .map_err(|_| Refusal("runtime_sign_manifest_invalid"))?;
    if canonical != bytes {
        return Err(Refusal("runtime_sign_manifest_not_canonical"));
    }
    if parsed.image_class != RuntimeImageClass::Production {
        return Err(Refusal("runtime_sign_test_image_refused"));
    }
    let key = signing_key(key)?;
    let signature = key.sign(&canonical).to_bytes();
    // The node's own check passes before a signature file exists at all.
    runtime_authority::production(&parsed, &signature, &key.verifying_key().to_bytes())
        .map_err(|error| Refusal(error.code()))?;
    write_new(out, &signature)?;
    Ok(hex::encode(Sha256::digest(&bytes)))
}

fn verify(manifest: &Path, public_key: &Path, signature: &Path) -> Result<String, Refusal> {
    // Parsed and refused with the codes the node logs for its configured files.
    let bytes = read_public(manifest, "runtime_sign_manifest_unreadable")?;
    let parsed = RuntimeManifest::from_json(&bytes)
        .map_err(|_| Refusal("session_runtime_manifest_invalid"))?;
    let signature: [u8; 64] = read_public(signature, "runtime_sign_signature_unreadable")?
        .try_into()
        .map_err(|_| Refusal("session_runtime_signature_invalid"))?;
    let key: [u8; 32] = read_public(public_key, "runtime_sign_public_key_unreadable")?
        .try_into()
        .map_err(|_| Refusal("session_release_key_invalid"))?;
    runtime_authority::production(&parsed, &signature, &key)
        .map_err(|error| Refusal(error.code()))?;
    Ok(hex::encode(Sha256::digest(&bytes)))
}

fn public_key_of(seed: &Path, out: &Path) -> Result<(), Refusal> {
    write_new(out, &signing_key(seed)?.verifying_key().to_bytes())
}

/// O_NONBLOCK keeps a FIFO from stalling the open; regular reads ignore it.
fn open_flags() -> i32 {
    nix::libc::O_NOFOLLOW | nix::libc::O_CLOEXEC | nix::libc::O_NONBLOCK
}

fn read_public(path: &Path, unreadable: &'static str) -> Result<Vec<u8>, Refusal> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(nix::libc::O_CLOEXEC | nix::libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| Refusal(unreadable))?;
    let mut bytes = Vec::new();
    file.take(MAX_INPUT_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Refusal(unreadable))?;
    if bytes.len() as u64 > MAX_INPUT_BYTES {
        return Err(Refusal(unreadable));
    }
    Ok(bytes)
}

/// Every check runs on the opened descriptor, so the file checked is the file read.
fn signing_key(path: &Path) -> Result<SigningKey, Refusal> {
    let denied = || Refusal("runtime_sign_key_custody_denied");
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(open_flags())
        .open(path)
        .map_err(|_| denied())?;
    let metadata = file.metadata().map_err(|_| denied())?;
    if !seed_custody_allows(
        metadata.is_file(),
        metadata.uid(),
        nix::unistd::Uid::effective().as_raw(),
        metadata.mode(),
        metadata.nlink(),
    ) {
        return Err(denied());
    }
    if metadata.len() != 32 {
        return Err(Refusal("runtime_sign_key_invalid"));
    }
    let mut seed = Zeroizing::new([0; 32]);
    let mut extra = [0; 1];
    // A file that grew after the check is refused, never half read.
    if file.read_exact(seed.as_mut()).is_err() || !matches!(file.read(&mut extra), Ok(0)) {
        return Err(Refusal("runtime_sign_key_invalid"));
    }
    Ok(SigningKey::from_bytes(&seed))
}

/// A seed is a regular file of the invoking user's own, with one link and no
/// group or other permission bits.
fn seed_custody_allows(regular: bool, owner: u32, invoker: u32, mode: u32, links: u64) -> bool {
    regular && owner == invoker && mode & 0o077 == 0 && links == 1
}

/// Create-only: an existing name, a dangling link included, is never replaced.
fn write_new(path: &Path, bytes: &[u8]) -> Result<(), Refusal> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o644)
        .custom_flags(nix::libc::O_NOFOLLOW | nix::libc::O_CLOEXEC)
        .open(path)
        .map_err(|error| {
            Refusal(match error.kind() {
                ErrorKind::AlreadyExists => "runtime_sign_output_exists",
                _ => "runtime_sign_output_failed",
            })
        })?;
    // Public bytes at exactly 0644 whatever the umask, synced with their directory.
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let written = file
        .set_permissions(Permissions::from_mode(0o644))
        .and_then(|()| file.write_all(bytes))
        .and_then(|()| file.sync_all())
        .and_then(|()| File::open(parent)?.sync_all());
    if written.is_err() {
        // create_new proved this run made the file, so removing it loses nothing.
        let _ = std::fs::remove_file(path);
        return Err(Refusal("runtime_sign_output_failed"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seed_custody_requires_own_regular_private_single_link_file() {
        assert!(seed_custody_allows(true, 1000, 1000, 0o100600, 1));
        assert!(seed_custody_allows(true, 1000, 1000, 0o100400, 1));
        for (regular, owner, mode, links) in [
            (true, 0, 0o100600, 1),
            (true, 1001, 0o100600, 1),
            (true, 1000, 0o100640, 1),
            (true, 1000, 0o100604, 1),
            (true, 1000, 0o100610, 1),
            (true, 1000, 0o100600, 2),
            (false, 1000, 0o020600, 1),
        ] {
            assert!(
                !seed_custody_allows(regular, owner, 1000, mode, links),
                "{owner} {mode:o} {links}"
            );
        }
    }

    #[test]
    fn modes_take_exactly_their_flags_and_never_a_seed_value() {
        let parse_all =
            |arguments: &[&str]| parse(arguments.iter().map(|argument| OsString::from(*argument)));
        assert!(matches!(
            parse_all(&["--out", "s", "--key", "k", "--manifest", "m"]),
            Some(Mode::Sign { .. })
        ));
        assert!(matches!(
            parse_all(&[
                "--signature",
                "s",
                "--verify",
                "--public-key",
                "p",
                "--manifest",
                "m"
            ]),
            Some(Mode::Verify { .. })
        ));
        assert!(matches!(
            parse_all(&["--public-key-of", "k", "--out", "p"]),
            Some(Mode::PublicKey { .. })
        ));
        for refused in [
            &[][..],
            &["--manifest", "m", "--key", "k"],
            &["--manifest", "m", "--key", "k", "--out", "s", "--out", "t"],
            &["--manifest", "m", "--key", "k", "--out", "s", "--verify"],
            &["--verify", "--verify", "--manifest", "m"],
            &["--manifest", "m", "--seed", "00", "--out", "s"],
            &["--manifest", "m", "--key", "--out", "s"],
            &["--manifest", "m", "--key", "", "--out", "s"],
            &["--public-key-of", "k", "--out", "p", "extra"],
        ] {
            assert!(parse_all(refused).is_none(), "{refused:?}");
        }
    }
}
