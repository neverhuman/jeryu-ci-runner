//! Fixed image-class overlay for trusted, unmounted builder staging trees.
//! This composes data only; recipes, hooks, signing and provenance are separate.
use jeryu_runner_core::{RunnerError, RunnerResult};
use jeryu_runner_protocol::wire::v2::RuntimeImageClass;
use nix::unistd::Uid;
use std::path::Path;

mod io;
#[cfg(test)]
mod tests;

const MOCK_AGENT: &[u8] = include_bytes!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../images/agent-microvm/test/mock-agent"
));

/// Compose the closed production/test overlay exactly once. The trusted image
/// producer supplies this staging path; no guest or session RPC can select it.
pub fn compose(root: &Path, image_class: RuntimeImageClass) -> RunnerResult<()> {
    if !Uid::effective().is_root() {
        return Err(denied("image_staging_custody_denied"));
    }
    let staging = io::trusted_root(root)?;
    if image_class == RuntimeImageClass::Production
        && let Some(parent) = io::directories(&staging, &["usr", "lib", "jeryu"], false)?
        && io::entry_exists(&parent, "mock")?
    {
        return Err(denied("production_mock_entrypoint_denied"));
    }
    let config = io::directories(&staging, &["etc", "jeryu"], true)?
        .ok_or_else(|| denied("image_staging_custody_denied"))?;
    if io::entry_exists(&config, "runtime-image-class")? {
        return Err(denied("image_class_already_composed"));
    }
    let marker: &[u8] = match image_class {
        RuntimeImageClass::Production => b"production\n",
        RuntimeImageClass::Test => {
            let mock = io::directories(&staging, &["usr", "lib", "jeryu", "mock"], true)?
                .ok_or_else(|| denied("image_staging_custody_denied"))?;
            if io::entry_exists(&mock, "agent")? {
                return Err(denied("mock_entrypoint_already_composed"));
            }
            // The readiness marker is last. A failed mock copy cannot identify
            // a partial TEST tree as a completed class overlay.
            io::write_fixed(&mock, "agent", MOCK_AGENT, 0o555)?;
            b"test\n"
        }
    };
    io::write_fixed(&config, "runtime-image-class", marker, 0o444)
}

fn denied(code: &'static str) -> RunnerError {
    RunnerError::new(code, "runtime class composition failed")
}
