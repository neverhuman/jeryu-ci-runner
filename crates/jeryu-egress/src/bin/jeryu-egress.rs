#![doc = "Thin entrypoint for the host-allowlist egress proxy."]
#![doc = ""]
#![doc = "All policy lives in the `jeryu_egress` library; this binary only resolves"]
#![doc = "the model-egress config (bind address + allow-list) and runs the proxy."]
#![doc = "Point `JERYU_MODEL_EGRESS_CONFIG` at a TOML file to bind the proxy on the"]
#![doc = "agent bridge and name the model API hosts it may forward to; with no file"]
#![doc = "it listens on loopback and allows only the Anthropic API host."]

use jeryu_egress::{Budget, ModelEgressConfig, Proxy};
use std::net::SocketAddr;

#[tokio::main]
async fn main() -> std::io::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let config = ModelEgressConfig::load()
        .map_err(|err| std::io::Error::new(std::io::ErrorKind::InvalidInput, err.to_string()))?;
    // An explicit override still wins, so an operator can move the listener
    // without editing the policy file.
    let bind = std::env::var("JERYU_EGRESS_BIND").unwrap_or_else(|_| config.bind.clone());
    let bind: SocketAddr = bind.parse().map_err(|e| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("bad bind addr {bind:?}: {e}"),
        )
    })?;

    let allowlist = config.allowlist();
    tracing::info!(
        hosts = ?allowlist.hosts(),
        suffixes = ?allowlist.suffixes(),
        network = %config.network,
        "model egress allow-list"
    );
    let proxy = Proxy::new(allowlist, Budget::new());
    proxy.serve(bind).await
}
