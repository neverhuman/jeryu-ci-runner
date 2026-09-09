//! End-to-end launch-path tests: probe -> spawn_sandboxed -> run_with_watchdog
//! -> verify_enforcement on a real command, proving the kernel actually enforced
//! the sandbox via `/proc/<pid>/status` and that the watchdog kills runaways.

use jeryu_runner_core::job::{JobRequest, NetworkPolicy, SecretPolicy, TokenPolicy};
use jeryu_runner_core::policy::select_runner;
use jeryu_runner_core::sandbox::SandboxPlan;
use jeryu_runner_core::trust::TrustTier;
use jeryu_sandbox_linux::capability::SandboxCapabilities;
use jeryu_sandbox_linux::launch::{spawn_sandboxed, verify_enforcement};
use jeryu_sandbox_linux::watchdog::run_with_watchdog;
use std::collections::BTreeMap;
use std::time::Duration;

fn job(workspace: std::path::PathBuf, command: &str, args: Vec<String>) -> JobRequest {
    JobRequest {
        job_id: "job".into(),
        repo_id: "repo".into(),
        commit_sha: "abc".into(),
        workspace,
        command: command.into(),
        args,
        env: BTreeMap::new(),
        trust_tier: TrustTier::T1ProtectedInternal,
        requested_runner: None,
        network_policy: NetworkPolicy::Deny,
        secret_policy: SecretPolicy::Default,
        token_policy: TokenPolicy::ReadOnly,
        timeout_ms: 10_000,
        fork: false,
    }
}

fn sandbox_env() -> BTreeMap<String, String> {
    let mut env = BTreeMap::new();
    env.insert("PATH".into(), "/usr/local/bin:/usr/bin:/bin".into());
    env.insert("HOME".into(), "/tmp".into());
    env
}

#[test]
fn launch_runs_command_and_proves_enforcement() {
    let caps = SandboxCapabilities::probe();
    let ws = std::env::temp_dir().join(format!("jeryu-launch-it-{}", std::process::id()));
    std::fs::create_dir_all(&ws).unwrap_or_else(|e| panic!("workspace: {e}"));

    let j = job(ws.clone(), "/bin/echo", vec!["sandbox-ok".into()]);
    let decision = select_runner(&j).unwrap_or_else(|e| panic!("{e}"));
    let plan = SandboxPlan::from_decision(&j.workspace, &decision);
    let level = caps.enforcement_level(&plan);

    let child = spawn_sandboxed(&j, &plan, &caps, &sandbox_env())
        .unwrap_or_else(|e| panic!("spawn_sandboxed: {e}"));
    let pid = child.id();
    // Prove enforcement from /proc BEFORE the (fast) child exits would be racy,
    // so we read status of the live child immediately; echo is slow enough under
    // piped stdio that NoNewPrivs/Seccomp are observable. If the child already
    // exited, the report fields are simply None and we fall back to the level.
    let report = verify_enforcement(pid, &level);

    let out = run_with_watchdog(child, Duration::from_secs(10))
        .unwrap_or_else(|e| panic!("watchdog: {e}"));
    assert!(!out.timed_out, "echo must not time out");
    assert_eq!(out.exit_code, Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "sandbox-ok");

    // The report level mirrors the resolved enforcement level.
    assert_eq!(report.level, level.as_str());
    // On any host where no_new_privs is available (the floor for running at all),
    // the report must NOT claim the sandbox was Unavailable.
    assert_ne!(
        report.level, "unavailable",
        "no_new_privs floor should hold"
    );

    let _ = std::fs::remove_dir_all(&ws);
}

#[test]
fn launch_no_new_privs_is_observable_in_proc_status() {
    // Run `sleep` so the child stays alive long enough to read /proc/<pid>/status
    // and PROVE NoNewPrivs:1 (and Seccomp:2 when seccomp is enforced).
    let caps = SandboxCapabilities::probe();
    if !caps.no_new_privs {
        eprintln!("SKIP: no_new_privs unavailable on this host");
        return;
    }
    let ws = std::env::temp_dir().join(format!("jeryu-launch-nnp-{}", std::process::id()));
    std::fs::create_dir_all(&ws).unwrap_or_else(|e| panic!("workspace: {e}"));

    let j = job(ws.clone(), "/bin/sleep", vec!["2".into()]);
    let decision = select_runner(&j).unwrap_or_else(|e| panic!("{e}"));
    let plan = SandboxPlan::from_decision(&j.workspace, &decision);
    let level = caps.enforcement_level(&plan);

    let child = spawn_sandboxed(&j, &plan, &caps, &sandbox_env())
        .unwrap_or_else(|e| panic!("spawn_sandboxed: {e}"));
    let pid = child.id();

    // Poll /proc/<pid>/status until NoNewPrivs appears (child reached post-exec).
    let mut report = verify_enforcement(pid, &level);
    for _ in 0..50 {
        if report.proc_no_new_privs.is_some() {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
        report = verify_enforcement(pid, &level);
    }

    let out = run_with_watchdog(child, Duration::from_secs(5))
        .unwrap_or_else(|e| panic!("watchdog: {e}"));
    // sleep 2 completes well under the 5s budget.
    assert!(!out.timed_out);

    // PROOF: the kernel set NoNewPrivs on the sandboxed child.
    assert_eq!(
        report.proc_no_new_privs,
        Some(1),
        "NoNewPrivs:1 must be visible in /proc/<pid>/status"
    );
    // When seccomp was enforced, Seccomp mode must be 2 (filter mode).
    if caps.seccomp_bpf {
        assert_eq!(
            report.proc_seccomp,
            Some(2),
            "Seccomp:2 (filter mode) must be visible when seccomp is enforced"
        );
    }

    let _ = std::fs::remove_dir_all(&ws);
}

#[test]
fn watchdog_kills_runaway_under_sandbox() {
    let caps = SandboxCapabilities::probe();
    let ws = std::env::temp_dir().join(format!("jeryu-launch-killer-{}", std::process::id()));
    std::fs::create_dir_all(&ws).unwrap_or_else(|e| panic!("workspace: {e}"));

    // sleep 30 must be killed by a 300ms watchdog after sandbox application.
    let j = job(ws.clone(), "/bin/sleep", vec!["30".into()]);
    let decision = select_runner(&j).unwrap_or_else(|e| panic!("{e}"));
    let plan = SandboxPlan::from_decision(&j.workspace, &decision);

    let child = spawn_sandboxed(&j, &plan, &caps, &sandbox_env())
        .unwrap_or_else(|e| panic!("spawn_sandboxed: {e}"));
    let out = run_with_watchdog(child, Duration::from_millis(300))
        .unwrap_or_else(|e| panic!("watchdog: {e}"));
    assert!(out.timed_out, "runaway must be killed by the watchdog");
    assert!(out.elapsed < Duration::from_secs(5));

    let _ = std::fs::remove_dir_all(&ws);
}

fn cgroup_test_capabilities(parent: std::path::PathBuf) -> SandboxCapabilities {
    // This fixture selects only cgroup and no_new_privs. The launch performs
    // their real syscalls; the other primitives are explicitly not qualified
    // by the two cgroup lifecycle cases below.
    SandboxCapabilities {
        user_namespace: false,
        mount_namespace: false,
        pid_namespace: false,
        landlock_abi: None,
        seccomp_bpf: false,
        cgroup_v2_subtree: Some(parent),
        no_new_privs: true,
    }
}

#[test]
fn raw_launch_refuses_supplied_fake_cgroups_for_both_policies() {
    for strict in [false, true] {
        let ws = tempfile::tempdir().unwrap();
        let parent = tempfile::tempdir().unwrap();
        let control = parent.path().join("cgroup.subtree_control");
        std::fs::write(&control, b"memory pids\n").unwrap();
        let request = job(
            ws.path().to_owned(),
            "/bin/sh",
            vec!["-c".into(), "touch executed".into()],
        );
        let decision = select_runner(&request).unwrap();
        let mut plan = SandboxPlan::from_decision(&request.workspace, &decision);
        plan.require_cgroup = strict;
        let error = spawn_sandboxed(
            &request,
            &plan,
            &cgroup_test_capabilities(parent.path().to_owned()),
            &sandbox_env(),
        )
        .expect_err("supplied capabilities cannot admit an ordinary filesystem");
        assert_eq!(error.code(), "cgroup_parent_unavailable");
        assert!(!ws.path().join("executed").exists());
        assert_eq!(std::fs::read(control).unwrap(), b"memory pids\n");
        assert_eq!(std::fs::read_dir(parent.path()).unwrap().count(), 1);
    }
}

#[test]
fn owned_launch_refuses_fake_cgroup_before_executing_job() {
    use jeryu_sandbox_linux::launch::spawn_sandboxed_owned;
    let ws = tempfile::tempdir().unwrap();
    let parent = tempfile::tempdir().unwrap();
    let j = job(
        ws.path().to_owned(),
        "/bin/sh",
        vec!["-c".into(), "touch executed".into()],
    );
    let decision = select_runner(&j).unwrap();
    let plan = SandboxPlan::from_decision(&j.workspace, &decision);
    let result = spawn_sandboxed_owned(
        &j,
        &plan,
        &cgroup_test_capabilities(parent.path().to_owned()),
        &sandbox_env(),
    );
    let error = result
        .err()
        .expect("ordinary files cannot provide cgroup custody");
    assert_eq!(error.code(), "cgroup_control_failed");
    assert!(!ws.path().join("executed").exists());
    assert_eq!(std::fs::read_dir(parent.path()).unwrap().count(), 0);
}

#[test]
#[ignore = "requires an allocated, exclusive delegated JERYU_TEST_CGROUP_PARENT; not ordinary-host qualification"]
fn owned_cgroup_kills_escaped_groups_and_removes_only_its_leaf() {
    use jeryu_sandbox_linux::launch::spawn_sandboxed_owned;
    use jeryu_sandbox_linux::watchdog::{
        TerminationScope, WatchdogOptions, run_owned_with_watchdog,
    };
    let parent = std::path::PathBuf::from(
        std::env::var_os("JERYU_TEST_CGROUP_PARENT")
            .expect("explicit delegated test parent required"),
    );
    assert!(parent.is_absolute());
    assert!(
        !std::fs::symlink_metadata(&parent)
            .unwrap()
            .file_type()
            .is_symlink()
    );
    for cancel in [false, true] {
        let ws = tempfile::tempdir().unwrap();
        let j = job(
            ws.path().to_owned(),
            "/bin/sh",
            vec![
                "-c".into(),
                "/usr/bin/setsid /bin/sh -c 'echo escaped:$$; exec /bin/sleep 30' & /bin/sleep 30"
                    .into(),
            ],
        );
        let decision = select_runner(&j).unwrap();
        let mut plan = SandboxPlan::from_decision(&j.workspace, &decision);
        plan.require_cgroup = true;
        let child = spawn_sandboxed_owned(
            &j,
            &plan,
            &cgroup_test_capabilities(parent.clone()),
            &sandbox_env(),
        )
        .unwrap();
        // Do not assert between launch and cleanup: even an observation failure
        // must reach the watchdog and stop this test's owned processes.
        let membership = std::fs::read_to_string(format!("/proc/{}/cgroup", child.id()));
        let options = WatchdogOptions::default();
        let token = options.cancellation.clone();
        let canceller = cancel.then(|| {
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(200));
                token.cancel();
            })
        });
        let timeout = if cancel {
            Duration::from_secs(10)
        } else {
            Duration::from_millis(200)
        };
        let result = run_owned_with_watchdog(child, timeout, options);
        if let Some(canceller) = canceller {
            canceller.join().unwrap();
        }
        let out = result.unwrap();
        let membership = membership.unwrap();
        let relative = membership
            .lines()
            .find_map(|line| line.strip_prefix("0::"))
            .unwrap();
        let leaf = std::path::Path::new("/sys/fs/cgroup").join(relative.trim_start_matches('/'));
        assert_eq!(leaf.parent(), Some(parent.as_path()));
        assert!(
            leaf.file_name()
                .unwrap()
                .as_encoded_bytes()
                .starts_with(b"jeryu-job-")
        );
        assert_eq!(out.termination_scope, TerminationScope::OwnedCgroup);
        assert_eq!(out.cancelled, cancel);
        assert_eq!(out.timed_out, !cancel);
        let output = std::str::from_utf8(&out.stdout).unwrap();
        let escaped = output
            .lines()
            .find_map(|line| line.strip_prefix("escaped:"))
            .expect("escaped-group child actually executed");
        let escaped: u32 = escaped.parse().unwrap();
        match std::fs::read(format!("/proc/{escaped}/stat")) {
            Ok(stat) => {
                let end = stat.iter().rposition(|b| *b == b')').unwrap();
                assert!(
                    matches!(stat[end + 2], b'Z' | b'X'),
                    "escaped group still executes"
                );
            }
            Err(error) => assert_eq!(error.kind(), std::io::ErrorKind::NotFound),
        }
        assert!(!leaf.exists(), "owned cgroup must be empty and removed");
        assert!(parent.is_dir(), "delegated parent must remain");
    }
}
