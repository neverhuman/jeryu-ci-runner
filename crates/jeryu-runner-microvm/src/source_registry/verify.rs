use super::*;
use sha2::{Digest, Sha256};
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
}
