//! Dedicated root node service. Its trusted config, not RPC callers, chooses
//! TLS identities, release authority, artifact store and bounded node capacity.
use jeryu_runnerd::session_node::{SessionNodeConfig, serve};
use std::path::Path;

// Supplied by the trusted builder. An unstamped developer build says unknown;
// runtime environment/cwd never supplies or changes the compiled identity.
const RUNTIME_SOURCE_HEAD: &str = match option_env!("JERYU_RUNTIME_SOURCE_HEAD") {
    Some(head) => {
        assert!(
            valid_source_head(head),
            "JERYU_RUNTIME_SOURCE_HEAD must be a lowercase 40-hex commit"
        );
        head
    }
    None => "unknown",
};

const fn valid_source_head(head: &str) -> bool {
    let bytes = head.as_bytes();
    if bytes.len() != 40 {
        return false;
    }
    let mut index = 0;
    while index < bytes.len() {
        let byte = bytes[index];
        if !((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f')) {
            return false;
        }
        index += 1;
    }
    true
}

#[tokio::main]
async fn main() {
    match jeryu_runner_microvm::guardian::run_if_requested() {
        Ok(true) => return,
        Ok(false) => (),
        Err(error) => {
            eprintln!("jeryu_vm_guardian_failed code={}", error.code());
            std::process::exit(1);
        }
    }
    if jeryu_sandbox_linux::microvm::disable_core_dumps().is_err() {
        eprintln!("jeryu_session_node_failed code=core_dump_limit_failed");
        std::process::exit(1);
    }
    let arguments: Vec<_> = std::env::args().collect();
    if arguments.len() == 2 && arguments[1] == "--build-identity" {
        println!(
            "{}",
            serde_json::json!({"runtime_source_head": RUNTIME_SOURCE_HEAD})
        );
        return;
    }
    if arguments.len() != 3 || arguments[1] != "--config" {
        eprintln!("usage: jeryu-session-node --config ROOT_OWNED_CONFIG | --build-identity");
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

#[cfg(test)]
mod tests {
    use super::valid_source_head;

    #[test]
    fn build_identity_accepts_only_complete_lowercase_commit_ids() {
        assert!(valid_source_head(
            "61f55fe0d66bd36422a3cc55fb03ee70c4691830"
        ));
        for invalid in [
            "unknown",
            "61f55fe",
            "61F55fe0d66bd36422a3cc55fb03ee70c4691830",
            "g1f55fe0d66bd36422a3cc55fb03ee70c4691830",
            "61f55fe0d66bd36422a3cc55fb03ee70c4691830\n",
        ] {
            assert!(!valid_source_head(invalid));
        }
    }
}
