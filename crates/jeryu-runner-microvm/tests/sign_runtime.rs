//! The release signer, driven as an operator runs it. Every seed is a random
//! throwaway written to a temporary directory that is removed with its test.
use ed25519_dalek::{Signer, SigningKey};
use jeryu_runner_microvm::runtime_authority;
use jeryu_runner_protocol::wire::v2::{
    ArtifactIdentity, FIRECRACKER_VERSION, GUEST_PROTOCOL_VERSION, RuntimeArchitecture,
    RuntimeImageClass, RuntimeManifest, RuntimeProfile,
};
use ring::rand::{SecureRandom, SystemRandom};
use sha2::{Digest, Sha256};
use std::{
    ffi::OsStr,
    fs,
    io::Write,
    os::unix::fs::{OpenOptionsExt, PermissionsExt, symlink},
    path::{Path, PathBuf},
    process::{Command, Output},
};

fn manifest(image_class: RuntimeImageClass) -> RuntimeManifest {
    let artifact = ArtifactIdentity {
        artifact_id: "synthetic".into(),
        digest: format!("sha256:{}", "a".repeat(64)),
    };
    RuntimeManifest {
        image_class,
        profile_ids: match image_class {
            RuntimeImageClass::Production => vec![RuntimeProfile::Shell],
            RuntimeImageClass::Test => vec![RuntimeProfile::Fixture, RuntimeProfile::Shell],
        },
        firecracker_version: FIRECRACKER_VERSION.into(),
        guest_protocol_version: GUEST_PROTOCOL_VERSION.into(),
        architecture: RuntimeArchitecture::X86_64,
        kernel_version: "synthetic".into(),
        firecracker: artifact.clone(),
        jailer: artifact.clone(),
        kernel: artifact.clone(),
        rootfs: artifact.clone(),
        guestd: artifact.clone(),
        agent: artifact.clone(),
        toolchain: artifact.clone(),
        environment_digest: artifact.digest.clone(),
        recipe_digest: artifact.digest.clone(),
        policy_revision: artifact.digest,
        snapshot_compatibility: "synthetic".into(),
    }
}

struct Fixture {
    dir: tempfile::TempDir,
    seeds: Vec<[u8; 32]>,
}

impl Fixture {
    fn new() -> Self {
        Self {
            dir: tempfile::tempdir().unwrap(),
            seeds: Vec::new(),
        }
    }
    fn path(&self, name: &str) -> PathBuf {
        self.dir.path().join(name)
    }
    fn write(&self, name: &str, bytes: &[u8], mode: u32) -> PathBuf {
        let path = self.path(name);
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .open(&path)
            .unwrap();
        file.set_permissions(fs::Permissions::from_mode(mode))
            .unwrap();
        file.write_all(bytes).unwrap();
        path
    }
    fn seed(&mut self, name: &str, mode: u32) -> (PathBuf, [u8; 32]) {
        let mut seed = [0; 32];
        SystemRandom::new().fill(&mut seed).unwrap();
        self.seeds.push(seed);
        (self.write(name, &seed, mode), seed)
    }
    fn manifest(&self, name: &str, image_class: RuntimeImageClass) -> (PathBuf, RuntimeManifest) {
        let parsed = manifest(image_class);
        (self.write(name, &parsed.to_json().unwrap(), 0o644), parsed)
    }
    /// Run the signer; no output may carry any seed this fixture made.
    fn run(&self, arguments: &[&dyn AsRef<OsStr>]) -> Output {
        let output = Command::new(env!("CARGO_BIN_EXE_jeryu-sign-runtime"))
            .args(arguments.iter().map(|argument| argument.as_ref()))
            .output()
            .unwrap();
        let printed = [output.stdout.as_slice(), output.stderr.as_slice()].concat();
        let text = String::from_utf8_lossy(&printed).to_lowercase();
        for seed in &self.seeds {
            assert!(!text.contains(&hex::encode(seed)), "a seed was printed");
            assert!(
                !printed.windows(32).any(|window| window == seed),
                "a seed was printed"
            );
        }
        output
    }
}

fn refusal(output: &Output) -> String {
    assert!(!output.status.success(), "accepted: {output:?}");
    let stderr = String::from_utf8(output.stderr.clone()).unwrap();
    stderr
        .trim_end()
        .strip_prefix("jeryu_sign_runtime_failed code=")
        .unwrap_or_else(|| panic!("unexpected refusal: {stderr}"))
        .to_string()
}

fn mode(path: &Path) -> u32 {
    fs::metadata(path).unwrap().permissions().mode() & 0o7777
}

#[test]
fn release_signature_passes_the_node_check_and_verify_mode() {
    let mut fx = Fixture::new();
    let (manifest_path, parsed) = fx.manifest("manifest.json", RuntimeImageClass::Production);
    let (seed, seed_bytes) = fx.seed("release.seed", 0o600);
    let signature = fx.path("manifest.sig");
    let signed = fx.run(&[
        &"--manifest",
        &manifest_path,
        &"--key",
        &seed,
        &"--out",
        &signature,
    ]);
    assert!(signed.status.success(), "{signed:?}");
    let digest = hex::encode(Sha256::digest(fs::read(&manifest_path).unwrap()));
    assert_eq!(
        String::from_utf8(signed.stdout).unwrap(),
        format!("manifest_sha256={digest}\nok\n")
    );
    assert_eq!(mode(&signature), 0o644);
    let signature_bytes: [u8; 64] = fs::read(&signature).unwrap().try_into().unwrap();
    let public = SigningKey::from_bytes(&seed_bytes)
        .verifying_key()
        .to_bytes();
    runtime_authority::production(&parsed, &signature_bytes, &public).unwrap();

    let public_path = fx.path("release.pub");
    let derived = fx.run(&[&"--public-key-of", &seed, &"--out", &public_path]);
    assert!(derived.status.success(), "{derived:?}");
    assert_eq!(fs::read(&public_path).unwrap(), public);
    assert_eq!(mode(&public_path), 0o644);

    let verified = fx.run(&[
        &"--verify",
        &"--manifest",
        &manifest_path,
        &"--public-key",
        &public_path,
        &"--signature",
        &signature,
    ]);
    assert!(verified.status.success(), "{verified:?}");
    assert_eq!(
        String::from_utf8(verified.stdout).unwrap(),
        format!("manifest_sha256={digest}\nok\n")
    );
    // The same check refuses a flipped bit and another release key.
    let mut flipped = signature_bytes;
    flipped[0] ^= 1;
    let flipped = fx.write("flipped.sig", &flipped, 0o644);
    let (other_seed, _) = fx.seed("other.seed", 0o600);
    let other_public = fx.path("other.pub");
    assert!(
        fx.run(&[&"--public-key-of", &other_seed, &"--out", &other_public])
            .status
            .success()
    );
    for (key, signature) in [(&public_path, &flipped), (&other_public, &signature)] {
        let refused = fx.run(&[
            &"--verify",
            &"--manifest",
            &manifest_path,
            &"--public-key",
            key,
            &"--signature",
            signature,
        ]);
        assert_eq!(refusal(&refused), "runtime_signature_invalid");
    }
}

#[test]
fn test_class_manifest_is_refused_and_nothing_is_written() {
    let mut fx = Fixture::new();
    let (manifest_path, parsed) = fx.manifest("test.json", RuntimeImageClass::Test);
    let (seed, seed_bytes) = fx.seed("release.seed", 0o600);
    let signature = fx.path("test.sig");
    let refused = fx.run(&[
        &"--manifest",
        &manifest_path,
        &"--key",
        &seed,
        &"--out",
        &signature,
    ]);
    assert_eq!(refusal(&refused), "runtime_sign_test_image_refused");
    assert!(!signature.exists());
    // A TEST manifest signed some other way is refused by the node's check.
    let key = SigningKey::from_bytes(&seed_bytes);
    let elsewhere = fx.write(
        "elsewhere.sig",
        &key.sign(&parsed.to_json().unwrap()).to_bytes(),
        0o644,
    );
    let public = fx.write("release.pub", &key.verifying_key().to_bytes(), 0o644);
    let verified = fx.run(&[
        &"--verify",
        &"--manifest",
        &manifest_path,
        &"--public-key",
        &public,
        &"--signature",
        &elsewhere,
    ]);
    assert_eq!(refusal(&verified), "runtime_test_image_denied");
}

#[test]
fn non_canonical_manifest_file_is_refused() {
    let mut fx = Fixture::new();
    let (seed, _) = fx.seed("release.seed", 0o600);
    let parsed = manifest(RuntimeImageClass::Production);
    let canonical = parsed.to_json().unwrap();
    let text = String::from_utf8(canonical.clone()).unwrap();
    let rest = text
        .strip_prefix("{\"image_class\":\"production\",")
        .and_then(|rest| rest.strip_suffix('}'))
        .unwrap();
    for (name, bytes) in [
        ("newline.json", [canonical.as_slice(), b"\n"].concat()),
        ("pretty.json", serde_json::to_vec_pretty(&parsed).unwrap()),
        (
            "reordered.json",
            format!("{{{rest},\"image_class\":\"production\"}}").into_bytes(),
        ),
    ] {
        // The node would parse each of these; only the canonical bytes sign.
        assert_eq!(RuntimeManifest::from_json(&bytes).unwrap(), parsed);
        let manifest_path = fx.write(name, &bytes, 0o644);
        let signature = fx.path(&format!("{name}.sig"));
        let refused = fx.run(&[
            &"--manifest",
            &manifest_path,
            &"--key",
            &seed,
            &"--out",
            &signature,
        ]);
        assert_eq!(refusal(&refused), "runtime_sign_manifest_not_canonical");
        assert!(!signature.exists());
    }
    let garbage = fx.write("garbage.json", b"{\"image_class\":", 0o644);
    let refused = fx.run(&[
        &"--manifest",
        &garbage,
        &"--key",
        &seed,
        &"--out",
        &fx.path("garbage.sig"),
    ]);
    assert_eq!(refusal(&refused), "runtime_sign_manifest_invalid");
}

/// Both modes refuse the seed with `code` and write nothing.
fn assert_seed_refused(fx: &Fixture, manifest: &Path, seed: &Path, code: &str, tag: &str) {
    let signature = fx.path(&format!("{tag}.sig"));
    let refused = fx.run(&[
        &"--manifest",
        &manifest,
        &"--key",
        &seed,
        &"--out",
        &signature,
    ]);
    assert_eq!(refusal(&refused), code, "{tag}");
    assert!(!signature.exists(), "{tag}");
    let public = fx.path(&format!("{tag}.pub"));
    let refused = fx.run(&[&"--public-key-of", &seed, &"--out", &public]);
    assert_eq!(refusal(&refused), code, "{tag}");
    assert!(!public.exists(), "{tag}");
}

#[test]
fn loose_linked_symlinked_or_wrong_length_seed_is_refused() {
    let mut fx = Fixture::new();
    let (manifest_path, _) = fx.manifest("manifest.json", RuntimeImageClass::Production);
    let (good, _) = fx.seed("good.seed", 0o600);
    let denied = "runtime_sign_key_custody_denied";
    for (name, mode) in [("group", 0o640), ("world", 0o604), ("search", 0o610)] {
        let (seed, _) = fx.seed(&format!("{name}.seed"), mode);
        assert_seed_refused(&fx, &manifest_path, &seed, denied, name);
    }
    // Each case stands alone: the symlink points at a seed that is otherwise
    // acceptable, so only following the link could make it pass.
    let link = fx.path("link.seed");
    symlink(&good, &link).unwrap();
    assert_seed_refused(&fx, &manifest_path, &link, denied, "link");
    for (name, length) in [("short", 31), ("long", 33)] {
        let seed = fx.write(&format!("{name}.seed"), &vec![7; length], 0o600);
        assert_seed_refused(&fx, &manifest_path, &seed, "runtime_sign_key_invalid", name);
    }
    let hard = fx.path("hard.seed");
    fs::hard_link(&good, &hard).unwrap();
    assert_seed_refused(&fx, &manifest_path, &good, denied, "hard");
    // Once its second link is gone the same seed signs: the refusals were custody.
    fs::remove_file(&hard).unwrap();
    let signature = fx.path("good.sig");
    let signed = fx.run(&[
        &"--manifest",
        &manifest_path,
        &"--key",
        &good,
        &"--out",
        &signature,
    ]);
    assert!(signed.status.success(), "{signed:?}");
}

#[test]
fn existing_output_is_refused_and_left_unchanged() {
    let mut fx = Fixture::new();
    let (manifest_path, _) = fx.manifest("manifest.json", RuntimeImageClass::Production);
    let (seed, _) = fx.seed("release.seed", 0o600);
    let taken = fx.write("taken", b"earlier bytes", 0o644);
    let dangling = fx.path("dangling");
    symlink(fx.path("missing"), &dangling).unwrap();
    for out in [&taken, &dangling] {
        let refused = fx.run(&[
            &"--manifest",
            &manifest_path,
            &"--key",
            &seed,
            &"--out",
            out,
        ]);
        assert_eq!(refusal(&refused), "runtime_sign_output_exists");
        let refused = fx.run(&[&"--public-key-of", &seed, &"--out", out]);
        assert_eq!(refusal(&refused), "runtime_sign_output_exists");
    }
    assert_eq!(fs::read(&taken).unwrap(), b"earlier bytes");
    assert!(fs::symlink_metadata(&dangling).unwrap().is_symlink());
    assert!(!fx.path("missing").exists());
}
