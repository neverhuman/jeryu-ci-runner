//! Restore only into the caller-owned fresh successor; retained ciphertext is
//! never mounted and integrity errors propagate before workspace preparation.
use super::*;
use jeryu_runner_protocol::wire::v2::{SessionLease, WorkspaceSource};
use zeroize::Zeroizing;

impl CheckpointStore {
    pub(crate) fn restore(
        &self,
        reference: &CheckpointReference,
        lease: &SessionLease,
        target: &mut File,
    ) -> RunnerResult<()> {
        let (directory, manifest) = self.checked_checkpoint(reference)?;
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
        if let Some(workspace) = &manifest.workspace
            && (workspace.head_revision != next.source_revision
                || !matches!(&lease.workspace, WorkspaceSource::GitBundle { base_revision, .. } if base_revision == &workspace.main_revision))
        {
            return Err(failed("checkpoint_resume_main_fenced"));
        }
        let mut key = Zeroizing::new([0; 32]);
        let mut key_file = Self::file(&directory, "key", 32)?;
        key_file.read_exact(key.as_mut())?;
        if key_file.metadata()?.len() != 32 {
            return Err(failed("checkpoint_key_invalid"));
        }
        let maximum = Self::image_maximum(&manifest)?;
        let mut image = Self::file(&directory, "image", maximum)?;
        let length = image.metadata()?.len();
        if (manifest.format == CheckpointFormat::LegacyDenseV1 && length != maximum)
            || (manifest.format == CheckpointFormat::SparseV2 && length < 56)
        {
            return Err(failed("checkpoint_image_invalid"));
        }
        let binding = Self::manifest_binding(&manifest)?;
        match manifest.format {
            CheckpointFormat::LegacyDenseV1 => crypto::decrypt(
                &mut image,
                target,
                &key,
                manifest.plaintext_bytes,
                &binding,
                &manifest.plaintext_digest,
                &manifest.ciphertext_digest,
            ),
            CheckpointFormat::SparseV2 => sparse::decrypt(
                &mut image,
                target,
                &key,
                manifest.plaintext_bytes,
                &binding,
                &manifest.plaintext_digest,
                &manifest.ciphertext_digest,
            ),
        }?;
        target.sync_all()?;
        Ok(())
    }
}
