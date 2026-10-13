//! Every cleanup acknowledgement authenticates held bytes before deleting plaintext.
use super::*;
use zeroize::Zeroizing;

impl CheckpointStore {
    pub(crate) fn authenticate_reference(
        &self,
        reference: &CheckpointReference,
        id: &str,
        context: &SessionContext,
        bytes: u64,
        filesystem_flushed: bool,
        workspace: Option<&WorkspaceReady>,
    ) -> RunnerResult<()> {
        if reference.checkpoint_id != id {
            return Err(failed("checkpoint_context_mismatch"));
        }
        let (directory, manifest) = self.checked_checkpoint(reference)?;
        Self::require_retained_metadata(&manifest, context, bytes, filesystem_flushed, workspace)?;
        Self::authenticate_files(&directory, &manifest)?;
        directory.sync()?;
        self.root_directory()?.sync()
    }

    pub(super) fn require_retained_metadata(
        manifest: &CheckpointManifest,
        context: &SessionContext,
        bytes: u64,
        filesystem_flushed: bool,
        workspace: Option<&WorkspaceReady>,
    ) -> RunnerResult<()> {
        if manifest.context != *context
            || manifest.plaintext_bytes != bytes
            || manifest.filesystem_flushed != filesystem_flushed
            || manifest.workspace.as_ref() != workspace
        {
            return Err(failed("checkpoint_context_mismatch"));
        }
        Ok(())
    }

    pub(super) fn authenticate_files(
        directory: &Directory,
        manifest: &CheckpointManifest,
    ) -> RunnerResult<()> {
        let mut key = Self::file(directory, "key", 32)?;
        let mut image = Self::file(directory, "image", Self::image_maximum(manifest)?)?;
        Self::authenticate_retry(&mut image, &mut key, manifest)?;
        directory.require_file_identity(Path::new("key"), &key)?;
        directory.require_file_identity(Path::new("image"), &image)
    }

    pub(super) fn manifest_binding(manifest: &CheckpointManifest) -> RunnerResult<Vec<u8>> {
        serde_json::to_vec(&(
            &manifest.checkpoint_id,
            &manifest.context,
            manifest.plaintext_bytes,
            manifest.filesystem_flushed,
            &manifest.workspace,
        ))
        .map_err(|_| failed("checkpoint_context_invalid"))
    }

    pub(super) fn authenticate_retry(
        image: &mut File,
        key_file: &mut File,
        manifest: &CheckpointManifest,
    ) -> RunnerResult<()> {
        if key_file.metadata()?.len() != 32 {
            return Err(failed("checkpoint_key_invalid"));
        }
        let mut key = Zeroizing::new([0; 32]);
        key_file.read_exact(key.as_mut())?;
        if key_file.metadata()?.len() != 32 {
            return Err(failed("checkpoint_key_invalid"));
        }
        let maximum = Self::image_maximum(manifest)?;
        let length = image.metadata()?.len();
        if length > maximum
            || (manifest.format == CheckpointFormat::LegacyDenseV1 && length != maximum)
            || (manifest.format == CheckpointFormat::SparseV2 && length < 56)
        {
            return Err(failed("checkpoint_image_invalid"));
        }
        let binding = Self::manifest_binding(manifest)?;
        let mut bounded = image.take(
            maximum
                .checked_add(1)
                .ok_or_else(|| failed("checkpoint_image_invalid"))?,
        );
        match manifest.format {
            CheckpointFormat::LegacyDenseV1 => crypto::decrypt(
                &mut bounded,
                &mut std::io::sink(),
                &key,
                manifest.plaintext_bytes,
                &binding,
                &manifest.plaintext_digest,
                &manifest.ciphertext_digest,
            ),
            CheckpointFormat::SparseV2 => sparse::verify(
                &mut bounded,
                &key,
                manifest.plaintext_bytes,
                &binding,
                &manifest.plaintext_digest,
                &manifest.ciphertext_digest,
            ),
        }
        .map_err(|_| failed("checkpoint_integrity_failed"))
    }
}
