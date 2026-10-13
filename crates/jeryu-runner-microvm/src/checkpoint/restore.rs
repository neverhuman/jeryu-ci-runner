//! Restore only into the caller-owned fresh successor; retained ciphertext is
//! never mounted and integrity errors propagate before workspace preparation.
use super::*;
use jeryu_runner_protocol::wire::v2::{SessionContext, SessionLease, WorkspaceSource};
use zeroize::Zeroizing;

impl CheckpointStore {
    pub(crate) fn restore(
        &self,
        reference: &CheckpointReference,
        lease: &SessionLease,
        target: &mut File,
    ) -> RunnerResult<()> {
        let (directory, manifest) = self.checked_checkpoint(reference)?;
        resume_fence(
            &manifest,
            &lease.context,
            lease.resources.workspace_gib,
            &lease.workspace,
            now_ms(),
        )?;
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

/// A checkpoint resumes only into its own session's fresh successor: the same
/// owner, repository and session, the next generation, the same runtime and
/// environment, its own workspace size and before it expires. Retained work
/// also needs the same head on the same main. Anything else is refused before
/// a key or an image is read, so one owner's checkpoint never opens into
/// another's session.
pub(super) fn resume_fence(
    manifest: &CheckpointManifest,
    next: &SessionContext,
    workspace_gib: u32,
    workspace: &WorkspaceSource,
    now: u128,
) -> RunnerResult<()> {
    let previous = &manifest.context;
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
        || manifest.plaintext_bytes != u64::from(workspace_gib) * 1024 * 1024 * 1024
        || now >= u128::from(manifest.expires_at_unix_millis)
    {
        return Err(failed("checkpoint_resume_fenced"));
    }
    if let Some(retained) = &manifest.workspace
        && (retained.head_revision != next.source_revision
            || !matches!(workspace, WorkspaceSource::GitBundle { base_revision, .. } if base_revision == &retained.main_revision))
    {
        return Err(failed("checkpoint_resume_main_fenced"));
    }
    Ok(())
}
