#![doc = "MicroVM runner planner/supervisor for untrusted Phase 4 jobs."]

use jeryu_runner_core::error::{RunnerError, RunnerResult};
use jeryu_runner_core::job::JobRequest;
use jeryu_runner_core::policy::PolicyDecision;
use jeryu_runner_core::receipt::{Receipt, ReceiptStatus, now_ms};
use jeryu_runner_core::sandbox::SandboxPlan;
use jeryu_runner_core::trust::RunnerClass;
pub mod api;
pub mod artifacts;
pub mod checkpoint;
mod diagnostics;
pub mod image_composition;
pub mod journal;
pub mod lease_authority;
pub(crate) mod runtime_authority;
pub mod source_registry;
pub mod supervisor;
pub mod transport;
mod vmm;

pub use supervisor::{MicroVmSession, NodeConfig};

/// MicroVM launch specification.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MicroVmSpec {
    /// MicroVM executable, e.g. firecracker.
    pub executable: String,
    /// Kernel image path.
    pub kernel_image: String,
    /// Rootfs image path.
    pub rootfs_image: String,
    /// Workdir exposed through a virtio/vsock-backed handoff.
    pub workspace: String,
    /// Command to execute inside guest.
    pub guest_command: Vec<String>,
    /// Network mode.
    pub network: String,
}

impl MicroVmSpec {
    /// Build a spec from a job and sandbox plan.
    pub fn from_job(job: &JobRequest, plan: &SandboxPlan) -> RunnerResult<Self> {
        if plan.runner_class != RunnerClass::MicroVmRust {
            return Err(RunnerError::new(
                "invalid_microvm_runner",
                format!("{} is not microvm-rust", plan.runner_class),
            ));
        }
        let executable =
            std::env::var("JERYU_MICROVM_BIN").unwrap_or_else(|_| "firecracker".to_string());
        let kernel_image = std::env::var("JERYU_MICROVM_KERNEL")
            .unwrap_or_else(|_| "/var/lib/jeryu/microvm/vmlinux".to_string());
        let rootfs_image = std::env::var("JERYU_MICROVM_ROOTFS")
            .unwrap_or_else(|_| "/var/lib/jeryu/microvm/rust-rootfs.ext4".to_string());
        let mut guest_command = vec![job.command.clone()];
        guest_command.extend(job.args.clone());
        Ok(Self {
            executable,
            kernel_image,
            rootfs_image,
            workspace: job.workspace.display().to_string(),
            guest_command,
            network: plan.network_policy.as_str().to_string(),
        })
    }

    /// Explain this spec without exposing secrets.
    pub fn explain(&self) -> String {
        format!(
            "microvm executable={} kernel={} rootfs={} workspace={} network={} guest-argv-count={}",
            self.executable,
            self.kernel_image,
            self.rootfs_image,
            self.workspace,
            self.network,
            self.guest_command.len()
        )
    }
}

/// MicroVM runner.
#[derive(Debug, Default, Clone)]
pub struct MicroVmRunner;

impl MicroVmRunner {
    /// Create a microVM runner.
    pub fn new() -> Self {
        Self
    }

    /// Build a microVM plan receipt without consulting the execution gate or
    /// invoking the configured launcher.
    ///
    /// Explain mode dispatches here so a plan request stays non-executing even
    /// when the host has enabled real microVM execution for the run path.
    pub fn plan_only(
        &self,
        job: &JobRequest,
        decision: &PolicyDecision,
        plan: &SandboxPlan,
    ) -> RunnerResult<Receipt> {
        let spec = MicroVmSpec::from_job(job, plan)?;
        let timestamp = now_ms();
        Ok(Receipt::new(
            job,
            decision,
            plan,
            ReceiptStatus::Planned,
            None,
            timestamp,
            timestamp,
            spec.explain(),
        ))
    }

    /// A managed launch cannot degrade to a planned receipt or run an arbitrary
    /// host launcher. Use `MicroVmSession::start` with a fenced v2 lease.
    pub fn execute_required(
        &self,
        _job: &JobRequest,
        _decision: &PolicyDecision,
        _plan: &SandboxPlan,
    ) -> RunnerResult<Receipt> {
        Err(RunnerError::new(
            "microvm_session_lease_required",
            "managed execution requires a v2 session lease",
        ))
    }

    /// Plan or execute a microVM job.
    ///
    /// By default this returns a plan receipt. Set `JERYU_RUN_MICROVM=1` to
    /// request execution. Legacy host launcher overrides cannot execute a job;
    /// real execution uses the validated session supervisor.
    pub fn execute(
        &self,
        job: &JobRequest,
        decision: &PolicyDecision,
        plan: &SandboxPlan,
    ) -> RunnerResult<Receipt> {
        let spec = MicroVmSpec::from_job(job, plan)?;
        let started = now_ms();
        if std::env::var("JERYU_RUN_MICROVM").ok().as_deref() != Some("1") {
            return Ok(Receipt::new(
                job,
                decision,
                plan,
                ReceiptStatus::Planned,
                None,
                started,
                started,
                spec.explain(),
            ));
        }

        Err(RunnerError::new(
            "microvm_session_lease_required",
            "execution requires a v2 session lease, verified runtime, and guest transport",
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use jeryu_runner_core::job::{NetworkPolicy, SecretPolicy, TokenPolicy};
    use jeryu_runner_core::policy::select_runner;
    use jeryu_runner_core::sandbox::SandboxPlan;
    use jeryu_runner_core::trust::TrustTier;
    use std::path::PathBuf;

    #[test]
    fn fork_job_builds_microvm_spec() {
        let job = JobRequest {
            job_id: "job".to_string(),
            repo_id: "repo".to_string(),
            commit_sha: "abc".to_string(),
            workspace: PathBuf::from("/tmp/work"),
            command: "/bin/echo".to_string(),
            args: vec!["ok".to_string()],
            env: Default::default(),
            trust_tier: TrustTier::T4ForkPr,
            requested_runner: None,
            network_policy: NetworkPolicy::Deny,
            secret_policy: SecretPolicy::Default,
            token_policy: TokenPolicy::ReadOnly,
            timeout_ms: 1000,
            fork: true,
        };
        let decision = select_runner(&job).unwrap_or_else(|err| panic!("{err}"));
        let plan = SandboxPlan::from_decision(&job.workspace, &decision);
        let spec = MicroVmSpec::from_job(&job, &plan).unwrap_or_else(|err| panic!("{err}"));
        assert_eq!(spec.network, "deny");
        assert!(spec.explain().contains("microvm"));
    }

    #[test]
    fn plan_only_returns_non_executing_receipt() {
        let job = JobRequest {
            job_id: "job".to_string(),
            repo_id: "repo".to_string(),
            commit_sha: "abc".to_string(),
            workspace: PathBuf::from("/tmp/work"),
            command: "/definitely/not/a/launcher".to_string(),
            args: Vec::new(),
            env: Default::default(),
            trust_tier: TrustTier::T4ForkPr,
            requested_runner: None,
            network_policy: NetworkPolicy::Deny,
            secret_policy: SecretPolicy::Default,
            token_policy: TokenPolicy::ReadOnly,
            timeout_ms: 1000,
            fork: true,
        };
        let decision = select_runner(&job).unwrap_or_else(|err| panic!("{err}"));
        let plan = SandboxPlan::from_decision(&job.workspace, &decision);

        let receipt = MicroVmRunner::new()
            .plan_only(&job, &decision, &plan)
            .unwrap_or_else(|err| panic!("{err}"));

        assert_eq!(receipt.status, ReceiptStatus::Planned);
        assert_eq!(receipt.exit_code, None);
    }
}

/// Independent privileged lifetime fencing for managed VMs.
pub mod guardian;
