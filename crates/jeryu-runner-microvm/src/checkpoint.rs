//! Retain opaque workspace disks, never post-authentication memory or tmpfs.
//! This transient root is excluded from ordinary backups together with its keys.
mod crypto;
mod destroy;
mod restore;
mod retain;
mod sparse;
mod verify;
/// Ciphertext tags/header plus bounded manifest/key/filesystem bookkeeping.
pub(crate) fn storage_charge(plaintext: u64) -> RunnerResult<u64> {
    plaintext
        .checked_add(
            plaintext
                .div_ceil(1024 * 1024)
                .checked_mul(32)
                .ok_or_else(|| failed("checkpoint_capacity_invalid"))?,
        )
        .and_then(|n| n.checked_add(72 + 1024 * 1024))
        .ok_or_else(|| failed("checkpoint_capacity_invalid"))
}
use crate::custody::{Directory, FileRole};
use jeryu_runner_core::{RunnerError, RunnerResult, receipt::now_ms};
use jeryu_runner_protocol::wire::v2::{
    CheckpointFormat, CheckpointManifest, CheckpointReference, SessionContext, WorkspaceReady,
};
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    io::{Read, Write},
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
};

pub struct CheckpointStore {
    root: PathBuf,
}
pub(crate) struct RetainedDisk<'a> {
    pub image: File,
    pub uid: u32,
    pub bytes: u64,
    pub filesystem_flushed: bool,
    pub workspace: Option<&'a WorkspaceReady>,
}
impl CheckpointStore {
    pub fn open(node_root: &Path) -> RunnerResult<Self> {
        let directory = Directory::open(node_root)
            .and_then(|node| node.child_directory(Path::new("checkpoints")))
            .map_err(|_| failed("checkpoint_custody_denied"))?;
        if directory.mode()? != 0o700 {
            return Err(failed("checkpoint_custody_denied"));
        }
        let root = node_root.join("checkpoints");
        Ok(Self { root })
    }
    pub fn manifest(&self, reference: &CheckpointReference) -> RunnerResult<CheckpointManifest> {
        self.checked_checkpoint(reference)
            .map(|(_, manifest)| manifest)
    }
    /// Manifest, key and ciphertext must refer to one held directory, even if
    /// its original name is moved or substituted while restore is in flight.
    fn checked_checkpoint(
        &self,
        reference: &CheckpointReference,
    ) -> RunnerResult<(Directory, CheckpointManifest)> {
        reference
            .validate()
            .map_err(|_| failed("checkpoint_reference_invalid"))?;
        let directory = self.open_directory(&reference.checkpoint_id)?;
        let (actual, manifest) = Self::read_directory(&directory, &reference.checkpoint_id)?;
        if actual != *reference {
            return Err(failed("checkpoint_manifest_mismatch"));
        }
        Ok((directory, manifest))
    }
    pub(crate) fn reference_for_resource(
        &self,
        id: &str,
        expected: &SessionContext,
        bytes: u64,
        filesystem_flushed: bool,
        workspace: Option<&WorkspaceReady>,
    ) -> RunnerResult<Option<CheckpointReference>> {
        Self::validate_id(id)?;
        let directory = self.root_directory()?;
        if !directory.entry_exists(Path::new(id))? {
            return Ok(None);
        }
        let directory = directory
            .open_directory(Path::new(id))
            .map_err(|_| failed("checkpoint_custody_denied"))?;
        let (reference, manifest) = Self::read_directory(&directory, id)?;
        Self::require_retained_metadata(&manifest, expected, bytes, filesystem_flushed, workspace)?;
        Self::authenticate_files(&directory, &manifest)?;
        directory.sync()?;
        self.root_directory()?.sync()?;
        Ok(Some(reference))
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
        let directory = self.root_directory()?;
        for entry in directory.entries()? {
            let name = entry
                .to_str()
                .ok_or_else(|| failed("checkpoint_custody_denied"))?;
            if name.ends_with(".new") {
                return Err(failed("checkpoint_staging_incomplete"));
            }
            Self::validate_id(name)?;
            let checkpoint = directory
                .open_directory(&entry)
                .map_err(|_| failed("checkpoint_custody_denied"))?;
            manifests.push(Self::read_directory(&checkpoint, name)?);
        }
        Ok(manifests)
    }
    fn open_directory(&self, id: &str) -> RunnerResult<Directory> {
        Self::validate_id(id)?;
        self.root_directory()
            .and_then(|root| root.open_directory(Path::new(id)))
            .map_err(|_| failed("checkpoint_custody_denied"))
    }
    fn root_directory(&self) -> RunnerResult<Directory> {
        let directory =
            Directory::open(&self.root).map_err(|_| failed("checkpoint_custody_denied"))?;
        if directory.mode()? != 0o700 {
            return Err(failed("checkpoint_custody_denied"));
        }
        Ok(directory)
    }
    fn image_maximum(manifest: &CheckpointManifest) -> RunnerResult<u64> {
        match manifest.format {
            CheckpointFormat::LegacyDenseV1 => manifest
                .plaintext_bytes
                .checked_add(
                    manifest
                        .plaintext_bytes
                        .div_ceil(1024 * 1024)
                        .checked_mul(16)
                        .ok_or_else(|| failed("checkpoint_image_invalid"))?,
                )
                .and_then(|size| size.checked_add(24))
                .ok_or_else(|| failed("checkpoint_image_invalid")),
            CheckpointFormat::SparseV2 => Ok(sparse::maximum_size(manifest.plaintext_bytes)?),
        }
    }
    fn read_directory(
        directory: &Directory,
        id: &str,
    ) -> RunnerResult<(CheckpointReference, CheckpointManifest)> {
        let file = Self::file(directory, "manifest.json", 32 * 1024)?;
        Self::read_manifest(file, id)
    }
    fn read_manifest(
        file: File,
        id: &str,
    ) -> RunnerResult<(CheckpointReference, CheckpointManifest)> {
        let mut encoded = vec![];
        file.take(32 * 1024 + 1).read_to_end(&mut encoded)?;
        if encoded.len() > 32 * 1024 {
            return Err(failed("checkpoint_custody_denied"));
        }
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
    fn file(directory: &Directory, name: &str, maximum: u64) -> RunnerResult<File> {
        directory
            .open_file(
                Path::new(name),
                FileRole::Configuration { private: true },
                maximum,
            )
            .map_err(|_| failed("checkpoint_custody_denied"))
    }
    fn validate_id(id: &str) -> RunnerResult<()> {
        CheckpointReference {
            checkpoint_id: id.into(),
            manifest_digest: format!("sha256:{}", "0".repeat(64)),
        }
        .validate()
        .map_err(|_| failed("checkpoint_id_invalid"))?;
        Ok(())
    }
}
fn digest(bytes: &[u8]) -> String {
    format!("sha256:{}", hex::encode(Sha256::digest(bytes)))
}
fn failed(code: &'static str) -> RunnerError {
    RunnerError::new(code, "workspace checkpoint operation failed")
}

pub(crate) fn workspace_custody_denied() -> RunnerError {
    failed("checkpoint_workspace_custody_denied")
}

#[cfg(test)]
mod tests;
