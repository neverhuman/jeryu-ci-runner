use super::*;
use jeryu_runner_core::job::NetworkPolicy;
use jeryu_runner_core::policy::{CacheWritePolicy, PolicyDecision};
use jeryu_runner_core::trust::RunnerClass;

fn plan() -> SandboxPlan {
    let decision = PolicyDecision {
        runner_class: RunnerClass::NativeRustClean,
        network_policy: NetworkPolicy::Deny,
        allow_secrets: false,
        token_policy: jeryu_runner_core::job::TokenPolicy::ReadOnly,
        cache_write_policy: CacheWritePolicy::Deny,
        reasons: vec!["test".to_string()],
    };
    SandboxPlan::from_decision("/tmp/jeryu-cap-test", &decision)
}

/// A plan that REQUIRES enforced cgroups (agent-job posture).
fn strict_plan() -> SandboxPlan {
    plan().with_require_cgroup(true)
}

#[test]
fn probe_is_self_consistent() {
    let caps = SandboxCapabilities::probe();
    // no_new_privs is the only primitive we *require* to exist on a sane
    // Linux box; everything else is host-dependent and may be false here.
    // We do not assert it true (CI may differ) but the summary must render.
    let _ = caps.summary();
    // Landlock ABI, when present, must be a positive version.
    if let Some(abi) = caps.landlock_abi {
        assert!(abi >= 1, "landlock abi must be >= 1 when reported");
    }
}

#[test]
fn missing_no_new_privs_is_unavailable() {
    let caps = SandboxCapabilities {
        user_namespace: false,
        mount_namespace: false,
        pid_namespace: false,
        landlock_abi: Some(4),
        seccomp_bpf: true,
        cgroup_v2_subtree: Some(PathBuf::from("/sys/fs/cgroup/x")),
        no_new_privs: false,
    };
    assert!(matches!(
        caps.enforcement_level(&plan()),
        EnforcementLevel::Unavailable { .. }
    ));
}

#[test]
fn all_primitives_present_is_enforced() {
    let caps = SandboxCapabilities {
        user_namespace: true,
        mount_namespace: true,
        pid_namespace: true,
        landlock_abi: Some(4),
        seccomp_bpf: true,
        cgroup_v2_subtree: Some(PathBuf::from("/sys/fs/cgroup/x")),
        no_new_privs: true,
    };
    assert_eq!(caps.enforcement_level(&plan()), EnforcementLevel::Enforced);
}

#[test]
fn require_cgroup_without_subtree_is_unavailable_fail_closed() {
    // THIS host's posture: no delegated cgroup subtree, but landlock/seccomp
    // present and no_new_privs available. A require_cgroup plan MUST fail
    // closed (Unavailable), never degrade.
    let caps = SandboxCapabilities {
        user_namespace: false,
        mount_namespace: false,
        pid_namespace: false,
        landlock_abi: Some(4),
        seccomp_bpf: true,
        cgroup_v2_subtree: None,
        no_new_privs: true,
    };
    match caps.enforcement_level(&strict_plan()) {
        EnforcementLevel::Unavailable { reason } => {
            assert!(
                reason.contains("cgroup"),
                "reason should name cgroups, got {reason:?}"
            );
        }
        other => panic!("require_cgroup must fail closed, got {other:?}"),
    }
    // A non-require_cgroup plan on the SAME caps must only DEGRADE (cgroup_v2
    // named missing), proving the gate is opt-in and does not break CI jobs.
    match caps.enforcement_level(&plan()) {
        EnforcementLevel::Degraded { missing } => {
            assert!(missing.contains(&"cgroup_v2".to_string()));
        }
        other => panic!("non-require plan must degrade, got {other:?}"),
    }
}

#[test]
fn require_cgroup_with_subtree_is_enforced() {
    // When a delegated subtree DOES exist, a require_cgroup plan enforces.
    let caps = SandboxCapabilities {
        user_namespace: true,
        mount_namespace: true,
        pid_namespace: true,
        landlock_abi: Some(4),
        seccomp_bpf: true,
        cgroup_v2_subtree: Some(PathBuf::from("/sys/fs/cgroup/x")),
        no_new_privs: true,
    };
    assert_eq!(
        caps.enforcement_level(&strict_plan()),
        EnforcementLevel::Enforced
    );
}

#[test]
fn blocked_userns_degrades_with_named_missing() {
    // Mirrors THIS host: no userns, but landlock/seccomp/cgroup present.
    let caps = SandboxCapabilities {
        user_namespace: false,
        mount_namespace: false,
        pid_namespace: false,
        landlock_abi: Some(4),
        seccomp_bpf: true,
        cgroup_v2_subtree: Some(PathBuf::from("/sys/fs/cgroup/x")),
        no_new_privs: true,
    };
    match caps.enforcement_level(&plan()) {
        EnforcementLevel::Degraded { missing } => {
            assert!(missing.contains(&"user_namespace".to_string()));
            assert!(missing.contains(&"mount_namespace".to_string()));
            assert!(missing.contains(&"pid_namespace".to_string()));
            assert!(!missing.contains(&"landlock".to_string()));
            assert!(!missing.contains(&"seccomp".to_string()));
            assert!(!missing.contains(&"cgroup_v2".to_string()));
        }
        other => panic!("expected degraded, got {other:?}"),
    }
}

#[test]
fn cgroup_probe_rejects_fake_control_directory_without_creating_leaf() {
    let parent = tempfile::tempdir().unwrap();
    std::fs::create_dir(parent.path().join("cgroup.subtree_control")).unwrap();
    assert!(!cgroup_subtree_is_enforceable(parent.path()));
    assert_eq!(std::fs::read_dir(parent.path()).unwrap().count(), 1);
}

#[test]
fn cgroup_probe_rejects_regular_control_files_without_mutation() {
    let parent = tempfile::tempdir().unwrap();
    let control = parent.path().join("cgroup.subtree_control");
    // Even caller-supplied bare names cannot make an ordinary filesystem a
    // valid delegated cgroup. Actual enable/readback semantics have separate
    // failure tests in cgroup_fs.
    std::fs::write(&control, b"memory pids\n").unwrap();
    assert!(!cgroup_subtree_is_enforceable(parent.path()));
    assert_eq!(std::fs::read(&control).unwrap(), b"memory pids\n");
    assert_eq!(std::fs::read_dir(parent.path()).unwrap().count(), 1);
}

#[test]
fn colliding_probe_name_preserves_existing_directory_and_bytes() {
    let parent = tempfile::tempdir().unwrap();
    let path = parent.path().join("existing.scope");
    std::fs::create_dir(&path).unwrap();
    std::fs::write(path.join("owner"), b"another probe").unwrap();
    let parent_fd = std::fs::File::open(parent.path()).unwrap();
    assert!(create_probe_directory(&parent_fd, c"existing.scope").is_err());
    assert_eq!(std::fs::read(path.join("owner")).unwrap(), b"another probe");
}

#[test]
fn simultaneous_probe_directories_have_distinct_owned_identities() {
    use crate::cgroup_fs::{remove_exact, unique_leaf_name};
    use std::collections::BTreeSet;

    let root = tempfile::tempdir().unwrap();
    let parent = std::fs::File::open(root.path()).unwrap();
    let previous = root
        .path()
        .join(format!("jeryu-cap-probe-{}.scope", std::process::id()));
    std::fs::create_dir(&previous).unwrap();
    let barrier = std::sync::Barrier::new(8);
    let leaves = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..8)
            .map(|_| {
                scope.spawn(|| {
                    let name = unique_leaf_name("jeryu-cap-probe").unwrap();
                    let leaf = create_probe_directory(&parent, &name);
                    barrier.wait();
                    (name, leaf.unwrap())
                })
            })
            .collect();
        handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .collect::<Vec<_>>()
    });
    let names: BTreeSet<_> = leaves.iter().map(|(name, _)| name.to_bytes()).collect();
    assert_eq!(names.len(), 8);
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 9);
    for (name, leaf) in leaves {
        remove_exact(&parent, &leaf, &name).unwrap();
    }
    assert!(previous.is_dir());
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 1);
}

#[test]
#[ignore = "requires an explicitly allocated delegated cgroup parent"]
fn delegated_cgroup_probe_checks_topology_and_concurrent_ownership() {
    let parent = PathBuf::from(
        std::env::var_os("JERYU_TEST_CGROUP_PARENT")
            .expect("an explicitly delegated test parent is required"),
    );
    let current = PathBuf::from("/sys/fs/cgroup").join(
        current_cgroup_rel()
            .expect("cgroup v2 membership")
            .trim_start_matches('/'),
    );
    assert!(current.starts_with(&parent) && current != parent);
    crate::cgroup_fs::open_parent(&parent).expect("real delegated cgroup v2 parent");
    let entries = |path: &std::path::Path| {
        std::fs::read_dir(path)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect::<std::collections::BTreeSet<_>>()
    };
    let before = entries(&parent);
    std::thread::scope(|scope| {
        let a = scope.spawn(|| cgroup_subtree_is_enforceable(&parent));
        let b = scope.spawn(|| cgroup_subtree_is_enforceable(&parent));
        assert!(a.join().unwrap());
        assert!(b.join().unwrap());
    });
    assert_eq!(entries(&parent), before, "probe leaves must be removed");

    // The allocated supervisor child contains this process. It cannot enable
    // the domain memory controller for children while retaining its processes.
    let control = current.join("cgroup.subtree_control");
    let before_control = std::fs::read(&control).unwrap();
    let before_entries = entries(&current);
    assert!(!cgroup_subtree_is_enforceable(&current));
    assert_eq!(std::fs::read(control).unwrap(), before_control);
    assert_eq!(entries(&current), before_entries);
}
