use super::*;
use jeryu_runner_core::job::{NetworkPolicy, SecretPolicy, TokenPolicy};
use jeryu_runner_core::policy::select_runner;
use jeryu_runner_core::sandbox::SandboxPlan;
use jeryu_runner_core::trust::TrustTier;
use std::path::PathBuf;
use std::sync::{
    Mutex,
    atomic::{AtomicU64, Ordering},
};
use std::time::{SystemTime, UNIX_EPOCH};

static EXECUTION_GUARD: Mutex<()> = Mutex::new(());

#[test]
fn output_summary_handles_multibyte_boundary_and_invalid_utf8() {
    let input = "€".repeat(2000);
    let summary = lossy_limit(input.as_bytes(), 4096);
    assert!(summary.ends_with("...[truncated]"));
    assert!(summary.len() <= 4096 + "...[truncated]".len());
    assert!(lossy_limit(&[0xff; 4097], 4096).ends_with("...[truncated]"));
}

#[test]
fn cancellation_before_launch_uses_failed_status_without_running_command() {
    let workspace = temp_dir();
    let job = JobRequest {
        job_id: "cancelled".into(),
        repo_id: "repo".into(),
        commit_sha: "abc".into(),
        workspace: workspace.clone(),
        command: "/bin/false".into(),
        args: Vec::new(),
        env: Default::default(),
        trust_tier: TrustTier::T1ProtectedInternal,
        requested_runner: None,
        network_policy: NetworkPolicy::Deny,
        secret_policy: SecretPolicy::Default,
        token_policy: TokenPolicy::ReadOnly,
        timeout_ms: 1000,
        fork: false,
    };
    let decision = select_runner(&job).unwrap();
    let plan = SandboxPlan::from_decision(&job.workspace, &decision);
    let options = WatchdogOptions::default();
    options.cancellation.cancel();
    let receipt = NativeRunner::new()
        .execute_with_options(&job, &decision, &plan, options)
        .unwrap();
    assert_eq!(receipt.status, ReceiptStatus::Failed);
    assert_eq!(receipt.exit_code, None);
    assert!(receipt.message.contains("cancelled before sandbox launch"));
    assert!(!workspace.exists());
}

#[test]
fn successful_exit_with_output_overflow_receipts_failure() {
    let _guard = EXECUTION_GUARD.lock().unwrap();
    let workspace = temp_dir();
    let job = JobRequest {
        job_id: "overflow".into(),
        repo_id: "repo".into(),
        commit_sha: "abc".into(),
        workspace: workspace.clone(),
        command: "/bin/echo".into(),
        args: vec!["too much output".into()],
        env: Default::default(),
        trust_tier: TrustTier::T1ProtectedInternal,
        requested_runner: None,
        network_policy: NetworkPolicy::Deny,
        secret_policy: SecretPolicy::Default,
        token_policy: TokenPolicy::ReadOnly,
        timeout_ms: 1000,
        fork: false,
    };
    let decision = select_runner(&job).unwrap();
    let plan = SandboxPlan::from_decision(&job.workspace, &decision);
    let mut options = WatchdogOptions::default();
    options.capture.max_bytes_per_stream = 4;
    let receipt = NativeRunner::new()
        .execute_with_options(&job, &decision, &plan, options)
        .unwrap();
    assert_eq!(receipt.status, ReceiptStatus::Failed);
    assert!(
        receipt.message.contains("output_limit_exceeded=true"),
        "{}",
        receipt.message
    );
    assert!(receipt.message.contains("termination_scope="));
    fs::remove_dir(workspace).unwrap();
}

fn temp_dir() -> PathBuf {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!("jeryu-native-test-{stamp}-{unique}"))
}

#[test]
fn executes_echo_and_receipts_pass() {
    let _guard = EXECUTION_GUARD.lock().unwrap();
    let workspace = temp_dir();
    let job = JobRequest {
        job_id: "job".to_string(),
        repo_id: "repo".to_string(),
        commit_sha: "abc".to_string(),
        workspace,
        command: "/bin/echo".to_string(),
        args: vec!["ok".to_string()],
        env: Default::default(),
        trust_tier: TrustTier::T1ProtectedInternal,
        requested_runner: None,
        network_policy: NetworkPolicy::Deny,
        secret_policy: SecretPolicy::Default,
        token_policy: TokenPolicy::ReadOnly,
        timeout_ms: 1000,
        fork: false,
    };
    let decision = select_runner(&job).unwrap_or_else(|err| panic!("{err}"));
    let plan = SandboxPlan::from_decision(&job.workspace, &decision);
    let receipt = NativeRunner::new()
        .execute(&job, &decision, &plan)
        .unwrap_or_else(|err| panic!("{err}"));
    assert_eq!(receipt.status, ReceiptStatus::Passed);
    assert_eq!(receipt.exit_code, Some(0));
    // The receipt must carry the PROVEN enforcement state, not a claim.
    assert!(
        receipt.message.contains("enforcement=level="),
        "receipt must record enforcement state: {}",
        receipt.message
    );
}

#[test]
fn ci_shell_steps_can_fork_when_cgroups_degrade() {
    let _guard = EXECUTION_GUARD.lock().unwrap();
    let workspace = temp_dir();
    let job = JobRequest {
        job_id: "ci-shell".to_string(),
        repo_id: "repo".to_string(),
        commit_sha: "abc".to_string(),
        workspace,
        command: "/bin/sh".to_string(),
        args: vec!["-lc".to_string(), "/bin/echo ok >/dev/null".to_string()],
        env: Default::default(),
        trust_tier: TrustTier::T2InternalBranch,
        requested_runner: Some(jeryu_runner_core::trust::RunnerClass::NativeRustClean),
        network_policy: NetworkPolicy::EgressOnly,
        secret_policy: SecretPolicy::None,
        token_policy: TokenPolicy::None,
        timeout_ms: 1000,
        fork: false,
    };
    let decision = select_runner(&job).unwrap_or_else(|err| panic!("{err}"));
    let plan = SandboxPlan::from_decision(&job.workspace, &decision);
    assert!(
        !plan.require_cgroup,
        "ordinary CI jobs must not use the agent fail-closed cgroup gate"
    );
    let receipt = NativeRunner::new()
        .execute(&job, &decision, &plan)
        .unwrap_or_else(|err| panic!("{err}"));
    assert_eq!(
        receipt.status,
        ReceiptStatus::Passed,
        "normal CI shell steps must be able to fork under degraded cgroups: {}",
        receipt.message
    );
}

#[test]
fn watchdog_timeout_maps_to_timed_out_status() {
    let _guard = EXECUTION_GUARD.lock().unwrap();
    let workspace = temp_dir();
    let job = JobRequest {
        job_id: "job".to_string(),
        repo_id: "repo".to_string(),
        commit_sha: "abc".to_string(),
        workspace,
        command: "/bin/sleep".to_string(),
        args: vec!["30".to_string()],
        env: Default::default(),
        trust_tier: TrustTier::T1ProtectedInternal,
        requested_runner: None,
        network_policy: NetworkPolicy::Deny,
        secret_policy: SecretPolicy::Default,
        token_policy: TokenPolicy::ReadOnly,
        timeout_ms: 250,
        fork: false,
    };
    let decision = select_runner(&job).unwrap_or_else(|err| panic!("{err}"));
    let plan = SandboxPlan::from_decision(&job.workspace, &decision);
    let receipt = NativeRunner::new()
        .execute(&job, &decision, &plan)
        .unwrap_or_else(|err| panic!("{err}"));
    assert_eq!(
        receipt.status,
        ReceiptStatus::TimedOut,
        "a runaway must be killed by the watchdog and recorded as TimedOut"
    );
    assert!(receipt.message.contains("timed_out_after_ms="));
}

#[test]
fn native_runner_sanitizes_process_environment() {
    let _guard = EXECUTION_GUARD.lock().unwrap();
    let workspace = temp_dir();
    let mut env = std::collections::BTreeMap::new();
    env.insert("SSH_AUTH_SOCK".to_string(), "/tmp/leaked-agent".to_string());
    env.insert("AWS_ACCESS_KEY_ID".to_string(), "leaked-key".to_string());
    env.insert("RUST_LOG".to_string(), "debug".to_string());
    let job = JobRequest {
        job_id: "job".to_string(),
        repo_id: "repo".to_string(),
        commit_sha: "abc".to_string(),
        workspace,
        command: "/usr/bin/env".to_string(),
        args: vec!["-0".to_string()],
        env,
        trust_tier: TrustTier::T1ProtectedInternal,
        requested_runner: None,
        network_policy: NetworkPolicy::Deny,
        secret_policy: SecretPolicy::None,
        token_policy: TokenPolicy::ReadOnly,
        timeout_ms: 1000,
        fork: false,
    };
    let decision = select_runner(&job).unwrap_or_else(|err| panic!("{err}"));
    let plan = SandboxPlan::from_decision(&job.workspace, &decision);
    let receipt = NativeRunner::new()
        .execute(&job, &decision, &plan)
        .unwrap_or_else(|err| panic!("{err}"));
    assert_eq!(receipt.status, ReceiptStatus::Passed);
    assert!(receipt.message.contains("RUST_LOG=debug"));
    assert!(receipt.message.contains("JERYU_SECRETS=disabled"));
    assert!(!receipt.message.contains("leaked-agent"));
    assert!(!receipt.message.contains("leaked-key"));
    assert!(!receipt.message.contains("SSH_AUTH_SOCK="));
    assert!(!receipt.message.contains("AWS_ACCESS_KEY_ID="));
}

#[test]
fn execute_rejects_invalid_job_before_spawn() {
    let mut job = JobRequest {
        job_id: "job".to_string(),
        repo_id: "repo".to_string(),
        commit_sha: "abc".to_string(),
        workspace: temp_dir(),
        command: "/bin/echo".to_string(),
        args: vec!["ok".to_string()],
        env: Default::default(),
        trust_tier: TrustTier::T1ProtectedInternal,
        requested_runner: None,
        network_policy: NetworkPolicy::Deny,
        secret_policy: SecretPolicy::Default,
        token_policy: TokenPolicy::ReadOnly,
        timeout_ms: 1000,
        fork: false,
    };
    let decision = select_runner(&job).unwrap_or_else(|err| panic!("{err}"));
    let plan = SandboxPlan::from_decision(&job.workspace, &decision);
    job.workspace = PathBuf::from("relative");
    let err = NativeRunner::new()
        .execute(&job, &decision, &plan)
        .err()
        .unwrap_or_else(|| panic!("expected validation failure"));
    assert_eq!(err.code(), "invalid_workspace");
}

#[test]
fn plan_only_rejects_invalid_job_before_receipt() {
    let mut job = JobRequest {
        job_id: "job".to_string(),
        repo_id: "repo".to_string(),
        commit_sha: "abc".to_string(),
        workspace: temp_dir(),
        command: "/bin/echo".to_string(),
        args: vec!["ok".to_string()],
        env: Default::default(),
        trust_tier: TrustTier::T1ProtectedInternal,
        requested_runner: None,
        network_policy: NetworkPolicy::Deny,
        secret_policy: SecretPolicy::Default,
        token_policy: TokenPolicy::ReadOnly,
        timeout_ms: 1000,
        fork: false,
    };
    let decision = select_runner(&job).unwrap_or_else(|err| panic!("{err}"));
    let plan = SandboxPlan::from_decision(&job.workspace, &decision);
    job.timeout_ms = 0;
    let err = NativeRunner::new()
        .plan_only(&job, &decision, &plan)
        .err()
        .unwrap_or_else(|| panic!("expected validation failure"));
    assert_eq!(err.code(), "invalid_job");
}
