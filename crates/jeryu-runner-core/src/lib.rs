#![doc = "Shared Phase 4 runner-fabric types and policy logic."]

pub mod credguard;
pub mod error;
pub mod fscheck;
pub mod job;
pub mod policy;
pub mod purpose;
pub mod receipt;
pub mod sandbox;
pub mod trust;

pub use credguard::{
    deny_credential_material, deny_destination_symlink, deny_token_values,
    deny_token_values_in_bytes, ensure_within_export_roots, guard_export_path,
    guard_write_destination,
};
pub use error::{RunnerError, RunnerResult};
pub use job::{JobRequest, NetworkPolicy, SecretPolicy, TokenPolicy};
pub use policy::{CacheWritePolicy, PolicyDecision, select_runner};
pub use purpose::{ExecutionPurpose, select_runner_for};
pub use receipt::{Receipt, ReceiptStatus};
pub use sandbox::{CgroupLimits, LandlockRule, MountSpec, SandboxPlan, SeccompProfile};
pub use trust::{RunnerClass, TrustTier};
