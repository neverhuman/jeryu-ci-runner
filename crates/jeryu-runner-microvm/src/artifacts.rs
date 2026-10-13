//! Signature- and digest-bound runtime admission. The public verification key is
//! installed by release operations, separately from manifests and databases.
use crate::runtime_authority;
use jeryu_runner_core::{RunnerError, RunnerResult};
use jeryu_runner_protocol::wire::v2::{
    ArtifactIdentity, RuntimeArchitecture, RuntimeManifest, WorkspaceSource,
};
use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::Read;
use std::os::unix::fs::FileExt;
use std::path::Path;
use std::sync::Arc;

#[derive(Debug, Clone)]
pub struct VerifiedRuntime {
    manifest: RuntimeManifest,
    firecracker: HeldArtifact,
    jailer: HeldArtifact,
    kernel: HeldArtifact,
    rootfs: HeldArtifact,
    store: Arc<crate::custody::Directory>,
}

#[derive(Debug, Clone)]
pub(crate) struct HeldArtifact {
    file: Arc<File>,
    digest: String,
    length: u64,
}

impl HeldArtifact {
    pub(crate) fn file(&self) -> &File {
        &self.file
    }
    pub(crate) fn len(&self) -> u64 {
        self.length
    }

    pub(crate) fn copy_into(
        &self,
        directory: &crate::custody::Directory,
        name: &Path,
    ) -> RunnerResult<()> {
        directory
            .copy_immutable(
                name,
                &mut ArtifactReader {
                    file: &self.file,
                    offset: 0,
                },
                &self.digest,
                self.length,
            )
            .map_err(|_| denied("runtime_custody_denied"))
    }
}

struct ArtifactReader<'a> {
    file: &'a File,
    offset: u64,
}
impl Read for ArtifactReader<'_> {
    fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
        let length = self.file.read_at(bytes, self.offset)?;
        self.offset = self
            .offset
            .checked_add(length as u64)
            .ok_or_else(|| std::io::Error::other("artifact size overflow"))?;
        Ok(length)
    }
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
        runtime_authority::production(&manifest, signature, release_key)?;
        Self::admit_artifacts(manifest, store)
    }

    /// Explicit development/CI service composition. This key is separately
    /// enrolled; no guest or RPC caller can select it. Never release-qualified.
    pub fn admit_test(
        manifest: RuntimeManifest,
        signature: &[u8; 64],
        release_key: &[u8; 32],
        test_key: &[u8; 32],
        store: &Path,
    ) -> RunnerResult<Self> {
        runtime_authority::test(&manifest, signature, release_key, test_key)?;
        Self::admit_artifacts(manifest, store)
    }

    fn admit_artifacts(manifest: RuntimeManifest, store: &Path) -> RunnerResult<Self> {
        // Closed declarations alone never enable a provider adapter. The fixed
        // guest registry currently qualifies only shell and test fixtures.
        if manifest.profile_ids.iter().any(|profile| {
            jeryu_runner_protocol::guest::GuestProfile::registered(profile.id()).is_err()
        }) {
            return Err(denied("runtime_profile_unqualified"));
        }
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
        let directory = Arc::new(
            crate::custody::Directory::open(store).map_err(|_| denied("runtime_custody_denied"))?,
        );
        let firecracker = verify_artifact(&directory, "firecracker", &manifest.firecracker, true)?;
        let jailer = verify_artifact(&directory, "jailer", &manifest.jailer, true)?;
        let kernel = verify_artifact(&directory, "kernel", &manifest.kernel, false)?;
        let rootfs = verify_artifact(&directory, "rootfs", &manifest.rootfs, false)?;
        for (role, artifact) in [
            ("guestd", &manifest.guestd),
            ("agent", &manifest.agent),
            ("toolchain", &manifest.toolchain),
        ] {
            verify_artifact(&directory, role, artifact, false)?;
        }
        Ok(Self {
            manifest,
            firecracker,
            jailer,
            kernel,
            rootfs,
            store: directory,
        })
    }

    pub fn manifest(&self) -> &RuntimeManifest {
        &self.manifest
    }
    pub(crate) fn workspace_bundle(
        &self,
        source: &WorkspaceSource,
    ) -> RunnerResult<Option<HeldArtifact>> {
        let WorkspaceSource::GitBundle {
            bundle,
            bundle_bytes,
            ..
        } = source
        else {
            return Ok(None);
        };
        let artifact = verify_artifact(&self.store, "source-bundle", bundle, false)?;
        if artifact.len() != bundle_bytes.div_ceil(512) * 512 {
            return Err(denied("workspace_bundle_size_mismatch"));
        }
        Ok(Some(artifact))
    }
    pub(crate) fn firecracker(&self) -> &HeldArtifact {
        &self.firecracker
    }
    pub(crate) fn jailer(&self) -> &HeldArtifact {
        &self.jailer
    }
    pub(crate) fn kernel(&self) -> &HeldArtifact {
        &self.kernel
    }
    pub(crate) fn rootfs(&self) -> &HeldArtifact {
        &self.rootfs
    }

    pub(crate) fn boot_artifact_bytes(&self) -> RunnerResult<u64> {
        self.kernel
            .len()
            .checked_add(self.rootfs.len())
            .and_then(|n| n.checked_add(self.firecracker.len()))
            .ok_or_else(|| denied("microvm_artifact_capacity_invalid"))
    }
}

fn verify_artifact(
    store: &crate::custody::Directory,
    role: &str,
    identity: &ArtifactIdentity,
    executable: bool,
) -> RunnerResult<HeldArtifact> {
    let digest = identity
        .digest
        .strip_prefix("sha256:")
        .filter(|digest| {
            digest.len() == 64
                && digest
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        })
        .ok_or_else(|| denied("runtime_digest_invalid"))?;
    let directory = store
        .open_directory(Path::new(digest))
        .map_err(|_| denied("runtime_custody_denied"))?;
    let file = directory
        .open_file(
            Path::new(role),
            crate::custody::FileRole::Immutable { executable },
            64 * (1 << 30),
        )
        .map_err(|_| denied("runtime_custody_denied"))?;
    let length = file.metadata()?.len();
    let reader = ArtifactReader {
        file: &file,
        offset: 0,
    };
    if sha256_reader(&mut reader.take(length.saturating_add(1)))? != identity.digest {
        return Err(denied("runtime_digest_mismatch"));
    }
    Ok(HeldArtifact {
        file: Arc::new(file),
        digest: identity.digest.clone(),
        length,
    })
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

pub(crate) fn sha256_descriptor(file: &File) -> RunnerResult<String> {
    let length = file.metadata()?.len();
    sha256_reader(&mut ArtifactReader { file, offset: 0 }.take(length.saturating_add(1)))
}

pub(crate) fn trusted_directory(path: &Path) -> RunnerResult<()> {
    if !path.is_absolute() {
        return Err(denied("runtime_path_denied"));
    }
    crate::custody::Directory::open(path)
        .map(|_| ())
        .map_err(|_| denied("runtime_custody_denied"))
}

/// Service configuration can reuse registry custody checks without admitting
/// caller-supplied executable paths or weakening artifact verification.
pub fn verify_trusted_directory(path: &Path) -> RunnerResult<()> {
    trusted_directory(path)
}

pub(crate) fn trusted_file(path: &Path, executable: bool) -> RunnerResult<File> {
    if !path.is_absolute() {
        return Err(denied("runtime_path_denied"));
    }
    crate::custody::open_file(
        path,
        crate::custody::FileRole::Immutable { executable },
        u64::MAX,
    )
    .map_err(|_| denied("runtime_custody_denied"))
}

pub(crate) fn denied(code: &'static str) -> RunnerError {
    RunnerError::new(code, "runtime admission failed")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Seek, SeekFrom};

    #[test]
    fn artifact_reads_keep_the_admitted_inode_and_independent_offsets() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("kernel");
        std::fs::write(&path, b"admitted").unwrap();
        let mut held = File::open(&path).unwrap();
        held.seek(SeekFrom::End(0)).unwrap();
        std::fs::rename(&path, temp.path().join("retained")).unwrap();
        std::fs::write(&path, b"substituted").unwrap();
        for _ in 0..2 {
            let mut reader = ArtifactReader {
                file: &held,
                offset: 0,
            };
            let mut bytes = Vec::new();
            reader.read_to_end(&mut bytes).unwrap();
            assert_eq!(bytes, b"admitted");
        }
        assert_eq!(held.stream_position().unwrap(), 8);
        assert_eq!(std::fs::read(path).unwrap(), b"substituted");
    }
}
