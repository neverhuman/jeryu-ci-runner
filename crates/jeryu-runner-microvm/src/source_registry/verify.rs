use super::*;
use sha2::{Digest, Sha256};
use std::io::{Read, Seek};

pub(super) fn file(file: &mut File, upload: &BundleUpload) -> RunnerResult<()> {
    file.rewind()?;
    let mut verifier = Verifier::new(upload);
    let mut buffer = [0u8; 64 * 1024];
    let limit = upload
        .stored_bytes
        .checked_add(1)
        .ok_or_else(|| failed("bundle_length_invalid"))?;
    let mut reader = (&mut *file).take(limit);
    loop {
        let length = reader.read(&mut buffer)?;
        if length == 0 {
            break;
        }
        verifier.push(&buffer[..length])?;
    }
    verifier.finish()?;
    file.rewind()?;
    Ok(())
}

pub(super) struct Verifier {
    raw: u64,
    stored: u64,
    written: u64,
    expected: String,
    hash: Sha256,
}
impl Verifier {
    pub fn new(upload: &BundleUpload) -> Self {
        Self {
            raw: upload.bundle_bytes,
            stored: upload.stored_bytes,
            written: 0,
            expected: upload.digest.clone(),
            hash: Sha256::new(),
        }
    }
    pub fn push(&mut self, bytes: &[u8]) -> RunnerResult<()> {
        let length = u64::try_from(bytes.len()).map_err(|_| failed("bundle_length_invalid"))?;
        if length > self.stored.saturating_sub(self.written) {
            return Err(failed("bundle_length_invalid"));
        }
        let raw_left = self.raw.saturating_sub(self.written).min(length) as usize;
        if bytes[raw_left..].iter().any(|byte| *byte != 0) {
            return Err(failed("bundle_padding_invalid"));
        }
        self.hash.update(bytes);
        self.written += length;
        Ok(())
    }
    pub fn finish(&self) -> RunnerResult<()> {
        if self.written != self.stored {
            return Err(failed("bundle_length_invalid"));
        }
        if format!("sha256:{}", hex::encode(self.hash.clone().finalize())) != self.expected {
            return Err(failed("bundle_digest_mismatch"));
        }
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn upload(bytes: &[u8], raw: u64) -> BundleUpload {
        BundleUpload {
            protocol_version: PROTOCOL_VERSION.into(),
            message_type: "bundle-upload".into(),
            request_id: "test".into(),
            role: jeryu_runner_protocol::wire::v2::BundleRole::SourceBundle,
            digest: format!("sha256:{}", hex::encode(Sha256::digest(bytes))),
            bundle_bytes: raw,
            stored_bytes: bytes.len() as u64,
        }
    }
    #[test]
    fn padding_is_checked_across_chunk_boundary_and_all_bytes_are_hashed() {
        let mut bytes = vec![42; 503];
        bytes.resize(512, 0);
        let input = upload(&bytes, 503);
        let mut verifier = Verifier::new(&input);
        for part in bytes.chunks(7) {
            verifier.push(part).unwrap();
        }
        verifier.finish().unwrap();
        bytes[502] ^= 1;
        let mut wrong = Verifier::new(&input);
        wrong.push(&bytes).unwrap();
        assert_eq!(wrong.finish().unwrap_err().code(), "bundle_digest_mismatch");
        bytes[503] = 1;
        assert_eq!(
            Verifier::new(&input).push(&bytes).unwrap_err().code(),
            "bundle_padding_invalid"
        );
    }
    #[test]
    fn truncated_extra_and_padding_only_chunks_are_rejected() {
        let bytes = vec![0; 512];
        let input = upload(&bytes, 500);
        let mut verifier = Verifier::new(&input);
        verifier.push(&bytes[..500]).unwrap();
        assert_eq!(
            verifier.finish().unwrap_err().code(),
            "bundle_length_invalid"
        );
        assert_eq!(
            verifier.push(&[1]).unwrap_err().code(),
            "bundle_padding_invalid"
        );
        verifier.push(&bytes[500..]).unwrap();
        verifier.finish().unwrap();
        assert_eq!(
            verifier.push(&[0]).unwrap_err().code(),
            "bundle_length_invalid"
        );
    }

    #[test]
    fn disk_verification_uses_the_held_file_and_refuses_modified_truncated_or_extra_bytes() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("staged");
        let bytes = vec![42; 512];
        let input = upload(&bytes, 512);
        std::fs::write(&path, &bytes).unwrap();
        let mut held = File::open(&path).unwrap();
        std::fs::rename(&path, temp.path().join("retained")).unwrap();
        std::fs::write(&path, vec![99; 512]).unwrap();
        file(&mut held, &input).unwrap();
        assert_eq!(held.stream_position().unwrap(), 0);
        assert_eq!(std::fs::read(&path).unwrap(), vec![99; 512]);
        for (contents, expected) in [
            (vec![99; 512], "bundle_digest_mismatch"),
            (vec![42; 511], "bundle_length_invalid"),
            (vec![42; 513], "bundle_length_invalid"),
        ] {
            std::fs::write(temp.path().join("retained"), contents).unwrap();
            assert_eq!(file(&mut held, &input).unwrap_err().code(), expected);
        }
    }
}
