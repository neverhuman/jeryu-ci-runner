//! Retain opaque workspace disks, never post-authentication memory or tmpfs.
//! This transient root is excluded from ordinary backups together with its keys.
mod crypto;
/// Ciphertext tags/header plus bounded manifest/key/filesystem bookkeeping.
pub(crate) fn storage_charge(plaintext: u64) -> RunnerResult<u64> {
    plaintext
        .checked_add(plaintext.div_ceil(1024 * 1024) * 16)
        .and_then(|n| n.checked_add(24 + 1024 * 1024))
        .ok_or_else(|| failed("checkpoint_capacity_invalid"))
}
use crate::artifacts::trusted_directory;
use jeryu_runner_core::{RunnerError, RunnerResult, receipt::now_ms};
use jeryu_runner_protocol::wire::v2::{
    CheckpointManifest, CheckpointReference, SessionContext, SessionLease, WorkspaceReady,
    WorkspaceSource,
};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};
use zeroize::Zeroizing;

pub struct CheckpointStore {
    root: PathBuf,
}
pub(crate) struct RetainedDisk<'a> {
    pub path: &'a Path,
    pub uid: u32,
    pub bytes: u64,
    pub filesystem_flushed: bool,
    pub workspace: Option<&'a WorkspaceReady>,
}
impl CheckpointStore {
    pub fn open(node_root: &Path) -> RunnerResult<Self> {
        trusted_directory(node_root)?;
        let root = node_root.join("checkpoints");
        fs::create_dir_all(&root)?;
        trusted_directory(&root)?;
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700))?;
        Ok(Self { root })
    }
    /// The journal holds this resource's lock and proves the VMM is dead before
    /// this method reads its private disk. It does not inspect guest file paths.
    pub(crate) fn retain(
        &self,
        id: &str,
        context: &SessionContext,
        disk: RetainedDisk<'_>,
    ) -> RunnerResult<CheckpointReference> {
        let RetainedDisk {
            path: source,
            uid: expected_uid,
            bytes,
            filesystem_flushed,
            workspace,
        } = disk;
        let directory = self.directory(id)?;
        if directory.exists() {
            let (reference, manifest) = self.read_id(id)?;
            if manifest.context != *context || manifest.plaintext_bytes != bytes {
                return Err(failed("checkpoint_context_mismatch"));
            }
            return Ok(reference);
        }
        let mut image = OpenOptions::new()
            .read(true)
            .custom_flags(nix::libc::O_NOFOLLOW)
            .open(source)?;
        let metadata = image.metadata()?;
        if !metadata.is_file()
            || metadata.nlink() != 1
            || metadata.uid() != expected_uid
            || metadata.len() != bytes
        {
            return Err(failed("checkpoint_workspace_custody_denied"));
        }
        let staging = self.root.join(format!("{id}.new"));
        if staging.exists() {
            trusted_directory(&staging)?;
            fs::remove_dir_all(&staging)?;
        }
        fs::create_dir(&staging)?;
        fs::set_permissions(&staging, fs::Permissions::from_mode(0o700))?;
        // Each retry gets a fresh key; partially written images are never reused.
        let key = crypto::random_key()?;
        let mut encrypted = create(&staging.join("image"))?;
        context
            .validate()
            .map_err(|_| failed("checkpoint_context_invalid"))?;
        let binding = serde_json::to_vec(&(id, context, bytes, filesystem_flushed, workspace))
            .map_err(|_| failed("checkpoint_context_invalid"))?;
        let (plaintext_digest, ciphertext_digest) =
            crypto::encrypt(&mut image, &mut encrypted, &key, bytes, &binding)?;
        encrypted.sync_all()?;
        let now = u64::try_from(now_ms()).map_err(|_| failed("checkpoint_clock_invalid"))?;
        let manifest = CheckpointManifest {
            checkpoint_id: id.into(),
            context: context.clone(),
            workspace: workspace.cloned(),
            plaintext_bytes: bytes,
            plaintext_digest,
            ciphertext_digest,
            filesystem_flushed,
            created_at_unix_millis: now,
            expires_at_unix_millis: now
                .checked_add(7 * 24 * 60 * 60 * 1000)
                .ok_or_else(|| failed("checkpoint_clock_invalid"))?,
        };
        let encoded = manifest
            .to_json()
            .map_err(|_| failed("checkpoint_manifest_invalid"))?;
        let mut key_file = create(&staging.join("key"))?;
        key_file.write_all(key.as_ref())?;
        key_file.sync_all()?;
        let mut receipt = create(&staging.join("manifest.json"))?;
        receipt.write_all(&encoded)?;
        receipt.sync_all()?;
        File::open(&staging)?.sync_all()?;
        fs::rename(staging, directory)?;
        File::open(&self.root)?.sync_all()?;
        Ok(CheckpointReference {
            checkpoint_id: id.into(),
            manifest_digest: digest(&encoded),
        })
    }
    pub fn manifest(&self, reference: &CheckpointReference) -> RunnerResult<CheckpointManifest> {
        reference
            .validate()
            .map_err(|_| failed("checkpoint_reference_invalid"))?;
        let (actual, manifest) = self.read_id(&reference.checkpoint_id)?;
        if actual != *reference {
            return Err(failed("checkpoint_manifest_mismatch"));
        }
        Ok(manifest)
    }
    pub(crate) fn reference_for_resource(
        &self,
        id: &str,
        expected: &SessionContext,
    ) -> RunnerResult<Option<CheckpointReference>> {
        if !self.directory(id)?.exists() {
            return Ok(None);
        }
        let (reference, manifest) = self.read_id(id)?;
        if manifest.context != *expected {
            return Err(failed("checkpoint_context_mismatch"));
        }
        Ok(Some(reference))
    }
    pub(crate) fn restore(
        &self,
        reference: &CheckpointReference,
        lease: &SessionLease,
        target: &mut File,
    ) -> RunnerResult<()> {
        let manifest = self.manifest(reference)?;
        let previous = &manifest.context;
        let next = &lease.context;
        if previous.owner_id != next.owner_id
            || previous.repository != next.repository
            || previous.session_id != next.session_id
            || next.generation
                != previous
                    .generation
                    .checked_add(1)
                    .ok_or_else(|| failed("checkpoint_generation_invalid"))?
            || previous.runtime_digest != next.runtime_digest
            || previous.environment_digest != next.environment_digest
            || manifest.plaintext_bytes
                != u64::from(lease.resources.workspace_gib) * 1024 * 1024 * 1024
            || now_ms() >= u128::from(manifest.expires_at_unix_millis)
        {
            return Err(failed("checkpoint_resume_fenced"));
        }
        let directory = self.directory(&reference.checkpoint_id)?;
        if let Some(workspace) = &manifest.workspace
            && (workspace.head_revision != next.source_revision
                || !matches!(&lease.workspace, WorkspaceSource::GitBundle { base_revision, .. } if base_revision == &workspace.main_revision))
        {
            return Err(failed("checkpoint_resume_main_fenced"));
        }
        let mut key = Zeroizing::new([0; 32]);
        let mut key_file = self.file(&directory.join("key"), 32)?;
        key_file.read_exact(key.as_mut())?;
        if key_file.metadata()?.len() != 32 {
            return Err(failed("checkpoint_key_invalid"));
        }
        let maximum =
            manifest.plaintext_bytes + manifest.plaintext_bytes.div_ceil(1024 * 1024) * 16 + 24;
        let mut image = self.file(&directory.join("image"), maximum)?;
        if image.metadata()?.len() != maximum {
            return Err(failed("checkpoint_image_invalid"));
        }
        let binding = serde_json::to_vec(&(
            &manifest.checkpoint_id,
            previous,
            manifest.plaintext_bytes,
            manifest.filesystem_flushed,
            &manifest.workspace,
        ))
        .map_err(|_| failed("checkpoint_context_invalid"))?;
        crypto::decrypt(
            &mut image,
            target,
            &key,
            manifest.plaintext_bytes,
            &binding,
            &manifest.plaintext_digest,
            &manifest.ciphertext_digest,
        )?;
        target.sync_all()?;
        Ok(())
    }
    /// Trusted cleanup uses an exact recorded reference and context. User or
    /// guest-provided paths never authorize deletion. Destroy the key first.
    pub fn destroy(
        &self,
        reference: &CheckpointReference,
        expected: &SessionContext,
    ) -> RunnerResult<()> {
        let directory = self.directory(&reference.checkpoint_id)?;
        if !directory.exists() {
            return Ok(());
        }
        if self.manifest(reference)?.context != *expected {
            return Err(failed("checkpoint_cleanup_fenced"));
        }
        match fs::remove_file(directory.join("key")) {
            Ok(()) => File::open(&directory)?.sync_all()?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
            Err(error) => return Err(error.into()),
        }
        fs::remove_dir_all(directory)?;
        File::open(&self.root)?.sync_all()?;
        Ok(())
    }
    pub(crate) fn retained_bytes(&self) -> RunnerResult<u64> {
        self.manifests()?
            .into_iter()
            .try_fold(0u64, |sum, (_, manifest)| {
                sum.checked_add(storage_charge(manifest.plaintext_bytes)?)
                    .ok_or_else(|| failed("checkpoint_capacity_invalid"))
            })
    }
    pub(crate) fn reconcile(&self) -> RunnerResult<()> {
        for (reference, manifest) in self.manifests()? {
            if now_ms() >= u128::from(manifest.expires_at_unix_millis) {
                self.destroy(&reference, &manifest.context)?;
            }
        }
        Ok(())
    }
    fn manifests(&self) -> RunnerResult<Vec<(CheckpointReference, CheckpointManifest)>> {
        let mut manifests = vec![];
        for entry in fs::read_dir(&self.root)? {
            let name = entry?.file_name().to_string_lossy().into_owned();
            if name.ends_with(".new") {
                continue;
            }
            manifests.push(self.read_id(&name)?);
        }
        Ok(manifests)
    }
    fn read_id(&self, id: &str) -> RunnerResult<(CheckpointReference, CheckpointManifest)> {
        let directory = self.directory(id)?;
        trusted_directory(&directory)?;
        let file = self.file(&directory.join("manifest.json"), 32 * 1024)?;
        let mut encoded = vec![];
        file.take(32 * 1024 + 1).read_to_end(&mut encoded)?;
        let manifest = CheckpointManifest::from_json(&encoded)
            .map_err(|_| failed("checkpoint_manifest_invalid"))?;
        if manifest.checkpoint_id != id {
            return Err(failed("checkpoint_manifest_mismatch"));
        }
        Ok((
            CheckpointReference {
                checkpoint_id: id.into(),
                manifest_digest: digest(&encoded),
            },
            manifest,
        ))
    }
    fn file(&self, path: &Path, maximum: u64) -> RunnerResult<File> {
        trusted_directory(
            path.parent()
                .ok_or_else(|| failed("checkpoint_custody_denied"))?,
        )?;
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(nix::libc::O_NOFOLLOW)
            .open(path)?;
        let meta = file.metadata()?;
        if !meta.is_file()
            || meta.uid() != 0
            || meta.mode() & 0o077 != 0
            || meta.nlink() != 1
            || meta.len() > maximum
        {
            return Err(failed("checkpoint_custody_denied"));
        }
        Ok(file)
    }
    fn directory(&self, id: &str) -> RunnerResult<PathBuf> {
        CheckpointReference {
            checkpoint_id: id.into(),
            manifest_digest: format!("sha256:{}", "0".repeat(64)),
        }
        .validate()
        .map_err(|_| failed("checkpoint_id_invalid"))?;
        Ok(self.root.join(id))
    }
}
fn create(path: &Path) -> std::io::Result<File> {
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
}
fn digest(bytes: &[u8]) -> String {
    format!("sha256:{}", hex::encode(Sha256::digest(bytes)))
}
fn failed(code: &'static str) -> RunnerError {
    RunnerError::new(code, "workspace checkpoint operation failed")
}
