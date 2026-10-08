//! Dedicated root node service. Its trusted config, not RPC callers, chooses
//! TLS identities, release authority, artifact store and bounded node capacity.
use jeryu_runnerd::session_node::{SessionNodeConfig, serve};
use std::path::Path;

#[tokio::main]
async fn main() {
    if jeryu_sandbox_linux::microvm::disable_core_dumps().is_err() {
        eprintln!("jeryu_session_node_failed code=core_dump_limit_failed");
        std::process::exit(1);
    }
    let arguments: Vec<_> = std::env::args().collect();
    if arguments.len() != 3 || arguments[1] != "--config" {
        eprintln!("usage: jeryu-session-node --config ROOT_OWNED_CONFIG");
        std::process::exit(2);
    }
    let config = match SessionNodeConfig::read(Path::new(&arguments[2])) {
        Ok(config) => config,
        Err(error) => {
            eprintln!("jeryu_session_node_failed code={}", error.code());
            std::process::exit(1);
        }
    };
    if let Err(error) = serve(config).await {
        eprintln!("jeryu_session_node_failed code={}", error.code());
        std::process::exit(1);
    }
}
