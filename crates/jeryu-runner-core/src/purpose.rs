//! Execution purpose is assigned by the trusted dispatcher, independently of trust tier.

use crate::{JobRequest, RunnerClass, RunnerError, RunnerResult};

/// The authority under which a workload runs. Agent-authored CI is still CI;
/// a running agent, its tools and its builds are managed-agent work.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExecutionPurpose {
    Ci,
    ManagedAgent,
}

impl ExecutionPurpose {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ci => "ci",
            Self::ManagedAgent => "managed-agent",
        }
    }

    /// Called at every backend boundary, including direct backend invocation.
    pub fn require_runner(self, runner: RunnerClass) -> RunnerResult<()> {
        if self == Self::ManagedAgent && runner != RunnerClass::MicroVmRust {
            return Err(RunnerError::new(
                "managed_agent_requires_microvm",
                "managed-agent execution requires microvm-rust",
            ));
        }
        Ok(())
    }

    /// Provider credentials can only be issued for broker-authorized agent VMs.
    /// Passing this check does not grant access to a provider connection.
    pub fn require_provider_boundary(self, runner: RunnerClass) -> RunnerResult<()> {
        if self != Self::ManagedAgent || runner != RunnerClass::MicroVmRust {
            return Err(RunnerError::new(
                "provider_credentials_denied",
                "provider access requires managed-agent microVM execution",
            ));
        }
        Ok(())
    }
}

/// Policy for an explicitly classified workload. Clients cannot supply purpose
/// through a command argument or environment variable; the authenticated service
/// chooses it before dispatch. The legacy selector continues to classify CI.
pub fn select_runner_for(
    job: &JobRequest,
    purpose: ExecutionPurpose,
) -> RunnerResult<crate::PolicyDecision> {
    if purpose == ExecutionPurpose::Ci {
        return crate::select_runner(job);
    }
    job.validate()?;
    if let Some(requested) = job.requested_runner {
        purpose.require_runner(requested)?;
    }
    // A caller's trust tier cannot enable host execution, Git authority, ambient
    // secrets, or shared compiled-cache promotion for an agent.
    Ok(crate::PolicyDecision {
        runner_class: RunnerClass::MicroVmRust,
        // Managed guests have no NIC. Brokered vsock egress is separately
        // authorized by the session service; callers cannot widen it here.
        network_policy: crate::NetworkPolicy::Deny,
        allow_secrets: false,
        token_policy: crate::TokenPolicy::None,
        cache_write_policy: crate::CacheWritePolicy::Quarantine,
        reasons: vec![
            "purpose=managed-agent".to_string(),
            "runner=microvm-required".to_string(),
            "credentials=broker-only".to_string(),
            "git-authority=trusted-export-only".to_string(),
        ],
    })
}
