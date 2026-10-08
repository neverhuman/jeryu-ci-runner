use jeryu_runner_core::{RunnerError, RunnerResult};
use jeryu_runner_microvm::{NodeConfig, artifacts::VerifiedRuntime};
use jeryu_runner_protocol::wire::v2::RuntimeManifest;
use rustls::{RootCertStore, ServerConfig, server::WebPkiClientVerifier};
use serde::Deserialize;
use std::{
    fs::{File, OpenOptions},
    io::{BufReader, Read},
    net::SocketAddr,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
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
    pub memory_budget_mib: u32,
    pub disk_budget_gib: u32,
    pub owner_limit: usize,
    pub listen: SocketAddr,
    pub artifact_store: PathBuf,
    pub runtime_manifest: PathBuf,
    pub runtime_signature: PathBuf,
    pub release_public_key: PathBuf,
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
        serde_json::from_reader(trusted_file(path, true)?)
            .map_err(|_| failed("session_node_config_invalid"))
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
        VerifiedRuntime::admit(manifest, &signature, &key, &self.artifact_store)
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
            memory_budget_mib: self.memory_budget_mib,
            disk_budget_gib: self.disk_budget_gib,
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
        for certificate in rustls_pemfile::certs(&mut BufReader::new(trusted_file(
            &self.control_plane_ca,
            false,
        )?)) {
            roots
                .add(certificate.map_err(|_| failed("session_tls_invalid"))?)
                .map_err(|_| failed("session_tls_invalid"))?;
        }
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let verifier =
            WebPkiClientVerifier::builder_with_provider(Arc::new(roots), provider.clone())
                .build()
                .map_err(|_| failed("session_tls_invalid"))?;
        let certificates = rustls_pemfile::certs(&mut BufReader::new(trusted_file(
            &self.server_certificate,
            false,
        )?))
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|_| failed("session_tls_invalid"))?;
        let key = rustls_pemfile::private_key(&mut BufReader::new(trusted_file(
            &self.server_private_key,
            true,
        )?))
        .map_err(|_| failed("session_tls_invalid"))?
        .ok_or_else(|| failed("session_tls_invalid"))?;
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
    jeryu_runner_microvm::artifacts::verify_trusted_directory(
        path.parent()
            .ok_or_else(|| failed("session_config_custody_denied"))?,
    )?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(nix::libc::O_NOFOLLOW)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.uid() != 0
        || metadata.nlink() != 1
        || metadata.len() > 64 * 1024
        || metadata.mode() & 0o022 != 0
        || (private && metadata.mode() & 0o077 != 0)
    {
        return Err(failed("session_config_custody_denied"));
    }
    Ok(file)
}
fn failed(code: &'static str) -> RunnerError {
    RunnerError::new(code, "session node configuration rejected")
}
