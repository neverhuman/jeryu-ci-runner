//! Negative proof for the untrusted-workload posture: an untrusted launch must
//! REFUSE when any of the four kernel controls — `no_new_privs`, cgroup-v2
//! limits, Landlock, seccomp — cannot be applied. No degraded success, no
//! silent fallback, and the job command must never run.
//!
//! Each case simulates one missing control through a fabricated
//! [`SandboxCapabilities`] (the probe reports the host; these tests report the
//! hosts we must refuse) and drives the real `spawn_sandboxed` path. The proof
//! that nothing ran is a sentinel file the command would have created.

use jeryu_runner_core::job::{JobRequest, NetworkPolicy, SecretPolicy, TokenPolicy};
use jeryu_runner_core::policy::select_runner;
use jeryu_runner_core::sandbox::SandboxPlan;
use jeryu_runner_core::trust::TrustTier;
use jeryu_sandbox_linux::capability::{EnforcementLevel, SandboxCapabilities};
use jeryu_sandbox_linux::launch::spawn_sandboxed;
use std::collections::BTreeMap;
use std::path::PathBuf;

fn workspace(tag: &str) -> PathBuf {
    jeryu_test_support::unique_temp_dir(&format!("jeryu-untrusted-{tag}"))
}

fn sandbox_env() -> BTreeMap<String, String> {
    let mut env = BTreeMap::new();
    env.insert("PATH".into(), "/usr/local/bin:/usr/bin:/bin".into());
    env.insert("HOME".into(), "/tmp".into());
    env
}

/// A job whose command leaves a sentinel behind, so an unwanted launch is
/// visible rather than inferred.
fn sentinel_job(ws: PathBuf) -> JobRequest {
    JobRequest {
        job_id: "untrusted".into(),
        repo_id: "repo".into(),
        commit_sha: "abc".into(),
        workspace: ws,
        command: "/bin/sh".into(),
        args: vec!["-c".into(), "touch executed".into()],
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

/// Capabilities naming a host where every control is available. Each case below
/// removes exactly one; the cgroup subtree is a plain directory, which the
/// launch path itself also refuses — the cases that keep it assert the refusal
/// came from the missing control instead.
fn all_controls(cgroup_parent: PathBuf) -> SandboxCapabilities {
    SandboxCapabilities {
        user_namespace: false,
        mount_namespace: false,
        pid_namespace: false,
        landlock_abi: Some(4),
        seccomp_bpf: true,
        cgroup_v2_subtree: Some(cgroup_parent),
        no_new_privs: true,
    }
}

fn untrusted_plan(job: &JobRequest) -> SandboxPlan {
    let decision = select_runner(job).unwrap_or_else(|e| panic!("{e}"));
    SandboxPlan::from_decision(&job.workspace, &decision).with_untrusted_workload(true)
}

/// Run one missing-control case: the resolver must say `Unavailable` naming the
/// control, the spawn must fail with `sandbox_unavailable`, and no command runs.
fn refuses_without(tag: &str, named: &str, strip: impl FnOnce(&mut SandboxCapabilities)) {
    let ws = workspace(tag);
    let parent = workspace(&format!("{tag}-cgroup"));
    let job = sentinel_job(ws.clone());
    let plan = untrusted_plan(&job);

    let mut caps = all_controls(parent.clone());
    strip(&mut caps);

    match caps.enforcement_level(&plan) {
        EnforcementLevel::Unavailable { reason } => assert!(
            reason.contains(named),
            "refusal should name {named}, got {reason:?}"
        ),
        other => panic!("untrusted launch must fail closed without {named}, got {other:?}"),
    }

    let err = spawn_sandboxed(&job, &plan, &caps, &sandbox_env())
        .err()
        .unwrap_or_else(|| panic!("untrusted launch must be refused without {named}"));
    assert_eq!(err.code(), "sandbox_unavailable", "{}", err.message());
    assert!(
        !ws.join("executed").exists(),
        "untrusted command ran without {named}"
    );

    let _ = std::fs::remove_dir_all(&ws);
    let _ = std::fs::remove_dir_all(&parent);
}

#[test]
fn untrusted_launch_refuses_without_no_new_privs() {
    refuses_without("nnp", "NO_NEW_PRIVS", |caps| caps.no_new_privs = false);
}

#[test]
fn untrusted_launch_refuses_without_cgroup() {
    refuses_without("cgroup", "cgroup_v2", |caps| caps.cgroup_v2_subtree = None);
}

#[test]
fn untrusted_launch_refuses_without_landlock() {
    refuses_without("landlock", "landlock", |caps| caps.landlock_abi = None);
}

#[test]
fn untrusted_launch_refuses_without_seccomp() {
    refuses_without("seccomp", "seccomp", |caps| caps.seccomp_bpf = false);
}

#[test]
fn untrusted_launch_refuses_a_plan_carrying_no_landlock_rules() {
    let ws = workspace("norules");
    let parent = workspace("norules-cgroup");
    let job = sentinel_job(ws.clone());
    let mut plan = untrusted_plan(&job);
    plan.landlock_rules.clear();

    let err = spawn_sandboxed(&job, &plan, &all_controls(parent.clone()), &sandbox_env())
        .err()
        .expect("an untrusted launch without landlock rules confines nothing");
    assert_eq!(err.code(), "sandbox_unavailable", "{}", err.message());
    assert!(!ws.join("executed").exists());

    let _ = std::fs::remove_dir_all(&ws);
    let _ = std::fs::remove_dir_all(&parent);
}

/// The host's own posture: whatever this machine supplies, an untrusted launch
/// either runs with all four controls or does not run at all. On the common
/// no-delegation host this is the real refusal, not a simulated one.
#[test]
fn untrusted_launch_on_this_host_is_all_four_or_refused() {
    let caps = SandboxCapabilities::probe();
    eprintln!("UNTRUSTED caps: {}", caps.summary());

    let ws = workspace("host");
    let job = sentinel_job(ws.clone());
    let plan = untrusted_plan(&job);

    let complete = caps.no_new_privs
        && caps.cgroup_v2_subtree.is_some()
        && caps.landlock_abi.is_some()
        && caps.seccomp_bpf;
    match caps.enforcement_level(&plan) {
        EnforcementLevel::Unavailable { reason } => {
            assert!(
                !complete,
                "all four controls are present, so the launch must not be refused"
            );
            for named in ["NO_NEW_PRIVS", "cgroup_v2", "landlock", "seccomp"] {
                let present = match named {
                    "NO_NEW_PRIVS" => caps.no_new_privs,
                    "cgroup_v2" => caps.cgroup_v2_subtree.is_some(),
                    "landlock" => caps.landlock_abi.is_some(),
                    _ => caps.seccomp_bpf,
                };
                assert!(
                    present || reason.contains(named),
                    "the refusal must name the missing {named}: {reason}"
                );
            }
            let err = spawn_sandboxed(&job, &plan, &caps, &sandbox_env())
                .err()
                .expect("refused launch");
            assert_eq!(err.code(), "sandbox_unavailable", "{}", err.message());
            assert!(
                !ws.join("executed").exists(),
                "untrusted command ran anyway"
            );
        }
        // A launch that proceeds must have every one of the four. Namespaces are
        // the only degradable primitives left, and they are out of this contract.
        level => {
            assert!(
                complete,
                "an untrusted plan may only launch with all four controls: {}",
                caps.summary()
            );
            if let EnforcementLevel::Degraded { missing } = &level {
                for named in ["cgroup_v2", "landlock", "seccomp"] {
                    assert!(
                        !missing.contains(&named.to_string()),
                        "{named} must never be a degraded-skip for untrusted code: {missing:?}"
                    );
                }
            }
        }
    }

    let _ = std::fs::remove_dir_all(&ws);
}
