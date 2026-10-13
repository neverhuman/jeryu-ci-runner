//! Hold the fenced workspace and every output until exclusive durable promotion.
use super::*;

impl CheckpointStore {
    /// The journal holds this resource's lock and proves every writer is dead.
    pub(crate) fn retain(
        &self,
        id: &str,
        context: &SessionContext,
        disk: RetainedDisk<'_>,
    ) -> RunnerResult<CheckpointReference> {
        self.retain_with_sync(id, context, disk, Directory::sync)
    }

    pub(super) fn retain_with_sync(
        &self,
        id: &str,
        context: &SessionContext,
        disk: RetainedDisk<'_>,
        sync: impl FnOnce(&Directory) -> RunnerResult<()>,
    ) -> RunnerResult<CheckpointReference> {
        Self::validate_id(id)?;
        context
            .validate()
            .map_err(|_| failed("checkpoint_context_invalid"))?;
        let root = self.root_directory()?;
        if root.entry_exists(Path::new(id))? {
            let directory = root
                .open_directory(Path::new(id))
                .map_err(|_| failed("checkpoint_custody_denied"))?;
            let (reference, manifest) = Self::read_directory(&directory, id)?;
            Self::require_retained_metadata(
                &manifest,
                context,
                disk.bytes,
                disk.filesystem_flushed,
                disk.workspace,
            )?;
            // A retry after promotion but failed parent sync must make that
            // same committed checkpoint durable before returning its reference.
            Self::authenticate_files(&directory, &manifest)?;
            directory.sync()?;
            sync(&root)?;
            return Ok(reference);
        }
        let RetainedDisk {
            mut image,
            uid,
            bytes,
            filesystem_flushed,
            workspace,
        } = disk;
        let metadata = image.metadata()?;
        if !metadata.is_file()
            || metadata.nlink() != 1
            || metadata.uid() != uid
            || metadata.mode() & 0o7777 != 0o600
            || metadata.len() != bytes
        {
            return Err(workspace_custody_denied());
        }
        sparse::maximum_size(bytes)?;
        let name = format!("{id}.new");
        if root.entry_exists(Path::new(&name))? {
            return Err(failed("checkpoint_staging_incomplete"));
        }
        let staging = root
            .create_directory(Path::new(&name))
            .map_err(|_| failed("checkpoint_custody_denied"))?;
        // A failed attempt is retained, never recycled with another key.
        let key = crypto::random_key()?;
        let mut encrypted = staging.create_private(Path::new("image"))?;
        let binding = serde_json::to_vec(&(id, context, bytes, filesystem_flushed, workspace))
            .map_err(|_| failed("checkpoint_context_invalid"))?;
        let (plaintext_digest, ciphertext_digest) =
            sparse::encrypt(&mut image, &mut encrypted, &key, bytes, &binding)?;
        encrypted.sync_all()?;
        let now = u64::try_from(now_ms()).map_err(|_| failed("checkpoint_clock_invalid"))?;
        let manifest = CheckpointManifest {
            format: CheckpointFormat::SparseV2,
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
        let mut key_file = staging.create_private(Path::new("key"))?;
        key_file.write_all(key.as_ref())?;
        key_file.sync_all()?;
        let mut receipt = staging.create_private(Path::new("manifest.json"))?;
        receipt.write_all(&encoded)?;
        receipt.sync_all()?;
        for (name, file) in [
            ("image", &encrypted),
            ("key", &key_file),
            ("manifest.json", &receipt),
        ] {
            staging.require_file_identity(Path::new(name), file)?;
        }
        staging.sync()?;
        if !root.promote_directory(Path::new(&name), &staging, Path::new(id))? {
            return Err(failed("checkpoint_promotion_collision"));
        }
        root.require_directory_identity(Path::new(id), &staging)?;
        sync(&root)?;
        Ok(CheckpointReference {
            checkpoint_id: id.into(),
            manifest_digest: digest(&encoded),
        })
    }
}
