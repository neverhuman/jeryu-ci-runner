//! Fenced, bounded destruction. Validate and hold all entries before removing a key.
use super::*;

impl CheckpointStore {
    pub fn destroy(
        &self,
        reference: &CheckpointReference,
        expected: &SessionContext,
    ) -> RunnerResult<()> {
        reference
            .validate()
            .map_err(|_| failed("checkpoint_reference_invalid"))?;
        let root = self.root_directory()?;
        let name = Path::new(&reference.checkpoint_id);
        if !root.entry_exists(name)? {
            return Ok(());
        }
        let directory = root
            .open_directory(name)
            .map_err(|_| failed("checkpoint_custody_denied"))?;
        let receipt = Self::file(&directory, "manifest.json", 32 * 1024)?;
        let (actual, manifest) =
            Self::read_manifest(receipt.try_clone()?, &reference.checkpoint_id)?;
        if actual != *reference {
            return Err(failed("checkpoint_manifest_mismatch"));
        }
        if manifest.context != *expected {
            return Err(failed("checkpoint_cleanup_fenced"));
        }
        for entry in directory.entries_bounded(3)? {
            if ![
                Path::new("key"),
                Path::new("image"),
                Path::new("manifest.json"),
            ]
            .contains(&entry.as_path())
            {
                return Err(failed("checkpoint_custody_denied"));
            }
        }
        let key = Self::optional_file(&directory, "key", 32)?;
        if let Some(key) = &key
            && key.metadata()?.len() != 32
        {
            return Err(failed("checkpoint_key_invalid"));
        }
        let maximum = Self::image_maximum(&manifest)?;
        let mut image = Self::optional_file(&directory, "image", maximum)?;
        if let Some(image) = &mut image {
            Self::verify_ciphertext(image, &manifest, maximum)?;
        }
        root.require_directory_identity(name, &directory)?;
        for (name, file) in [
            ("key", key.as_ref()),
            ("image", image.as_ref()),
            ("manifest.json", Some(&receipt)),
        ] {
            if let Some(file) = file {
                directory.require_file_identity(Path::new(name), file)?;
            }
        }
        if let Some(key) = &key {
            directory.remove_file(Path::new("key"), key)?;
            directory.sync()?;
        }
        if let Some(image) = &image {
            directory.remove_file(Path::new("image"), image)?;
        }
        // Keep the exact manifest's deletion authority until data removal is durable.
        directory.sync()?;
        directory.remove_file(Path::new("manifest.json"), &receipt)?;
        directory.sync()?;
        root.remove_directory(name, &directory)?;
        root.sync()
    }

    fn optional_file(
        directory: &Directory,
        name: &str,
        maximum: u64,
    ) -> RunnerResult<Option<File>> {
        if directory.entry_exists(Path::new(name))? {
            Self::file(directory, name, maximum).map(Some)
        } else {
            Ok(None)
        }
    }

    pub(super) fn verify_ciphertext(
        image: &mut File,
        manifest: &CheckpointManifest,
        maximum: u64,
    ) -> RunnerResult<()> {
        let mut hash = Sha256::new();
        let mut buffer = [0; 64 * 1024];
        let mut total = 0u64;
        let mut reader = image.take(
            maximum
                .checked_add(1)
                .ok_or_else(|| failed("checkpoint_image_invalid"))?,
        );
        loop {
            let length = reader.read(&mut buffer)?;
            if length == 0 {
                break;
            }
            total += length as u64;
            if total > maximum {
                return Err(failed("checkpoint_image_invalid"));
            }
            hash.update(&buffer[..length]);
        }
        if (manifest.format == CheckpointFormat::LegacyDenseV1 && total != maximum)
            || (manifest.format == CheckpointFormat::SparseV2 && total < 56)
            || format!("sha256:{}", hex::encode(hash.finalize())) != manifest.ciphertext_digest
        {
            return Err(failed("checkpoint_image_invalid"));
        }
        Ok(())
    }
}
