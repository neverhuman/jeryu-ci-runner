use jeryu_runner_core::job::{NetworkPolicy, SecretPolicy};
use jeryu_runner_core::{
    CacheWritePolicy, ExecutionPurpose, JobRequest, RunnerClass, SandboxPlan, TokenPolicy,
    TrustTier, select_runner_for,
};

fn job(tier: TrustTier) -> JobRequest {
    JobRequest {
        job_id: "managed".into(),
        repo_id: "owner/repo".into(),
        commit_sha: "abc".into(),
        workspace: "/tmp/workspace".into(),
        command: "/bin/sh".into(),
        args: vec![],
        env: Default::default(),
        trust_tier: tier,
        requested_runner: None,
        network_policy: NetworkPolicy::Deny,
        secret_policy: SecretPolicy::Requested,
        token_policy: TokenPolicy::ScopedWrite,
        timeout_ms: 1000,
        fork: false,
    }
}

#[test]
fn every_trust_tier_requires_a_microvm_and_excludes_host_authority() {
    for tier in [
        TrustTier::T0ReleaseHermetic,
        TrustTier::T1ProtectedInternal,
        TrustTier::T2InternalBranch,
        TrustTier::T3AgentAuthored,
        TrustTier::T4ForkPr,
        TrustTier::T5PublicUntrusted,
    ] {
        let mut request = job(tier);
        request.network_policy = NetworkPolicy::EgressOnly;
        let decision = select_runner_for(&request, ExecutionPurpose::ManagedAgent).unwrap();
        assert_eq!(decision.runner_class, RunnerClass::MicroVmRust);
        assert_eq!(decision.network_policy, NetworkPolicy::Deny);
        assert!(!decision.allow_secrets);
        assert_eq!(decision.token_policy, TokenPolicy::None);
        assert_eq!(decision.cache_write_policy, CacheWritePolicy::Quarantine);
        let plan = SandboxPlan::from_decision("/tmp/workspace", &decision);
        assert!(plan.mounts.is_empty());
        assert!(plan.landlock_rules.is_empty());
        for runner in [
            RunnerClass::NativeRustHot,
            RunnerClass::NativeRustClean,
            RunnerClass::AgentGuard,
            RunnerClass::ReleaseHermetic,
            RunnerClass::OciDocker,
        ] {
            let mut request = job(tier);
            request.requested_runner = Some(runner);
            assert_eq!(
                select_runner_for(&request, ExecutionPurpose::ManagedAgent)
                    .unwrap_err()
                    .code(),
                "managed_agent_requires_microvm"
            );
        }
    }
}

#[test]
fn provider_access_cannot_be_issued_to_ci_or_host_backends() {
    for purpose in [ExecutionPurpose::Ci, ExecutionPurpose::ManagedAgent] {
        for runner in [
            RunnerClass::NativeRustHot,
            RunnerClass::NativeRustClean,
            RunnerClass::AgentGuard,
            RunnerClass::ReleaseHermetic,
            RunnerClass::OciDocker,
            RunnerClass::MicroVmRust,
        ] {
            assert_eq!(
                purpose.require_provider_boundary(runner).is_ok(),
                purpose == ExecutionPurpose::ManagedAgent && runner == RunnerClass::MicroVmRust
            );
        }
    }
}

#[test]
fn ordinary_ci_keeps_its_existing_runner_policy() {
    assert_eq!(
        select_runner_for(&job(TrustTier::T1ProtectedInternal), ExecutionPurpose::Ci)
            .unwrap()
            .runner_class,
        RunnerClass::NativeRustHot
    );
}
