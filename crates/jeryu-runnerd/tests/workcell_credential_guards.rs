//! Host credential material must never leave a workcell through a workspace
//! export, an artifact upload destination, a captured log, or a frozen capsule.
//!
//! Every case here drives the real validators the export path calls.

use jeryu_runnerd::workcell::{
    FreezeFailedCiRunRequest, HoldFailedTreeRequest, StartupSync, WorkcellClaimRequest,
    WorkcellManager, validate_capture_text, validate_export_destination, validate_export_paths,
};
use std::path::PathBuf;

fn root() -> PathBuf {
    PathBuf::from("/workcells/wc-0001/repo")
}

fn rebased_claim(agent_id: &str) -> WorkcellClaimRequest {
    WorkcellClaimRequest {
        agent_id: agent_id.into(),
        workspace_root: root(),
        repo_roots: vec![root()],
        branch_budget: 1,
        runner_id: "runner-17".into(),
        runner_epoch: 7,
        git_status_summary: "clean".into(),
        ci_snapshot_age_ms: Some(0),
        startup: StartupSync::Rebased {
            main_ref: "origin/main".into(),
            base_sha: "abc123".into(),
            head_sha: "def456".into(),
        },
    }
}

/// One credential shape per line, all of them INSIDE a permitted export root so
/// that only the credential guard can deny them. Each is also tried with
/// Windows separators and in upper case.
const CREDENTIAL_RELATIVE_PATHS: &[&str] = &[
    ".home/.config/gh/hosts.yml",
    ".claude/.credentials.json",
    ".codex/auth.json",
    ".jekko/users/jeryu-agent/llm.env",
    "agent-auth/claude/env",
    ".git-credentials",
    "nested/.netrc",
    "nested/_netrc",
    ".ssh/known_hosts",
    "keys/id_rsa",
    "keys/id_ed25519",
    ".aws/credentials",
    ".config/gh/hosts.yml",
    ".docker/config.json",
    "state/refresh_token.json",
    "state/refresh-token",
];

#[test]
fn export_refuses_host_credential_material_inside_a_permitted_root() {
    let allowed_roots = vec![root()];
    for relative in CREDENTIAL_RELATIVE_PATHS {
        for spelling in [
            (*relative).to_string(),
            relative.replace('/', "\\"),
            relative.to_uppercase(),
        ] {
            let path = root().join(&spelling);
            let err = validate_export_paths(std::slice::from_ref(&path), &allowed_roots)
                .expect_err("credential material must never be exported");
            assert_eq!(
                err.reason,
                "workcell_credential_material_denied",
                "{} must be denied as credential material",
                path.display()
            );
        }
    }

    // Repository content in the same root still exports.
    validate_export_paths(&[root().join("src/lib.rs")], &allowed_roots)
        .unwrap_or_else(|err| panic!("{err}"));
}

#[test]
fn export_destination_refuses_unlisted_roots_and_symlinks() {
    let temp = tempfile::tempdir().unwrap_or_else(|err| panic!("{err}"));
    let host_store = temp.path().join("host-store");
    std::fs::create_dir(&host_store).unwrap_or_else(|err| panic!("{err}"));
    let uploads = temp.path().join("uploads");
    std::fs::create_dir(&uploads).unwrap_or_else(|err| panic!("{err}"));
    let permitted = vec![uploads.clone()];

    validate_export_destination(&uploads.join("wc-0001.tar"), &permitted)
        .unwrap_or_else(|err| panic!("{err}"));

    let err = validate_export_destination(&host_store.join("wc-0001.tar"), &permitted)
        .expect_err("a destination outside the configured roots must be denied");
    assert_eq!(err.reason, "workcell_export_destination_denied");

    let linked = uploads.join("linked");
    std::os::unix::fs::symlink(&host_store, &linked).unwrap_or_else(|err| panic!("{err}"));
    let err = validate_export_destination(&linked.join("wc-0001.tar"), &permitted)
        .expect_err("an upload must not be written through a symlink");
    assert_eq!(err.reason, "workcell_export_destination_denied");
}

#[test]
fn capture_refuses_a_configured_token_value_in_a_log() {
    let token = "jrt-invented-value-9f3b".to_string();
    let forbidden = vec![token.clone()];

    let err = validate_capture_text(
        "log",
        &format!("cargo test failed: Authorization: Bearer {token}"),
        &forbidden,
    )
    .expect_err("a token value in a log must fail the capture");
    assert_eq!(err.reason, "workcell_capture_token_denied");
    assert!(
        !err.message().contains(&token),
        "the denial must not echo the token value: {}",
        err.message()
    );

    validate_capture_text("log", "cargo test failed: exit code 101", &forbidden)
        .unwrap_or_else(|err| panic!("{err}"));
}

#[test]
fn a_capsule_carrying_a_token_value_is_not_frozen() {
    let token = "jrt-invented-value-9f3b".to_string();
    let forbidden = vec![token.clone()];

    // The denylist is daemon configuration, never part of the request.
    let mut manager = WorkcellManager::with_warm_pool(1).with_forbidden_token_values(forbidden);
    // Claims are fenced on the fleet registry's epochs; admit the fixture runner's
    // epoch as RunnerFleet would, so the token guard is what refuses below.
    manager.sync_runner_epochs([("runner-17".to_string(), 7)]);
    let err = manager
        .hold_failed_tree(HoldFailedTreeRequest {
            claim: rebased_claim("agent-wrath-17"),
            ci_run_id: "ci-19".into(),
            failed_run_id: "run-19".into(),
            failed_receipt_id: "receipt-19".into(),
            failure_log_digest: format!("sha256:dead {token}"),
        })
        .expect_err("a capsule carrying a token value must not be frozen");
    assert_eq!(err.reason, "workcell_capture_token_denied");

    let lease = manager
        .claim(rebased_claim("agent-wrath-18"))
        .unwrap_or_else(|err| panic!("{err}"));
    let err = manager
        .freeze_failed_ci_run(
            &lease.workcell_id,
            lease.runner_epoch,
            FreezeFailedCiRunRequest {
                ci_run_id: "ci-20".into(),
                failed_run_id: "run-20".into(),
                failed_receipt_id: "receipt-20".into(),
                failure_log_digest: format!("sha256:dead {token}"),
                snapshot_age_ms: 10,
            },
        )
        .expect_err("a capsule carrying a token value must not be frozen");
    assert_eq!(err.reason, "workcell_capture_token_denied");
}

#[test]
fn manager_export_enforces_path_and_destination_guards() {
    let temp = tempfile::tempdir().unwrap_or_else(|err| panic!("{err}"));
    let uploads = temp.path().join("uploads");
    std::fs::create_dir(&uploads).unwrap_or_else(|err| panic!("{err}"));
    let elsewhere = temp.path().join("elsewhere");
    std::fs::create_dir(&elsewhere).unwrap_or_else(|err| panic!("{err}"));

    let mut manager =
        WorkcellManager::with_warm_pool(1).with_export_destination_roots(vec![uploads.clone()]);
    let lease = manager
        .hold_failed_tree(HoldFailedTreeRequest {
            claim: rebased_claim("agent-wrath-21"),
            ci_run_id: "ci-21".into(),
            failed_run_id: "run-21".into(),
            failed_receipt_id: "receipt-21".into(),
            failure_log_digest: "sha256:dead".into(),
        })
        .unwrap_or_else(|err| panic!("{err}"));
    let id = lease.workcell_id.as_str();
    let epoch = lease.runner_epoch;
    let tar = uploads.join("wc-0001.tar");
    let source = vec![root().join("src/lib.rs")];

    manager
        .export_workspace(id, epoch, &source, &tar)
        .unwrap_or_else(|err| panic!("{err}"));

    let err = manager
        .export_workspace(id, epoch, &[root().join(".codex/auth.json")], &tar)
        .expect_err("credential material must not leave through the manager");
    assert_eq!(err.reason, "workcell_credential_material_denied");

    let err = manager
        .export_workspace(id, epoch, &[PathBuf::from("/etc/passwd")], &tar)
        .expect_err("a path outside the repo roots must be denied");
    assert_eq!(err.reason, "workcell_tar_path_denied");

    let err = manager
        .export_workspace(id, epoch, &source, &elsewhere.join("wc-0001.tar"))
        .expect_err("a destination outside the configured roots must be denied");
    assert_eq!(err.reason, "workcell_export_destination_denied");

    let err = manager
        .export_workspace(id, epoch + 1, &source, &tar)
        .expect_err("a stale epoch must be fenced");
    assert_eq!(err.reason, "workcell_epoch_fenced");

    // No configured destination root means no export at all.
    let mut bare = WorkcellManager::with_warm_pool(1);
    let lease = bare
        .hold_failed_tree(HoldFailedTreeRequest {
            claim: rebased_claim("agent-wrath-22"),
            ci_run_id: "ci-22".into(),
            failed_run_id: "run-22".into(),
            failed_receipt_id: "receipt-22".into(),
            failure_log_digest: "sha256:dead".into(),
        })
        .unwrap_or_else(|err| panic!("{err}"));
    let err = bare
        .export_workspace(&lease.workcell_id, lease.runner_epoch, &source, &tar)
        .expect_err("an empty destination allowlist denies");
    assert_eq!(err.reason, "workcell_export_destination_denied");
}
