//! Integration tests for the typed CI IR (`jeryu-ci-ir`).
//!
//! Coverage focus:
//!   * DETERMINISM: identical `Pipeline`s yield identical IR hashes regardless
//!     of the insertion order of jobs / edges / cache mounts / artifacts.
//!   * Job / Dependency DAG validity + cycle rejection.
//!   * `TrustTier` ordering / parsing / selection.
//!   * `RunnerClass` string mapping + parsing.
//!   * Round-trip stability of the IR through its canonical serialization
//!     (the crate's own stable on-the-wire form; see note in
//!     `canonical_serialization_round_trip_is_stable`).
//!   * Policy fields (cache / artifact / permission / secret / proof / signing)
//!     are preserved into the canonical IR + hash.

use std::collections::BTreeMap;

use jeryu_ci_ir::{
    ArtifactPath, ArtifactPolicy, ArtifactWhen, CacheMode, CacheMount, CachePolicy, Dependency,
    EnvMap, Job, NetworkPolicy, PermissionPolicy, Pipeline, PipelineSource, ProofPolicy,
    RetryPolicy, RunnerClass, SecretPolicy, SigningPolicy, Step, TokenScope, TrustTier,
    ValidationError, deterministic_hash, sanitize_id, stable_id, trim_quotes,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A representative two-job pipeline: `fmt -> test`.
fn sample_pipeline() -> Pipeline {
    let mut pipeline = Pipeline::new(
        PipelineSource::NativeToml,
        "acme/demo",
        "abc123",
        TrustTier::InternalBranch,
    );
    let mut fmt = Job::new("fmt", "fmt", RunnerClass::NativeRustClean);
    fmt.steps
        .push(Step::run("fmt_0", "fmt", "cargo fmt --check"));
    let mut test = Job::new("test", "test", RunnerClass::NativeRustClean);
    test.steps.push(Step::run("test_0", "test", "cargo test"));
    pipeline.jobs.push(fmt);
    pipeline.jobs.push(test);
    pipeline.edges.push(Dependency {
        from: "fmt".to_string(),
        to: "test".to_string(),
    });
    pipeline
}

/// A richer pipeline exercising every policy + per-job field so canonical
/// rendering is broadly covered.
fn rich_pipeline() -> Pipeline {
    let mut pipeline = Pipeline::new(
        PipelineSource::GitHubActions,
        "octo/forge",
        "deadbeefcafe",
        TrustTier::ReleaseHermetic,
    );

    let mut build = Job::new("build", "Build", RunnerClass::ReleaseHermetic);
    build.timeout_seconds = 1800;
    build.retry_policy = RetryPolicy {
        max_attempts: 3,
        backoff_seconds: 30,
    };
    build.network_policy = NetworkPolicy::Allowlist(vec![
        "registry.internal".to_string(),
        "crates.io".to_string(),
    ]);
    build.token_scope = TokenScope::WriteChecks;
    build
        .inputs
        .insert("profile".to_string(), "release".to_string());
    build
        .outputs
        .insert("artifact".to_string(), "bin/forge".to_string());
    build.cache_mounts.push(CacheMount {
        name: "cargo-registry".to_string(),
        path: "/root/.cargo/registry".to_string(),
        mode: CacheMode::ReadWriteTrusted,
        fingerprint: "fp-001".to_string(),
    });
    build.artifact_paths.push(ArtifactPath {
        name: "binaries".to_string(),
        paths: vec!["target/release/forge".to_string()],
        when: ArtifactWhen::OnSuccess,
        retention_days: 30,
    });
    let mut step = Step::run("build_0", "compile", "cargo build --release");
    let mut env = EnvMap::new();
    env.insert("RUSTFLAGS".to_string(), "-D warnings".to_string());
    step.env = env;
    step.working_directory = Some("workspace".to_string());
    build.steps.push(step);
    build
        .steps
        .push(Step::uses("build_1", "checkout", "actions/checkout@v4"));

    let mut sign = Job::new("sign", "Sign", RunnerClass::ReleaseHermetic);
    sign.token_scope = TokenScope::Custom(vec!["id-token:write".to_string()]);
    sign.steps.push(Step::run("sign_0", "sign", "cosign sign"));

    pipeline.jobs.push(build);
    pipeline.jobs.push(sign);
    pipeline.edges.push(Dependency {
        from: "build".to_string(),
        to: "sign".to_string(),
    });

    // Non-default policies to prove preservation.
    pipeline.proof_policy = ProofPolicy {
        proof_required: true,
        lane: "release-strict".to_string(),
    };
    pipeline.signing_policy = SigningPolicy {
        provenance_required: true,
        release_only: true,
    };
    pipeline.secret_policy = SecretPolicy {
        secrets_available: true,
        deny_on_fork: true,
    };
    pipeline
}

// ---------------------------------------------------------------------------
// DETERMINISM — the spec's "deterministic IR hash" gate
// ---------------------------------------------------------------------------

#[test]
fn identical_pipelines_have_identical_hash_and_canonical() {
    let a = sample_pipeline();
    let b = sample_pipeline();
    assert_eq!(a.canonical(), b.canonical());
    assert_eq!(a.ir_hash(), b.ir_hash());
}

#[test]
fn hash_is_stable_across_many_runs() {
    let pipeline = rich_pipeline();
    let first = pipeline.ir_hash();
    for _ in 0..256 {
        assert_eq!(pipeline.ir_hash(), first);
    }
}

#[test]
fn job_insertion_order_does_not_affect_hash() {
    // Same logical pipeline, jobs pushed in opposite orders.
    let mut a = Pipeline::new(
        PipelineSource::NativeToml,
        "acme/demo",
        "abc123",
        TrustTier::InternalBranch,
    );
    let mut b = Pipeline::new(
        PipelineSource::NativeToml,
        "acme/demo",
        "abc123",
        TrustTier::InternalBranch,
    );

    let mut j1 = Job::new("alpha", "Alpha", RunnerClass::NativeRustClean);
    j1.steps.push(Step::run("a0", "a", "echo a"));
    let mut j2 = Job::new("beta", "Beta", RunnerClass::NativeRustClean);
    j2.steps.push(Step::run("b0", "b", "echo b"));

    a.jobs.push(j1.clone());
    a.jobs.push(j2.clone());
    b.jobs.push(j2);
    b.jobs.push(j1);

    assert_eq!(a.canonical(), b.canonical());
    assert_eq!(a.ir_hash(), b.ir_hash());
}

#[test]
fn edge_insertion_order_does_not_affect_hash() {
    let build = |edges: Vec<(&str, &str)>| {
        let mut p = Pipeline::new(
            PipelineSource::NativeToml,
            "acme/demo",
            "abc123",
            TrustTier::InternalBranch,
        );
        for id in ["a", "b", "c"] {
            let mut job = Job::new(id, id, RunnerClass::NativeRustClean);
            job.steps.push(Step::run(format!("{id}0"), id, "echo x"));
            p.jobs.push(job);
        }
        for (from, to) in edges {
            p.edges.push(Dependency {
                from: from.to_string(),
                to: to.to_string(),
            });
        }
        p
    };

    let forward = build(vec![("a", "b"), ("b", "c"), ("a", "c")]);
    let shuffled = build(vec![("a", "c"), ("b", "c"), ("a", "b")]);
    assert_eq!(forward.canonical(), shuffled.canonical());
    assert_eq!(forward.ir_hash(), shuffled.ir_hash());
}

#[test]
fn cache_mount_order_does_not_affect_hash() {
    let mk = |mounts: Vec<&str>| {
        let mut p = sample_pipeline();
        let job = &mut p.jobs[0];
        for name in mounts {
            job.cache_mounts.push(CacheMount {
                name: name.to_string(),
                path: format!("/cache/{name}"),
                mode: CacheMode::ReadOnly,
                fingerprint: format!("fp-{name}"),
            });
        }
        p
    };
    let a = mk(vec!["zeta", "alpha", "mid"]);
    let b = mk(vec!["alpha", "mid", "zeta"]);
    assert_eq!(a.canonical(), b.canonical());
    assert_eq!(a.ir_hash(), b.ir_hash());
}

#[test]
fn artifact_order_does_not_affect_hash() {
    let mk = |artifacts: Vec<&str>| {
        let mut p = sample_pipeline();
        let job = &mut p.jobs[0];
        for name in artifacts {
            job.artifact_paths.push(ArtifactPath {
                name: name.to_string(),
                paths: vec![format!("out/{name}")],
                when: ArtifactWhen::Always,
                retention_days: 7,
            });
        }
        p
    };
    let a = mk(vec!["z-logs", "a-bin", "m-cov"]);
    let b = mk(vec!["a-bin", "m-cov", "z-logs"]);
    assert_eq!(a.canonical(), b.canonical());
    assert_eq!(a.ir_hash(), b.ir_hash());
}

#[test]
fn distinct_pipelines_produce_distinct_hashes() {
    let base = sample_pipeline();
    let mut changed = sample_pipeline();
    changed.commit = "different".to_string();
    assert_ne!(base.ir_hash(), changed.ir_hash());
}

#[test]
fn changing_any_policy_changes_the_hash() {
    let base = sample_pipeline();
    let base_hash = base.ir_hash();

    let mut p = sample_pipeline();
    p.jeryu_cache_policy.allow_cross_project_compiled = true;
    assert_ne!(base_hash, p.ir_hash(), "cache policy must affect hash");

    let mut p = sample_pipeline();
    p.artifact_policy.default_retention_days = 99;
    assert_ne!(base_hash, p.ir_hash(), "artifact policy must affect hash");

    let mut p = sample_pipeline();
    p.permission_policy.fail_closed = false;
    assert_ne!(base_hash, p.ir_hash(), "permission policy must affect hash");

    let mut p = sample_pipeline();
    p.secret_policy.secrets_available = true;
    assert_ne!(base_hash, p.ir_hash(), "secret policy must affect hash");

    let mut p = sample_pipeline();
    p.proof_policy.proof_required = false;
    assert_ne!(base_hash, p.ir_hash(), "proof policy must affect hash");

    let mut p = sample_pipeline();
    p.signing_policy.provenance_required = true;
    assert_ne!(base_hash, p.ir_hash(), "signing policy must affect hash");
}

#[test]
fn deterministic_hash_has_expected_prefix_and_width() {
    let h = deterministic_hash("anything");
    assert!(h.starts_with("fnv64:"), "hash prefix: {h}");
    let hex = h.trim_start_matches("fnv64:");
    assert_eq!(hex.len(), 16, "expected 16 hex digits, got {hex}");
    assert!(hex.chars().all(|c| c.is_ascii_hexdigit()));
}

#[test]
fn deterministic_hash_is_pure() {
    assert_eq!(deterministic_hash("forge"), deterministic_hash("forge"));
    assert_ne!(deterministic_hash("forge"), deterministic_hash("Forge"));
    assert_ne!(deterministic_hash("ab"), deterministic_hash("ba"));
}

#[test]
fn pipeline_id_is_derived_deterministically_from_identity() {
    let a = Pipeline::new(
        PipelineSource::Api,
        "octo/forge",
        "c0ffee",
        TrustTier::ForkPr,
    );
    let b = Pipeline::new(
        PipelineSource::Api,
        "octo/forge",
        "c0ffee",
        TrustTier::PublicUntrusted,
    );
    // id depends on source/repo/commit, not on trust tier.
    assert_eq!(a.id, b.id);
    let c = Pipeline::new(
        PipelineSource::Agent,
        "octo/forge",
        "c0ffee",
        TrustTier::ForkPr,
    );
    assert_ne!(a.id, c.id, "different source must change derived id");
}

// ---------------------------------------------------------------------------
// Job / Dependency DAG validity + cycle rejection
// ---------------------------------------------------------------------------

#[test]
fn valid_dag_passes_validation() {
    assert_eq!(sample_pipeline().validate(), Ok(()));
    assert_eq!(rich_pipeline().validate(), Ok(()));
}

#[test]
fn empty_repo_is_rejected() {
    let mut p = sample_pipeline();
    p.repo = "   ".to_string();
    assert_eq!(p.validate(), Err(ValidationError::EmptyRepo));
}

#[test]
fn empty_commit_is_rejected() {
    let mut p = sample_pipeline();
    p.commit = String::new();
    assert_eq!(p.validate(), Err(ValidationError::EmptyCommit));
}

#[test]
fn empty_job_id_is_rejected() {
    let mut p = sample_pipeline();
    let mut bad = Job::new("", "ghost", RunnerClass::NativeRustClean);
    bad.steps.push(Step::run("g0", "g", "echo"));
    p.jobs.push(bad);
    assert_eq!(p.validate(), Err(ValidationError::EmptyJobId));
}

#[test]
fn duplicate_job_id_is_rejected() {
    let mut p = sample_pipeline();
    let mut dup = Job::new("fmt", "fmt-again", RunnerClass::NativeRustClean);
    dup.steps.push(Step::run("d0", "d", "echo"));
    p.jobs.push(dup);
    assert_eq!(
        p.validate(),
        Err(ValidationError::DuplicateJob("fmt".to_string()))
    );
}

#[test]
fn job_without_steps_is_rejected() {
    let mut p = sample_pipeline();
    p.jobs
        .push(Job::new("empty", "empty", RunnerClass::NativeRustClean));
    assert_eq!(
        p.validate(),
        Err(ValidationError::JobHasNoSteps("empty".to_string()))
    );
}

#[test]
fn edge_to_unknown_job_is_rejected() {
    let mut p = sample_pipeline();
    p.edges.push(Dependency {
        from: "fmt".to_string(),
        to: "ghost".to_string(),
    });
    assert_eq!(
        p.validate(),
        Err(ValidationError::UnknownEdgeEndpoint("ghost".to_string()))
    );
}

#[test]
fn edge_from_unknown_job_is_rejected() {
    let mut p = sample_pipeline();
    p.edges.push(Dependency {
        from: "ghost".to_string(),
        to: "fmt".to_string(),
    });
    assert_eq!(
        p.validate(),
        Err(ValidationError::UnknownEdgeEndpoint("ghost".to_string()))
    );
}

#[test]
fn self_dependency_is_rejected() {
    let mut p = sample_pipeline();
    p.edges.push(Dependency {
        from: "fmt".to_string(),
        to: "fmt".to_string(),
    });
    assert_eq!(
        p.validate(),
        Err(ValidationError::SelfDependency("fmt".to_string()))
    );
}

/// Independent Kahn's-algorithm topological sort over the IR's `(jobs, edges)`,
/// treating `from -> to` as "from runs before to". Returns `Err(())` when the
/// dependency graph contains a cycle. This lives in the test crate because the
/// IR's own cycle check (`validate_rejects_multi_node_cycles`) is cross-checked
/// against it.
fn topological_order(p: &Pipeline) -> Result<Vec<String>, ()> {
    let ids: Vec<String> = p.jobs.iter().map(|j| j.id.clone()).collect();
    let mut indegree: BTreeMap<String, usize> =
        ids.iter().cloned().map(|id| (id, 0usize)).collect();
    let mut adj: BTreeMap<String, Vec<String>> =
        ids.iter().cloned().map(|id| (id, Vec::new())).collect();

    for e in &p.edges {
        adj.get_mut(&e.from).unwrap().push(e.to.clone());
        *indegree.get_mut(&e.to).unwrap() += 1;
    }

    // Seed with all zero-indegree nodes (BTreeMap keeps this deterministic).
    let mut queue: Vec<String> = indegree
        .iter()
        .filter(|&(_, &d)| d == 0)
        .map(|(id, _)| id.clone())
        .collect();
    let mut order = Vec::new();
    while let Some(node) = queue.pop() {
        order.push(node.clone());
        for next in &adj[&node] {
            let d = indegree.get_mut(next).unwrap();
            *d -= 1;
            if *d == 0 {
                queue.push(next.clone());
            }
        }
    }

    if order.len() == ids.len() {
        Ok(order)
    } else {
        Err(())
    }
}

#[test]
fn topological_order_succeeds_for_acyclic_graph() {
    let order = topological_order(&rich_pipeline()).expect("rich pipeline is acyclic");
    let pos = |id: &str| order.iter().position(|x| x == id).unwrap();
    // build must precede sign.
    assert!(pos("build") < pos("sign"));
}

#[test]
fn topological_order_detects_two_node_cycle() {
    let mut p = sample_pipeline();
    // fmt -> test already exists; add test -> fmt to close a 2-cycle.
    p.edges.push(Dependency {
        from: "test".to_string(),
        to: "fmt".to_string(),
    });
    assert!(
        topological_order(&p).is_err(),
        "a 2-node cycle must be rejected by topological sort"
    );
}

#[test]
fn topological_order_detects_three_node_cycle() {
    let mut p = Pipeline::new(
        PipelineSource::NativeToml,
        "acme/demo",
        "abc123",
        TrustTier::InternalBranch,
    );
    for id in ["a", "b", "c"] {
        let mut job = Job::new(id, id, RunnerClass::NativeRustClean);
        job.steps.push(Step::run(format!("{id}0"), id, "echo"));
        p.jobs.push(job);
    }
    for (from, to) in [("a", "b"), ("b", "c"), ("c", "a")] {
        p.edges.push(Dependency {
            from: from.to_string(),
            to: to.to_string(),
        });
    }
    assert!(
        topological_order(&p).is_err(),
        "a 3-node cycle must be rejected by topological sort"
    );
}

/// Dependency edges must form a DAG: `validate()` rejects multi-node cycles
/// that the independent topological sort above also rejects.
#[test]
fn validate_rejects_multi_node_cycles() {
    let mut p = sample_pipeline();
    p.edges.push(Dependency {
        from: "test".to_string(),
        to: "fmt".to_string(),
    });
    assert!(topological_order(&p).is_err());
    assert_eq!(
        p.validate(),
        Err(ValidationError::DependencyCycle("fmt".to_string()))
    );
    // A job hanging off the cycle does not hide it.
    let mut three = p.clone();
    three.edges.retain(|e| e.from != "test");
    let mut lint = Job::new("lint", "lint", RunnerClass::NativeRustClean);
    lint.steps.push(Step::run("l0", "lint", "echo"));
    three.jobs.push(lint);
    for (from, to) in [("test", "lint"), ("lint", "fmt")] {
        three.edges.push(Dependency {
            from: from.to_string(),
            to: to.to_string(),
        });
    }
    assert!(topological_order(&three).is_err());
    assert!(matches!(
        three.validate(),
        Err(ValidationError::DependencyCycle(_))
    ));
}

// ---------------------------------------------------------------------------
// TrustTier ordering / parsing / selection
// ---------------------------------------------------------------------------

#[test]
fn trust_tier_orders_labels_and_round_trips() {
    use TrustTier::*;
    // Derived Ord follows declaration order: ReleaseHermetic is the most trusted.
    let ordered = [
        ReleaseHermetic,
        ProtectedInternal,
        InternalBranch,
        AgentAuthored,
        ForkPr,
        PublicUntrusted,
    ];
    let mut shuffled = ordered.to_vec();
    shuffled.reverse();
    shuffled.sort();
    assert_eq!(shuffled, ordered);
    let labels = [
        "T0-release-hermetic",
        "T1-protected-internal",
        "T2-internal-branch",
        "T3-agent-authored",
        "T4-fork-pr",
        "T5-public-untrusted",
    ];
    for (tier, label) in ordered.iter().zip(labels) {
        assert_eq!(tier.as_str(), label);
        assert_eq!(label.parse::<TrustTier>().as_ref(), Ok(tier), "{label}");
    }
}

#[test]
fn trust_tier_from_str_accepts_aliases_and_rejects_unknown() {
    let cases: &[(&str, TrustTier)] = &[
        ("release", TrustTier::ReleaseHermetic),
        ("protected", TrustTier::ProtectedInternal),
        ("internal", TrustTier::InternalBranch),
        ("agent", TrustTier::AgentAuthored),
        ("fork", TrustTier::ForkPr),
        ("public", TrustTier::PublicUntrusted),
        ("untrusted", TrustTier::PublicUntrusted),
        // Case and separator insensitive.
        ("  T2 internal_branch  ", TrustTier::InternalBranch),
        ("RELEASE-HERMETIC", TrustTier::ReleaseHermetic),
    ];
    for (input, expected) in cases {
        assert_eq!(
            input.parse::<TrustTier>().as_ref(),
            Ok(expected),
            "parsing {input:?}"
        );
    }
    let err = "tier-9000".parse::<TrustTier>().unwrap_err();
    assert!(err.contains("unknown trust tier"), "err was: {err}");
}

// ---------------------------------------------------------------------------
// RunnerClass mapping / parsing
// ---------------------------------------------------------------------------

#[test]
fn runner_class_maps_names_aliases_and_custom() {
    use RunnerClass::*;
    assert_eq!(RunnerClass::default(), NativeRustClean);
    let canonical = [
        (NativeRustHot, "native-rust-hot"),
        (NativeRustClean, "native-rust-clean"),
        (CrategraphDelta, "crategraph-delta"),
        (NextestCapsule, "nextest-capsule"),
        (AgentGuard, "agent-guard"),
        (MergeSpec, "merge-spec"),
        (ReleaseHermetic, "release-hermetic"),
        (MicrovmRust, "microvm-rust"),
        (OciDocker, "oci-docker"),
        (K8sOci, "k8s-oci"),
    ];
    for (class, name) in canonical {
        assert_eq!(class.as_str(), name);
        assert_eq!(name.parse::<RunnerClass>(), Ok(class), "{name}");
    }
    // GitHub Actions-style labels, then custom fallback (quotes stripped).
    let aliases = [
        ("ubuntu-latest", NativeRustClean),
        ("linux", NativeRustClean),
        ("docker", OciDocker),
        ("kubernetes", K8sOci),
        ("k8s", K8sOci),
        ("microvm", MicrovmRust),
        ("gpu-fleet-a100", Custom("gpu-fleet-a100".to_string())),
        ("\"gpu fleet\"", Custom("gpu fleet".to_string())),
        ("'self-hosted'", Custom("self-hosted".to_string())),
    ];
    for (input, expected) in aliases {
        assert_eq!(input.parse::<RunnerClass>(), Ok(expected), "{input}");
    }
    assert_eq!(Custom("gpu-fleet".to_string()).as_str(), "gpu-fleet");
    for empty in ["", "   ", "\"\""] {
        assert!(empty.parse::<RunnerClass>().is_err(), "{empty:?}");
    }
}

// ---------------------------------------------------------------------------
// Round-trip stability of the IR (via its canonical serialization).
// ---------------------------------------------------------------------------

/// NOTE: the IR types in this crate do not derive `serde::Serialize` /
/// `Deserialize`, so a JSON serde round trip cannot be exercised without
/// changing the source (which these tests must not do). The crate's stable
/// on-the-wire form is the `canonical()` string consumed by `ir_hash()`. We
/// therefore assert round-trip *stability* of that canonical form: rebuilding
/// an equal `Pipeline` reproduces a byte-identical canonical string, and the
/// canonical string fully determines the hash.
#[test]
fn canonical_serialization_round_trip_is_stable() {
    let original = rich_pipeline();
    let canonical = original.canonical();

    // Re-derive from scratch: an independently-constructed but logically equal
    // pipeline must serialize to the exact same canonical bytes.
    let rebuilt = rich_pipeline();
    assert_eq!(rebuilt.canonical(), canonical);

    // The canonical string is the sole input to the hash.
    assert_eq!(original.ir_hash(), deterministic_hash(&canonical));
    assert_eq!(rebuilt.ir_hash(), deterministic_hash(&canonical));
}

#[test]
fn canonical_form_preserves_all_policy_fields() {
    let p = rich_pipeline();
    let c = p.canonical();
    // Cache policy (defaults retained).
    assert!(c.contains("cache.project_scoped=true"));
    assert!(c.contains("cache.allow_cross_project_compiled=false"));
    assert!(c.contains("cache.promote_after_green=true"));
    assert!(c.contains("cache.quarantine_untrusted_writes=true"));
    // Artifact policy.
    assert!(c.contains("artifact.allow_absolute_paths=false"));
    assert!(c.contains("artifact.require_metadata=true"));
    assert!(c.contains("artifact.default_retention_days=14"));
    // Permission policy.
    assert!(c.contains("permission.fail_closed=true"));
    // Secret policy (overridden in rich_pipeline).
    assert!(c.contains("secret.secrets_available=true"));
    assert!(c.contains("secret.deny_on_fork=true"));
    // Proof policy (overridden lane).
    assert!(c.contains("proof.required=true"));
    assert!(c.contains("proof.lane=release-strict"));
    // Signing policy (overridden).
    assert!(c.contains("signing.provenance_required=true"));
    assert!(c.contains("signing.release_only=true"));
}

#[test]
fn canonical_form_preserves_job_and_step_detail() {
    let p = rich_pipeline();
    let c = p.canonical();
    assert!(c.contains("job.id=build"));
    assert!(c.contains("job.runner=release-hermetic"));
    assert!(c.contains("job.timeout_seconds=1800"));
    assert!(c.contains("job.retry.max_attempts=3"));
    assert!(c.contains("job.retry.backoff_seconds=30"));
    assert!(c.contains("job.network=allowlist:registry.internal,crates.io"));
    assert!(c.contains("job.token=write-checks"));
    assert!(c.contains("job.input.profile=release"));
    assert!(c.contains("job.output.artifact=bin/forge"));
    assert!(c.contains("job.cache=cargo-registry|/root/.cargo/registry|read-write-trusted|fp-001"));
    assert!(c.contains("job.artifact=binaries|on-success|30|target/release/forge"));
    assert!(c.contains("job.step.run=cargo build --release"));
    assert!(c.contains("job.step.uses=actions/checkout@v4"));
    assert!(c.contains("job.step.cwd=workspace"));
    assert!(c.contains("job.step.env.RUSTFLAGS=-D warnings"));
    // Custom token scope on the sign job.
    assert!(c.contains("job.token=custom:id-token:write"));
    // The dependency edge is rendered.
    assert!(c.contains("edge=build->sign"));
}

#[test]
fn canonical_form_escapes_newlines_and_backslashes() {
    let mut p = sample_pipeline();
    p.jobs[0]
        .steps
        .push(Step::run("multi", "multi", "line1\nline2\\done"));
    let c = p.canonical();
    // Raw newline inside the value must be escaped so it cannot break the
    // line-oriented canonical format (and thus cannot collide hashes).
    assert!(
        c.contains("job.step.run=line1\\nline2\\\\done"),
        "got:\n{c}"
    );
}

#[test]
fn canonical_newline_escaping_prevents_hash_collision() {
    // Two distinct step commands that would alias if newlines were not escaped.
    let mut a = sample_pipeline();
    a.jobs[0].steps.push(Step::run("x", "x", "a\nb"));
    let mut b = sample_pipeline();
    b.jobs[0].steps.push(Step::run("x", "x", "a\\nb"));
    // They are genuinely different inputs; escaping keeps their hashes distinct.
    assert_ne!(a.ir_hash(), b.ir_hash());
}

// ---------------------------------------------------------------------------
// Policy & enum defaults / mappings
// ---------------------------------------------------------------------------

#[test]
fn policy_and_job_defaults_are_fail_safe() {
    let cache = CachePolicy::default();
    assert!(cache.project_scoped);
    assert!(!cache.allow_cross_project_compiled);
    assert!(cache.promote_after_green);
    assert!(cache.quarantine_untrusted_writes);

    let artifact = ArtifactPolicy::default();
    assert!(!artifact.allow_absolute_paths);
    assert!(artifact.require_metadata);
    assert_eq!(artifact.default_retention_days, 14);

    let permission = PermissionPolicy::default();
    assert!(permission.fail_closed);
    assert_eq!(permission.default_token_scope, TokenScope::ReadRepo);

    let secret = SecretPolicy::default();
    assert!(!secret.secrets_available);
    assert!(secret.deny_on_fork);

    let proof = ProofPolicy::default();
    assert!(proof.proof_required);
    assert_eq!(proof.lane, "phase3-fast");

    let signing = SigningPolicy::default();
    assert!(!signing.provenance_required);
    assert!(signing.release_only);

    let retry = RetryPolicy::default();
    assert_eq!(retry.max_attempts, 1);
    assert_eq!(retry.backoff_seconds, 0);

    assert_eq!(NetworkPolicy::default(), NetworkPolicy::Deny);
    assert_eq!(TokenScope::default(), TokenScope::ReadRepo);
    let job = Job::new("j", "J", RunnerClass::NativeRustClean);
    assert_eq!(job.network_policy, NetworkPolicy::Deny);
    assert_eq!(job.token_scope, TokenScope::ReadRepo);
    assert_eq!(job.timeout_seconds, 3600);
    assert!(job.steps.is_empty());
    assert_eq!(job.retry_policy, RetryPolicy::default());
}

#[test]
fn enum_labels_map_each_variant() {
    for (mode, label) in [
        (CacheMode::ReadOnly, "read-only"),
        (CacheMode::ReadWriteQuarantine, "read-write-quarantine"),
        (CacheMode::ReadWriteTrusted, "read-write-trusted"),
    ] {
        assert_eq!(mode.as_str(), label);
    }
    for (when, label) in [
        (ArtifactWhen::Always, "always"),
        (ArtifactWhen::OnSuccess, "on-success"),
        (ArtifactWhen::OnFailure, "on-failure"),
    ] {
        assert_eq!(when.as_str(), label);
    }
}

#[test]
fn pipeline_source_labels_display_and_order() {
    for (source, label) in [
        (PipelineSource::GitHubActions, "github-actions"),
        (PipelineSource::NativeToml, "jit-native"),
        (PipelineSource::Api, "api"),
        (PipelineSource::Agent, "agent"),
        (PipelineSource::MergeQueue, "merge-queue"),
        (PipelineSource::Hotfix, "hotfix"),
        (PipelineSource::Release, "release"),
        (PipelineSource::Scheduled, "scheduled"),
        (PipelineSource::Unknown("weird".to_string()), "weird"),
    ] {
        assert_eq!(source.as_str(), label);
        assert_eq!(source.to_string(), label);
    }
    // PipelineSource ordering is declaration order.
    assert!(PipelineSource::GitHubActions < PipelineSource::NativeToml);
    assert!(PipelineSource::Api < PipelineSource::Agent);
}

// ---------------------------------------------------------------------------

#[test]
fn sanitize_id_is_deterministic_and_lowercased() {
    assert_eq!(sanitize_id("Rust stable / Ubuntu"), "rust_stable_ubuntu");
    assert_eq!(sanitize_id("Build & Test"), "build_test");
    assert_eq!(sanitize_id("keep-dash.and_under"), "keep-dash.and_under");
}

#[test]
fn sanitize_id_collapses_runs_and_trims_separators() {
    assert_eq!(sanitize_id("a   b"), "a_b");
    assert_eq!(sanitize_id("  leading"), "leading");
    assert_eq!(sanitize_id("trailing  "), "trailing");
}

#[test]
fn sanitize_id_falls_back_to_unnamed() {
    assert_eq!(sanitize_id("!!!"), "unnamed");
    assert_eq!(sanitize_id(""), "unnamed");
    assert_eq!(sanitize_id("   "), "unnamed");
}

#[test]
fn sanitize_id_is_idempotent() {
    let once = sanitize_id("Some / Weird :: Name");
    assert_eq!(sanitize_id(&once), once);
}

#[test]
fn stable_id_prefixes_and_strips_hash_scheme() {
    let id = stable_id("job", "build");
    assert!(id.starts_with("job_"));
    assert!(!id.contains("fnv64:"));
    // Deterministic and pure.
    assert_eq!(id, stable_id("job", "build"));
    assert_ne!(stable_id("job", "build"), stable_id("job", "test"));
    assert_ne!(stable_id("job", "build"), stable_id("step", "build"));
}

#[test]
fn trim_quotes_strips_matched_pairs_only() {
    assert_eq!(trim_quotes("\"hello\""), "hello");
    assert_eq!(trim_quotes("'hello'"), "hello");
    assert_eq!(trim_quotes("  \"spaced\"  "), "spaced");
    // Unmatched / mixed quotes are left intact (after trimming whitespace).
    assert_eq!(trim_quotes("\"unbalanced"), "\"unbalanced");
    assert_eq!(trim_quotes("'mixed\""), "'mixed\"");
    assert_eq!(trim_quotes("plain"), "plain");
    // A lone quote is too short to be a matched pair.
    assert_eq!(trim_quotes("\""), "\"");
}

// ---------------------------------------------------------------------------
// Step constructors
// ---------------------------------------------------------------------------

#[test]
fn step_run_constructor_sets_command_only() {
    let s = Step::run("id", "name", "echo hi");
    assert_eq!(s.id, "id");
    assert_eq!(s.name, "name");
    assert_eq!(s.command.as_deref(), Some("echo hi"));
    assert_eq!(s.uses, None);
    assert!(s.env.is_empty());
    assert_eq!(s.working_directory, None);
}

#[test]
fn step_uses_constructor_sets_uses_only() {
    let s = Step::uses("id", "Checkout", "actions/checkout@v4");
    assert_eq!(s.command, None);
    assert_eq!(s.uses.as_deref(), Some("actions/checkout@v4"));
}

// ---------------------------------------------------------------------------
// ValidationError Display
// ---------------------------------------------------------------------------

#[test]
fn validation_error_display_is_human_readable() {
    assert_eq!(
        ValidationError::EmptyRepo.to_string(),
        "pipeline repo cannot be empty"
    );
    assert_eq!(
        ValidationError::DuplicateJob("build".into()).to_string(),
        "duplicate job id: build"
    );
    assert_eq!(
        ValidationError::JobHasNoSteps("build".into()).to_string(),
        "job has no steps: build"
    );
    assert_eq!(
        ValidationError::UnknownEdgeEndpoint("ghost".into()).to_string(),
        "edge references unknown job: ghost"
    );
    assert_eq!(
        ValidationError::SelfDependency("loop".into()).to_string(),
        "job cannot depend on itself: loop"
    );
    assert_eq!(
        ValidationError::DependencyCycle("a".into()).to_string(),
        "dependency cycle through job: a"
    );
}
