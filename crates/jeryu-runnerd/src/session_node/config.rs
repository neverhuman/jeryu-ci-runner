use jeryu_runner_core::{RunnerError, RunnerResult};
use jeryu_runner_microvm::{NodeConfig, artifacts::VerifiedRuntime};
use jeryu_runner_protocol::wire::v2::{RuntimeImageClass, RuntimeManifest};
use rustls::{RootCertStore, ServerConfig, server::WebPkiClientVerifier};
use rustls_pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
use serde::Deserialize;
use std::{
    fs::File,
    io::Read,
    net::SocketAddr,
    path::{Path, PathBuf},
    sync::Arc,
};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionNodeConfig {
    pub runner_id: String,
    pub runner_epoch: u64,
    pub state_dir: PathBuf,
    pub capacity: usize,
    pub cpu_budget_vcpus: u16,
    pub memory_budget_mib: u32,
    pub disk_budget_gib: u32,
    #[serde(default = "legacy_uid_base")]
    pub uid_base: u32,
    pub owner_limit: usize,
    pub listen: SocketAddr,
    pub artifact_store: PathBuf,
    /// Separate operator allocation, with physical VM/upload admission shared.
    pub source_bundle_budget_gib: u32,
    pub runtime_manifest: PathBuf,
    pub runtime_signature: PathBuf,
    pub release_public_key: PathBuf,
    /// Omitted in production. An explicitly enrolled distinct fixture authority.
    #[serde(default)]
    pub test_runtime_public_key: Option<PathBuf>,
    pub control_plane_lease_public_key: PathBuf,
    pub server_certificate: PathBuf,
    pub server_private_key: PathBuf,
    pub control_plane_ca: PathBuf,
    /// Exact approved control-plane leaf certificate; CA membership alone is
    /// insufficient to let another runner assert user identities or assign work.
    pub control_plane_certificate_sha256: String,
}
impl SessionNodeConfig {
    pub fn read(path: &Path) -> RunnerResult<Self> {
        let bytes =
            jeryu_runner_microvm::custody::read_bounded(trusted_file(path, true)?, 64 * 1024)
                .map_err(|_| failed("session_config_custody_denied"))?;
        serde_json::from_slice(&bytes).map_err(|_| failed("session_node_config_invalid"))
    }
    pub(super) fn runtime(&self) -> RunnerResult<VerifiedRuntime> {
        let manifest = RuntimeManifest::from_json(&trusted_bytes(&self.runtime_manifest)?)
            .map_err(|_| failed("session_runtime_manifest_invalid"))?;
        let signature = trusted_bytes(&self.runtime_signature)?
            .try_into()
            .map_err(|_| failed("session_runtime_signature_invalid"))?;
        let key = trusted_bytes(&self.release_public_key)?
            .try_into()
            .map_err(|_| failed("session_release_key_invalid"))?;
        // Public keys cannot be selected by RPC. Config and key custody are
        // verified separately; signature does not itself qualify a runtime.
        match manifest.image_class {
            RuntimeImageClass::Production if self.test_runtime_public_key.is_none() => {
                VerifiedRuntime::admit(manifest, &signature, &key, &self.artifact_store)
            }
            RuntimeImageClass::Production => Err(failed("session_test_authority_in_production")),
            RuntimeImageClass::Test => {
                let path = self
                    .test_runtime_public_key
                    .as_ref()
                    .ok_or_else(|| failed("session_test_authority_missing"))?;
                let test_key = trusted_bytes(path)?
                    .try_into()
                    .map_err(|_| failed("session_test_authority_invalid"))?;
                VerifiedRuntime::admit_test(
                    manifest,
                    &signature,
                    &key,
                    &test_key,
                    &self.artifact_store,
                )
            }
        }
    }
    pub(super) fn node(&self) -> RunnerResult<NodeConfig> {
        Ok(NodeConfig {
            runner_id: self.runner_id.clone(),
            runner_epoch: self.runner_epoch,
            control_plane_lease_key: trusted_bytes(&self.control_plane_lease_public_key)?
                .try_into()
                .map_err(|_| failed("session_lease_authority_invalid"))?,
            state_dir: self.state_dir.clone(),
            capacity: self.capacity,
            cpu_budget_vcpus: self.cpu_budget_vcpus,
            memory_budget_mib: self.memory_budget_mib,
            disk_budget_gib: self.disk_budget_gib,
            uid_base: self.uid_base,
        })
    }
    pub(super) fn tls(&self) -> RunnerResult<Arc<ServerConfig>> {
        if self.control_plane_certificate_sha256.len() != 64
            || !self
                .control_plane_certificate_sha256
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(failed("session_peer_pin_invalid"));
        }
        let mut roots = RootCertStore::empty();
        for certificate in certificates(trusted_file(&self.control_plane_ca, false)?)? {
            roots
                .add(certificate)
                .map_err(|_| failed("session_tls_invalid"))?;
        }
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let verifier =
            WebPkiClientVerifier::builder_with_provider(Arc::new(roots), provider.clone())
                .build()
                .map_err(|_| failed("session_tls_invalid"))?;
        let certificates = certificates(trusted_file(&self.server_certificate, false)?)?;
        let key = private_key(trusted_file(&self.server_private_key, true)?)?;
        let mut tls = ServerConfig::builder_with_provider(provider)
            .with_protocol_versions(&[&rustls::version::TLS13])
            .map_err(|_| failed("session_tls_invalid"))?
            .with_client_cert_verifier(verifier)
            .with_single_cert(certificates, key)
            .map_err(|_| failed("session_tls_invalid"))?;
        tls.alpn_protocols = vec![b"http/1.1".to_vec()];
        Ok(Arc::new(tls))
    }
}
fn certificates(reader: impl Read) -> RunnerResult<Vec<CertificateDer<'static>>> {
    CertificateDer::pem_reader_iter(reader)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| failed("session_tls_invalid"))
}
fn private_key(reader: impl Read) -> RunnerResult<PrivateKeyDer<'static>> {
    PrivateKeyDer::from_pem_reader(reader).map_err(|_| failed("session_tls_invalid"))
}
fn trusted_bytes(path: &Path) -> RunnerResult<Vec<u8>> {
    let file = trusted_file(path, false)?;
    let mut bytes = Vec::new();
    file.take(64 * 1024 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > 64 * 1024 {
        return Err(failed("session_config_custody_denied"));
    }
    Ok(bytes)
}
fn trusted_file(path: &Path, private: bool) -> RunnerResult<File> {
    jeryu_runner_microvm::custody::open_file(
        path,
        jeryu_runner_microvm::custody::FileRole::Configuration { private },
        64 * 1024,
    )
    .map_err(|_| failed("session_config_custody_denied"))
}
fn legacy_uid_base() -> u32 {
    jeryu_runner_microvm::journal::LEGACY_UID_BASE
}
fn failed(code: &'static str) -> RunnerError {
    RunnerError::new(code, "session node configuration rejected")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io;

    const CERT: &[u8] = b"-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----\n";

    #[test]
    fn legacy_config_defaults_uid_base_and_new_config_keeps_its_explicit_range() {
        let mut value = serde_json::json!({
            "runner_id":"node", "runner_epoch":1, "state_dir":"/var/lib/node", "capacity":1,
            "cpu_budget_vcpus":2, "memory_budget_mib":8192, "disk_budget_gib":32, "owner_limit":1,
            "listen":"127.0.0.1:9876", "artifact_store":"/var/lib/artifacts", "source_bundle_budget_gib":2,
            "runtime_manifest":"/var/lib/manifest", "runtime_signature":"/var/lib/signature", "release_public_key":"/var/lib/release-key",
            "control_plane_lease_public_key":"/var/lib/lease-key", "server_certificate":"/var/lib/cert", "server_private_key":"/var/lib/key",
            "control_plane_ca":"/var/lib/ca", "control_plane_certificate_sha256":"a".repeat(64)
        });
        let legacy: SessionNodeConfig = serde_json::from_value(value.clone()).unwrap();
        assert_eq!(legacy.uid_base, 200000);
        value["uid_base"] = serde_json::json!(231104);
        let enrolled: SessionNodeConfig = serde_json::from_value(value).unwrap();
        assert_eq!(enrolled.uid_base, 231104);
    }

    // Synthetic payloads test PEM framing; TLS setup separately validates DER.
    fn pem_section(label: &str, body: &str) -> Vec<u8> {
        format!("-----BEGIN {label}-----\n{body}\n-----END {label}-----\n").into_bytes()
    }

    struct Fragmented<'a>(&'a [u8]);
    impl Read for Fragmented<'_> {
        fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
            if bytes.is_empty() || self.0.is_empty() {
                return Ok(0);
            }
            bytes[0] = self.0[0];
            self.0 = &self.0[1..];
            Ok(1)
        }
    }

    #[test]
    fn fragmented_certificate_chain_preserves_order_and_filters_keys() {
        let mut pem = CERT.to_vec();
        pem.extend_from_slice(&pem_section("PRIVATE KEY", "Bw=="));
        pem.extend_from_slice(b"-----BEGIN CERTIFICATE-----\nBAUG\n-----END CERTIFICATE-----\n");
        let chain = certificates(Fragmented(&pem)).unwrap();
        assert_eq!(chain.len(), 2);
        assert_eq!(chain[0].as_ref(), [1, 2, 3]);
        assert_eq!(chain[1].as_ref(), [4, 5, 6]);
    }

    #[test]
    fn all_key_encodings_select_first_key_and_preserve_der() {
        for (index, label) in ["RSA PRIVATE KEY", "EC PRIVATE KEY", "PRIVATE KEY"]
            .iter()
            .enumerate()
        {
            let mut pem = CERT.to_vec();
            pem.extend_from_slice(&pem_section(label, "AQID"));
            pem.extend_from_slice(&pem_section("PRIVATE KEY", "BAUG"));
            let key = private_key(Fragmented(&pem)).unwrap();
            assert_eq!(key.secret_der(), [1, 2, 3]);
            assert!(matches!(
                (index, key),
                (0, PrivateKeyDer::Pkcs1(_))
                    | (1, PrivateKeyDer::Sec1(_))
                    | (2, PrivateKeyDer::Pkcs8(_))
            ));
        }
    }

    fn assert_rejected<T: std::fmt::Debug>(result: RunnerResult<T>) {
        let error = result.unwrap_err();
        assert_eq!(error.code(), "session_tls_invalid");
        assert_eq!(error.message(), "session node configuration rejected");
    }

    #[test]
    fn malformed_or_truncated_pem_and_missing_keys_fail_closed() {
        for label in ["CERTIFICATE", "PRIVATE KEY"] {
            for body in ["not@base64\n", "AQID\n"] {
                let pem = format!("-----BEGIN {label}-----\n{body}");
                assert_rejected(certificates(pem.as_bytes()));
                assert_rejected(private_key(pem.as_bytes()));
            }
            let pem = format!("-----BEGIN {label}-----\nnot@base64\n-----END {label}-----\n");
            assert_rejected(certificates(pem.as_bytes()));
            assert_rejected(private_key(pem.as_bytes()));
        }
        assert_rejected(private_key(CERT));
        assert_rejected(private_key(&b"no PEM items"[..]));
    }

    struct FailedRead;
    impl Read for FailedRead {
        fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
            Err(io::Error::other(
                "sensitive input must not appear in diagnostics",
            ))
        }
    }

    #[test]
    fn certificate_and_key_io_errors_are_redacted() {
        assert_rejected(certificates(FailedRead));
        assert_rejected(private_key(FailedRead));
    }
}
