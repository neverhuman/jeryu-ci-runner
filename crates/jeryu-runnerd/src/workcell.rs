//! Workcell control-plane primitives for the shared runner/CI stack.
//!
//! The manager here is intentionally in-memory and narrow: it models a warm
//! pool, epoch-fenced claims, startup rebase enforcement, immutable CI repair
//! snapshots, and quarantine-first tar validation without inventing a new
//! runner class.

mod archive;
mod error;
mod manager;
mod model;

use archive::{is_within_any_root, validate_archive_entry, validate_export_path};

use jeryu_runner_core::credguard::{
    deny_credential_material, deny_token_values, guard_write_destination,
};
use jeryu_runner_core::error::RunnerError;

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fmt::{Display, Formatter};
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};

/// Structured repair guidance for workcell failures.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkcellError {
    pub purpose: &'static str,
    pub reason: &'static str,
    pub common_fixes: &'static [&'static str],
    pub docs_url: &'static str,
    pub repair_hint: &'static str,
    message: String,
}

/// Result alias for workcell operations.
pub type WorkcellResult<T> = Result<T, WorkcellError>;

/// Kind of archive entry the workcell import/export helper is allowed to
/// inspect.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArchiveEntryKind {
    File,
    Directory,
    Symlink,
    Hardlink,
    CharacterDevice,
    BlockDevice,
    Fifo,
    Socket,
}

/// One tar archive entry used by the quarantine-first path validator.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArchiveEntry {
    pub path: PathBuf,
    pub kind: ArchiveEntryKind,
    pub link_target: Option<PathBuf>,
}

/// Startup sync required before a workcell is handed to the agent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum StartupSync {
    Rebased {
        main_ref: String,
        base_sha: String,
        head_sha: String,
    },
    Failed {
        main_ref: String,
        base_sha: String,
        head_sha: String,
        reason: String,
    },
}

/// Branch budget and namespace policy for one workcell.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BranchPolicy {
    pub agent_id: String,
    pub workcell_id: String,
    pub max_branches: u32,
    pub open_branches: BTreeSet<String>,
    pub merge_allowed: bool,
    pub delete_allowed: bool,
}

/// Immutable frozen snapshot of a failed CI run.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FrozenCiSnapshot {
    pub ci_run_id: String,
    pub failed_run_id: String,
    pub failed_receipt_id: String,
    pub workcell_id: String,
    pub runner_id: String,
    /// The frozen cell's own fencing token (a repair cell's is bumped).
    pub runner_epoch: u64,
    /// The runner lifetime the registry admitted when the frozen cell's chain
    /// was first claimed. Repair is fenced on this, never on the token above.
    pub admitted_runner_epoch: u64,
    pub workspace_root: PathBuf,
    pub repo_roots: Vec<PathBuf>,
    pub allowed_paths: Vec<PathBuf>,
    pub git_status_summary: String,
    pub branch_policy: BranchPolicy,
    pub main_ref: String,
    pub base_sha: String,
    pub head_sha: String,
    pub failure_log_digest: String,
    pub snapshot_age_ms: u64,
    pub heartbeat_healthy: bool,
}

/// Current lifecycle state of a workcell lease.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkcellState {
    Warming,
    Ready,
    Claimed,
    Held,
    Repairing,
    Blocked,
    Released,
}

/// Claim request for a workcell.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkcellClaimRequest {
    pub agent_id: String,
    pub workspace_root: PathBuf,
    pub repo_roots: Vec<PathBuf>,
    pub branch_budget: u32,
    pub runner_id: String,
    pub runner_epoch: u64,
    pub git_status_summary: String,
    pub ci_snapshot_age_ms: Option<u64>,
    pub startup: StartupSync,
}

/// Request to freeze failed CI evidence before starting live repair.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FreezeFailedCiRunRequest {
    pub ci_run_id: String,
    pub failed_run_id: String,
    pub failed_receipt_id: String,
    pub failure_log_digest: String,
    pub snapshot_age_ms: u64,
}

/// Request to repair from a frozen snapshot. `runner_id` and `runner_epoch`
/// are the caller's own identity, fenced against the daemon's registry; the
/// snapshot's chain must belong to that runner lifetime.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RepairFromSnapshotRequest {
    pub runner_id: String,
    pub runner_epoch: u64,
    pub snapshot: FrozenCiSnapshot,
    pub startup: StartupSync,
}

/// Request to hold a failed tree for live repair.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HoldFailedTreeRequest {
    pub claim: WorkcellClaimRequest,
    pub ci_run_id: String,
    pub failed_run_id: String,
    pub failed_receipt_id: String,
    pub failure_log_digest: String,
}

/// One live workcell lease.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkcellLease {
    pub workcell_id: String,
    pub state: WorkcellState,
    pub agent_id: String,
    pub workspace_root: PathBuf,
    pub repo_roots: Vec<PathBuf>,
    pub startup_head_sha: Option<String>,
    pub branch_policy: BranchPolicy,
    pub git_status_summary: String,
    pub ci_snapshot_age_ms: Option<u64>,
    pub runner_id: String,
    /// This cell's own fencing token: per-cell operations must present it.
    /// A repair cell carries its snapshot's token plus one.
    pub runner_epoch: u64,
    /// The runner lifetime the registry admitted for this cell's claim chain.
    /// It is never bumped, so a repair of a repair is still fenced on the
    /// runner's real epoch.
    pub admitted_runner_epoch: u64,
    pub heartbeat_healthy: bool,
    pub startup_rebased: bool,
    pub startup_main_ref: Option<String>,
    pub startup_base_sha: Option<String>,
    pub failed_run_id: Option<String>,
    pub failed_receipt_id: Option<String>,
    pub allowed_paths: Vec<PathBuf>,
    pub failure_log_digest: Option<String>,
    pub frozen_snapshot: Option<FrozenCiSnapshot>,
    pub blocked_reason: Option<String>,
}

/// How far the daemon's registry admits a runner lifetime past the
/// work-cell fence.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunnerAdmission {
    /// The runner takes fresh work cells and carries its in-flight work.
    Active,
    /// The runner takes no fresh work cell (claim, warm cell or failed-tree
    /// hold); it may only repair from a frozen snapshot of its existing
    /// in-flight work.
    Draining,
}

/// One runner lifetime on the work-cell fence: the epoch the registry issued
/// it and how far that lifetime is admitted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdmittedRunner {
    pub epoch: u64,
    pub admission: RunnerAdmission,
}

/// In-memory workcell warm-pool and claim ledger.
#[derive(Debug, Default, Clone)]
pub struct WorkcellManager {
    /// Token values from the daemon's own configuration that must never appear
    /// in a frozen capsule. They are never taken from a freeze or hold request:
    /// the party whose capsule is screened must not be able to empty the list.
    forbidden_token_values: Vec<String>,
    /// Roots an export may be written under, from the daemon's configuration.
    /// Empty means no export destination is permitted.
    export_destination_roots: Vec<PathBuf>,
    next_id: u64,
    ready_queue: VecDeque<String>,
    cells: BTreeMap<String, WorkcellLease>,
    /// Current epoch and admission per admitted runner, as issued by the
    /// daemon's registry. A runner not listed here, or a request carrying any
    /// other epoch, comes from a lifetime the daemon did not admit and is
    /// fenced; a draining runner is admitted only to repair from a snapshot.
    runner_epochs: BTreeMap<String, AdmittedRunner>,
    /// Source cells a repair cell has already been minted from. Repair is
    /// one-shot per source cell, so replaying a snapshot mints nothing.
    repaired_sources: BTreeSet<String>,
}

/// The ledger's own record of a repair's source cell, from which the repair
/// cell is seeded instead of from the caller's snapshot.
struct RepairSource {
    runner_id: String,
    runner_epoch: u64,
    admitted_runner_epoch: u64,
    agent_id: String,
    workspace_root: PathBuf,
    repo_roots: Vec<PathBuf>,
    allowed_paths: Vec<PathBuf>,
}

/// Validate incoming archive entries before extraction into a workcell repo.
pub fn validate_import_archive(
    entries: &[ArchiveEntry],
    destination_root: impl AsRef<Path>,
    allowed_repo_roots: &[PathBuf],
) -> WorkcellResult<()> {
    let destination_root = destination_root.as_ref();
    if !is_within_any_root(destination_root, allowed_repo_roots) {
        return Err(WorkcellError::tar_path_denied(format!(
            "destination root {} is outside the approved repo roots",
            destination_root.display()
        )));
    }
    for entry in entries {
        validate_archive_entry(entry, destination_root, allowed_repo_roots)?;
    }
    Ok(())
}

/// Validate a set of filesystem paths before exporting them into an outbound
/// tarball. `allowed_repo_roots` is the configured allowlist of permitted
/// export roots; on top of it, host credential material is refused even when it
/// sits inside a permitted root, because the native runner mints the per-run
/// agent home under the workspace.
pub fn validate_export_paths(
    paths: &[PathBuf],
    allowed_repo_roots: &[PathBuf],
) -> WorkcellResult<()> {
    for path in paths {
        validate_export_path(path)?;
        if !is_within_any_root(path, allowed_repo_roots) {
            return Err(WorkcellError::tar_path_denied(format!(
                "export path {} is outside the approved repo roots",
                path.display()
            )));
        }
        deny_credential_material(path).map_err(WorkcellError::from_credential_guard)?;
    }
    Ok(())
}

/// Validate the destination an outbound export, uploaded artifact, log or
/// capsule is about to be WRITTEN to. `allowed_destination_roots` is the
/// configured allowlist; the destination must additionally not pass through a
/// symlink, so a planted link cannot redirect the write onto host credentials.
pub fn validate_export_destination(
    destination: &Path,
    allowed_destination_roots: &[PathBuf],
) -> WorkcellResult<()> {
    guard_write_destination(destination, allowed_destination_roots)
        .map_err(WorkcellError::from_credential_guard)
}

/// Validate one captured log or capsule body before it leaves the workcell: a
/// configured token value appearing in the capture fails the capture outright.
/// `label` names the surface (`log`, `capsule`) so the denial points at it.
pub fn validate_capture_text(
    label: &str,
    text: &str,
    forbidden_token_values: &[String],
) -> WorkcellResult<()> {
    deny_token_values(label, text, forbidden_token_values)
        .map_err(WorkcellError::from_credential_guard)
}

#[cfg(test)]
mod tests;
