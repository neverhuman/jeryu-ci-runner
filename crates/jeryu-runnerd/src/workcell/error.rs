//! Structured workcell failure implementations and deterministic repair guidance.

use super::*;

const CLAIM_FIXES: &[&str] = &[
    "fetch remote main and rebase before handing the cell to the agent",
    "keep the claim epoch attached to every heartbeat, release, and repair call",
];

const STARTUP_REBASE_FIXES: &[&str] = &[
    "refresh the failed snapshot from the frozen evidence copy",
    "rerun the startup rebase instead of bypassing the failure",
];

const BRANCH_BUDGET_FIXES: &[&str] = &[
    "keep branches namespaced to the agent and workcell",
    "raise the budget only through the explicit five-branch override",
];

const TAR_PATH_FIXES: &[&str] = &[
    "extract only into approved repo roots",
    "reject absolute paths, parent traversal, and special files before unpacking",
];

const CREDENTIAL_MATERIAL_FIXES: &[&str] = &[
    "export only repository content; leave the per-run agent home behind",
    "keep host credential stores out of the export, upload, and capsule manifests",
];

const EXPORT_DESTINATION_FIXES: &[&str] = &[
    "write the export into a configured destination root, never through a symlink",
    "replace a symlinked destination with a real directory before exporting",
];

const CAPTURE_TOKEN_FIXES: &[&str] = &[
    "fix the step that printed the token value instead of exporting the capture",
    "keep token values out of logs and capsules; receipts record digests only",
];

const EPOCH_FENCE_FIXES: &[&str] = &[
    "refresh the workcell lease before retrying the mutation",
    "discard outdated heartbeats or releases that carry a prior epoch",
];

const MERGE_DELETE_FIXES: &[&str] = &[
    "keep merge control in the existing review and queue path",
    "do not route delete requests through the workcell control plane",
];

const REPAIR_STATE_FIXES: &[&str] = &[
    "hold the failed tree before live repair",
    "start live repair only after the workcell is in the held state",
];

/// Stable `reason` codes, for callers that branch on the kind of refusal.
const REASON_CLAIM_DENIED: &str = "workcell_claim_denied";
pub(crate) const REASON_STARTUP_REBASE_FAILED: &str = "workcell_startup_rebase_failed";
pub(crate) const REASON_EPOCH_FENCED: &str = "workcell_epoch_fenced";

impl WorkcellError {
    fn new(
        purpose: &'static str,
        reason: &'static str,
        common_fixes: &'static [&'static str],
        docs_url: &'static str,
        repair_hint: &'static str,
        message: impl Into<String>,
    ) -> Self {
        Self {
            purpose,
            reason,
            common_fixes,
            docs_url,
            repair_hint,
            message: message.into(),
        }
    }

    pub(super) fn claim_denied(message: impl Into<String>) -> Self {
        Self::new(
            "claim a ready workcell",
            REASON_CLAIM_DENIED,
            CLAIM_FIXES,
            "docs/testing.md#workcells",
            "rerun cargo test -p jeryu-runnerd workcell --jobs 40",
            message,
        )
    }

    pub(super) fn startup_rebase_failed(message: impl Into<String>) -> Self {
        Self::new(
            "fetch main and rebase the workcell",
            REASON_STARTUP_REBASE_FAILED,
            STARTUP_REBASE_FIXES,
            "docs/testing.md#workcells",
            "rerun cargo test -p jeryu-runnerd workcell --jobs 40",
            message,
        )
    }

    pub(super) fn branch_budget_denied(message: impl Into<String>) -> Self {
        Self::new(
            "enforce the agent branch budget",
            "workcell_branch_budget_denied",
            BRANCH_BUDGET_FIXES,
            "docs/boundaries.md#workcells",
            "rerun cargo test -p jeryu-runnerd workcell --jobs 40",
            message,
        )
    }

    pub(super) fn tar_path_denied(message: impl Into<String>) -> Self {
        Self::new(
            "validate quarantine-first tar paths",
            "workcell_tar_path_denied",
            TAR_PATH_FIXES,
            "docs/testing.md#workcells",
            "rerun cargo test -p jeryu-runnerd workcell --jobs 40",
            message,
        )
    }

    pub(super) fn credential_material_denied(message: impl Into<String>) -> Self {
        Self::new(
            "keep host credential material out of workcell exports",
            "workcell_credential_material_denied",
            CREDENTIAL_MATERIAL_FIXES,
            "docs/boundaries.md#workcells",
            "rerun cargo test -p jeryu-runnerd workcell --jobs 40",
            message,
        )
    }

    pub(super) fn export_destination_denied(message: impl Into<String>) -> Self {
        Self::new(
            "write an export only into a configured destination root",
            "workcell_export_destination_denied",
            EXPORT_DESTINATION_FIXES,
            "docs/boundaries.md#workcells",
            "rerun cargo test -p jeryu-runnerd workcell --jobs 40",
            message,
        )
    }

    pub(super) fn capture_token_denied(message: impl Into<String>) -> Self {
        Self::new(
            "keep token values out of captured logs and capsules",
            "workcell_capture_token_denied",
            CAPTURE_TOKEN_FIXES,
            "docs/boundaries.md#workcells",
            "rerun cargo test -p jeryu-runnerd workcell --jobs 40",
            message,
        )
    }

    pub(super) fn epoch_fenced(message: impl Into<String>) -> Self {
        Self::new(
            "fence outdated workcell epochs",
            REASON_EPOCH_FENCED,
            EPOCH_FENCE_FIXES,
            "docs/boundaries.md#workcells",
            "rerun cargo test -p jeryu-runnerd workcell --jobs 40",
            message,
        )
    }

    pub(super) fn merge_denied(message: impl Into<String>) -> Self {
        Self::new(
            "keep merge control out of the workcell",
            "workcell_merge_denied",
            MERGE_DELETE_FIXES,
            "docs/boundaries.md#workcells",
            "rerun cargo test -p jeryu-runnerd workcell --jobs 40",
            message,
        )
    }

    pub(super) fn delete_denied(message: impl Into<String>) -> Self {
        Self::new(
            "keep delete control out of the workcell",
            "workcell_delete_denied",
            MERGE_DELETE_FIXES,
            "docs/boundaries.md#workcells",
            "rerun cargo test -p jeryu-runnerd workcell --jobs 40",
            message,
        )
    }

    pub(super) fn repair_state_denied(message: impl Into<String>) -> Self {
        Self::new(
            "hold a failed workcell before live repair",
            "workcell_repair_state_denied",
            REPAIR_STATE_FIXES,
            "docs/boundaries.md#workcells",
            "rerun cargo test -p jeryu-runnerd workcell --jobs 40",
            message,
        )
    }

    /// Translate a `jeryu-runner-core` credential-guard denial into the
    /// workcell repair surface, keeping the guard's message (which never
    /// carries a secret value) as the detail.
    pub(super) fn from_credential_guard(error: RunnerError) -> Self {
        match error.code() {
            "export_root_denied" | "destination_symlink_denied" => {
                Self::export_destination_denied(error.message().to_string())
            }
            "token_value_in_capture" => Self::capture_token_denied(error.message().to_string()),
            _ => Self::credential_material_denied(error.message().to_string()),
        }
    }

    pub fn message(&self) -> &str {
        &self.message
    }
}

impl Display for WorkcellError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.reason, self.message)
    }
}

impl std::error::Error for WorkcellError {}
