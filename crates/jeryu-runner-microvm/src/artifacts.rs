//! Signature- and digest-bound runtime admission. The public verification key is
//! installed by release operations, separately from manifests and databases.
use ed25519_dalek::{Signature, VerifyingKey};
use jeryu_runner_core::{RunnerError, RunnerResult};
use jeryu_runner_protocol::wire::v2::{
    ArtifactIdentity, RuntimeArchitecture, RuntimeManifest, WorkspaceSource,
};
use sha2::{Digest, Sha256};
use std::fs::{File, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};

#[derive(Debug, Clone)]
pub struct VerifiedRuntime {
    manifest: RuntimeManifest,
    firecracker: PathBuf,
    jailer: PathBuf,
    kernel: PathBuf,
    rootfs: PathBuf,
    store: PathBuf,
}

impl VerifiedRuntime {
    /// A valid release signature admits identities. Every referenced artifact
    /// must also be immutable, root-owned, and match its signed digest.
    pub fn admit(
        manifest: RuntimeManifest,
        signature: &[u8; 64],
        release_key: &[u8; 32],
        store: &Path,
    ) -> RunnerResult<Self> {
        let canonical = manifest
            .to_json()
            .map_err(|_| denied("runtime_manifest_invalid"))?;
        let key = VerifyingKey::from_bytes(release_key)
            .map_err(|_| denied("runtime_signature_invalid"))?;
        key.verify_strict(&canonical, &Signature::from_bytes(signature))
            .map_err(|_| denied("runtime_signature_invalid"))?;
        let architecture = if cfg!(target_arch = "x86_64") {
            RuntimeArchitecture::X86_64
        } else if cfg!(target_arch = "aarch64") {
            RuntimeArchitecture::Aarch64
        } else {
            return Err(denied("runtime_architecture_unsupported"));
        };
        if manifest.architecture != architecture {
            return Err(denied("runtime_architecture_mismatch"));
        }
        trusted_directory(store)?;
        let firecracker = verify_artifact(store, "firecracker", &manifest.firecracker, true)?;
        let jailer = verify_artifact(store, "jailer", &manifest.jailer, true)?;
        let kernel = verify_artifact(store, "kernel", &manifest.kernel, false)?;
        let rootfs = verify_artifact(store, "rootfs", &manifest.rootfs, false)?;
        for (role, artifact) in [
            ("guestd", &manifest.guestd),
            ("agent", &manifest.agent),
            ("toolchain", &manifest.toolchain),
        ] {
            verify_artifact(store, role, artifact, false)?;
        }
        Ok(Self {
            manifest,
            firecracker,
            jailer,
            kernel,
            rootfs,
            store: store.to_path_buf(),
        })
    }

    pub fn manifest(&self) -> &RuntimeManifest {
        &self.manifest
    }
    pub(crate) fn workspace_bundle(
        &self,
        source: &WorkspaceSource,
    ) -> RunnerResult<Option<PathBuf>> {
        let WorkspaceSource::GitBundle {
            bundle,
            bundle_bytes,
            ..
        } = source
        else {
            return Ok(None);
        };
        let path = verify_artifact(&self.store, "source-bundle", bundle, false)?;
        if std::fs::metadata(&path)?.len() != bundle_bytes.div_ceil(512) * 512 {
            return Err(denied("workspace_bundle_size_mismatch"));
        }
        Ok(Some(path))
    }
    pub(crate) fn firecracker(&self) -> &Path {
        &self.firecracker
    }
    pub(crate) fn jailer(&self) -> &Path {
        &self.jailer
    }
    pub(crate) fn kernel(&self) -> &Path {
        &self.kernel
    }
    pub(crate) fn rootfs(&self) -> &Path {
        &self.rootfs
    }
}

fn verify_artifact(
    store: &Path,
    role: &str,
    identity: &ArtifactIdentity,
    executable: bool,
) -> RunnerResult<PathBuf> {
    let digest = identity
        .digest
        .strip_prefix("sha256:")
        .ok_or_else(|| denied("runtime_digest_invalid"))?;
    let directory = store.join(digest);
    trusted_directory(&directory)?;
    let path = directory.join(role);
    let mut file = trusted_file(&path, executable)?;
    if sha256_reader(&mut file)? != identity.digest {
        return Err(denied("runtime_digest_mismatch"));
    }
    Ok(path)
}

pub fn sha256_reader(reader: &mut impl Read) -> RunnerResult<String> {
    let mut digest = Sha256::new();
    let mut bytes = [0; 64 * 1024];
    loop {
        let length = reader.read(&mut bytes)?;
        if length == 0 {
            break;
        }
        digest.update(&bytes[..length]);
    }
    Ok(format!("sha256:{}", hex::encode(digest.finalize())))
}

pub(crate) fn trusted_directory(path: &Path) -> RunnerResult<()> {
    if !path.is_absolute() {
        return Err(denied("runtime_path_denied"));
    }
    let mut current = PathBuf::new();
    for component in path.components() {
        match component {
            Component::RootDir | Component::Normal(_) => current.push(component),
            _ => return Err(denied("runtime_path_denied")),
        }
        let meta = std::fs::symlink_metadata(&current)?;
        if !meta.is_dir() || meta.uid() != 0 || meta.mode() & 0o022 != 0 {
            return Err(denied("runtime_custody_denied"));
        }
    }
    Ok(())
}

/// Service configuration can reuse registry custody checks without admitting
/// caller-supplied executable paths or weakening artifact verification.
pub fn verify_trusted_directory(path: &Path) -> RunnerResult<()> {
    trusted_directory(path)
}

pub(crate) fn trusted_file(path: &Path, executable: bool) -> RunnerResult<File> {
    trusted_directory(path.parent().ok_or_else(|| denied("runtime_path_denied"))?)?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(nix::libc::O_NOFOLLOW)
        .open(path)?;
    let meta = file.metadata()?;
    if !meta.is_file()
        || meta.nlink() != 1
        || meta.uid() != 0
        || meta.mode() & 0o222 != 0
        || (executable && meta.mode() & 0o111 == 0)
    {
        return Err(denied("runtime_custody_denied"));
    }
    Ok(file)
}

fn denied(code: &'static str) -> RunnerError {
    RunnerError::new(code, "runtime admission failed")
}
