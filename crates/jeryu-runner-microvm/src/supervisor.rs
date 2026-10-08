//! Real VM supervision: admission, Jailer, API boot, private vsock handshake,
//! guest results, lease expiry, and node-owned cleanup.
mod admission;
mod boot;
mod storage;
use crate::{
    api,
    artifacts::{VerifiedRuntime, trusted_directory},
    diagnostics::DiagnosticDrain,
    journal::{NodeJournal, ResourceRecord, ResourceState},
};
use jeryu_runner_core::{RunnerError, RunnerResult, receipt::now_ms};
use jeryu_runner_protocol::{
    guest::{GuestEvent, GuestProfile, GuestRequest, read_frame, write_frame},
    wire::v2::{SessionLease, WorkspaceReady},
};
use nix::unistd::{Gid, Uid, chown};
use serde_json::json;
use std::{
    fs::OpenOptions,
    os::unix::{
        fs::{OpenOptionsExt, PermissionsExt},
        net::UnixStream,
    },
    path::PathBuf,
    process::Child,
    sync::{Arc, Mutex, mpsc},
    time::{Duration, Instant},
};
pub use storage::HostStorageReservation;

#[derive(Clone, Debug)]
pub struct NodeConfig {
    pub runner_id: String,
    pub runner_epoch: u64,
    /// Enrolled control-plane authority. Never taken from a lease or guest.
    pub control_plane_lease_key: [u8; 32],
    /// Root-owned service state, with no untrusted parent directories.
    pub state_dir: PathBuf,
    pub capacity: usize,
    /// Explicit node share after host reserve, never implicit CPU overcommit.
    pub cpu_budget_vcpus: u16,
    pub memory_budget_mib: u32,
    pub disk_budget_gib: u32,
}

pub struct Node {
    config: NodeConfig,
    journal: NodeJournal,
    admission: Mutex<()>,
    upload_reserved_bytes: std::sync::atomic::AtomicU64,
    checkpoints: crate::checkpoint::CheckpointStore,
}

impl Node {
    pub fn validate_lease(&self, lease: &SessionLease) -> RunnerResult<()> {
        crate::lease_authority::verify(lease, &self.config.control_plane_lease_key)?;
        if lease.connection_bindings.iter().any(|binding| {
            binding.mode == jeryu_runner_protocol::wire::v2::ConnectionMode::QualifiedRamToken
        }) {
            return Err(failed("provider_mode_unqualified"));
        }
        let now = u64::try_from(now_ms()).map_err(|_| failed("microvm_clock_invalid"))?;
        lease
            .validate_for_runner(&self.config.runner_id, self.config.runner_epoch, now)
            .map_err(|_| failed("microvm_lease_invalid"))
    }
    /// Retried at startup and every 30 seconds. A malformed owned record stays
    /// visible; only expired or already-cleaning resources can be destroyed.
    pub fn reconcile(&self) -> RunnerResult<()> {
        let mut failure = None;
        for record in self.journal.records()? {
            if (matches!(record.state, ResourceState::Cleaning)
                || now_ms() >= u128::from(record.expires_at_unix_millis))
                && let Err(error) = self.journal.cleanup(&record)
            {
                failure.get_or_insert(error);
            }
        }
        if let Err(error) = self.checkpoints.reconcile() {
            failure.get_or_insert(error);
        }
        failure.map_or(Ok(()), Err)
    }
    pub fn checkpoints(&self) -> &crate::checkpoint::CheckpointStore {
        &self.checkpoints
    }
}

impl NodeConfig {
    /// Constrained launcher runs as a dedicated root service. Agents never
    /// execute in this process. Operator accounts need no direct KVM access.
    pub fn open(self) -> RunnerResult<Arc<Node>> {
        if !Uid::effective().is_root() {
            return Err(failed("microvm_launcher_privilege_required"));
        }
        if self.capacity == 0
            || self.capacity > 64
            || self.runner_epoch == 0
            || !(1..=2048).contains(&self.cpu_budget_vcpus)
            || self.memory_budget_mib == 0
            || self.disk_budget_gib == 0
            || self.control_plane_lease_key == [0; 32]
            || ed25519_dalek::VerifyingKey::from_bytes(&self.control_plane_lease_key).is_err()
        {
            return Err(failed("microvm_node_config_invalid"));
        }
        OpenOptions::new()
            .read(true)
            .write(true)
            .open("/dev/kvm")
            .map_err(|_| failed("microvm_kvm_unavailable"))?;
        let journal = NodeJournal::open(&self.state_dir)?;
        // The node lock fences another launcher. Previous daemon resources are
        // stopped before any new writable generation can be admitted.
        let mut failure = None;
        for record in journal.records()? {
            if let Err(error) = journal.cleanup(&record) {
                failure.get_or_insert(error);
            }
        }
        if let Some(error) = failure {
            return Err(error);
        }
        let checkpoints = crate::checkpoint::CheckpointStore::open(&self.state_dir)?;
        checkpoints.reconcile()?;
        let node = Arc::new(Node {
            config: self,
            journal,
            admission: Mutex::new(()),
            upload_reserved_bytes: std::sync::atomic::AtomicU64::new(0),
            checkpoints,
        });
        let weak = Arc::downgrade(&node);
        std::thread::spawn(move || {
            loop {
                std::thread::sleep(Duration::from_secs(30));
                let Some(node) = weak.upgrade() else {
                    break;
                };
                if let Err(error) = node.reconcile() {
                    eprintln!("jeryu_microvm_reconciliation_failed code={}", error.code());
                }
            }
        });
        Ok(node)
    }
}

pub struct MicroVmSession {
    node: Arc<Node>,
    record: ResourceRecord,
    lease: SessionLease,
    child: Option<Child>,
    channel: Option<UnixStream>,
    reader: Option<crate::transport::GuestReader>,
    started: Instant,
    maximum_runtime: Duration,
    stopped: bool,
    watchdog_cancel: Option<mpsc::Sender<()>>,
    diagnostics: Vec<DiagnosticDrain>,
    workspace_ready: Option<WorkspaceReady>,
    vmm: Option<Arc<crate::vmm::VmmGuard>>,
    checkpoint: Option<jeryu_runner_protocol::wire::v2::CheckpointReference>,
}

impl MicroVmSession {
    pub fn start(
        node: Arc<Node>,
        runtime: &VerifiedRuntime,
        lease: SessionLease,
    ) -> RunnerResult<Self> {
        let now = u64::try_from(now_ms()).map_err(|_| failed("microvm_clock_invalid"))?;
        node.validate_lease(&lease)?;
        if runtime.manifest() != &lease.runtime {
            return Err(failed("microvm_runtime_mismatch"));
        }
        GuestProfile::registered(&lease.profile_id).map_err(|_| failed("unknown_agent_profile"))?;
        let maximum_runtime = Duration::from_millis(lease.expires_at_unix_millis - now);
        let resource_id = uuid::Uuid::new_v4().simple().to_string();
        let artifact_bytes = admission::artifact_bytes(runtime, &lease)?;
        let record = {
            let _admission = node
                .admission
                .lock()
                .map_err(|_| failed("node_journal_unavailable"))?;
            let journal = &node.journal;
            let existing = journal.records()?;
            journal.require_clean_admission()?;
            admission::check(
                &node.config,
                &existing,
                &lease,
                node.checkpoints.retained_bytes()?,
                artifact_bytes,
            )?;
            admission::check_free_space(
                &node.journal,
                &node.config.state_dir,
                &existing,
                admission::new_disk_charge(&lease, artifact_bytes)?
                    + u128::from(
                        node.upload_reserved_bytes
                            .load(std::sync::atomic::Ordering::Acquire),
                    ),
            )?;
            if existing
                .iter()
                .any(|r| r.context.session_id == lease.context.session_id)
            {
                return Err(failed("microvm_generation_already_running"));
            }
            let uid = (200000..200064)
                .find(|uid| existing.iter().all(|r| r.uid != *uid))
                .ok_or_else(|| failed("microvm_capacity_unavailable"))?;
            let record = ResourceRecord {
                resource_id,
                uid,
                vcpus: lease.resources.vcpus,
                artifact_bytes,
                memory_mib: lease.resources.memory_mib,
                workspace_gib: lease.resources.workspace_gib,
                context: lease.context.clone(),
                expires_at_unix_millis: lease.expires_at_unix_millis,
                state: ResourceState::Provisioning,
                firecracker_digest: runtime.manifest().firecracker.digest.clone(),
                vmm: None,
                retain_workspace: false,
                workspace_flushed: false,
                checkpoint: None,
                workspace: None,
            };
            journal.write(&record)?;
            record
        };
        let mut session = Self {
            node,
            record,
            lease,
            child: None,
            channel: None,
            reader: None,
            started: Instant::now(),
            maximum_runtime,
            stopped: false,
            watchdog_cancel: None,
            diagnostics: Vec::new(),
            workspace_ready: None,
            vmm: None,
            checkpoint: None,
        };
        session.boot(runtime)?;
        session.start_watchdog();
        Ok(session)
    }

    fn root(&self) -> RunnerResult<PathBuf> {
        self.node.journal.jail_root(&self.record.resource_id)
    }

    fn start_watchdog(&mut self) {
        let (cancel, receive) = mpsc::channel();
        self.watchdog_cancel = Some(cancel);
        let node = self.node.clone();
        let record = self.record.clone();
        let vmm = self.vmm.clone();
        let diagnostics: Vec<_> = self
            .diagnostics
            .iter()
            .map(DiagnosticDrain::cancellation)
            .collect();
        let deadline = self.started + self.maximum_runtime;
        std::thread::spawn(move || {
            loop {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() || now_ms() >= u128::from(record.expires_at_unix_millis) {
                    break;
                }
                match receive.recv_timeout(remaining.min(Duration::from_secs(1))) {
                    Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => return,
                    Err(mpsc::RecvTimeoutError::Timeout) => (),
                }
            }
            // Expiry destroys the VM even if the client never polls again.
            // Failed cleanup remains journaled for startup reconciliation.
            if let Some(vmm) = vmm {
                let _ = vmm.terminate();
            }
            let _ = node.journal.cleanup(&record);
            for stop in diagnostics {
                stop.store(true, std::sync::atomic::Ordering::Release);
            }
        });
    }

    fn ensure_live(&self) -> RunnerResult<()> {
        if self.stopped
            || self.started.elapsed() >= self.maximum_runtime
            || now_ms() >= u128::from(self.lease.expires_at_unix_millis)
        {
            return Err(failed("microvm_lease_expired"));
        }
        Ok(())
    }

    pub fn send(&mut self, request: &GuestRequest) -> RunnerResult<()> {
        if let Err(error) = self.ensure_live() {
            self.stop()?;
            return Err(error);
        }
        if matches!(request, GuestRequest::Bind { .. }) {
            return Err(failed("microvm_rebind_denied"));
        }
        write_frame(
            self.channel
                .as_mut()
                .ok_or_else(|| failed("microvm_not_running"))?,
            request,
        )?;
        Ok(())
    }

    /// A VMM exit cannot produce this result: only validated guest events do.
    pub fn receive(&mut self) -> RunnerResult<GuestEvent> {
        self.reader
            .as_mut()
            .ok_or_else(|| failed("microvm_reader_unavailable"))?
            .receive()
    }

    /// Transfer the single event reader without blocking command writes.
    pub fn take_reader(&mut self) -> RunnerResult<crate::transport::GuestReader> {
        self.ensure_live()?;
        self.reader
            .take()
            .ok_or_else(|| failed("microvm_reader_unavailable"))
    }

    pub fn workspace_ready(&self) -> Option<&WorkspaceReady> {
        self.workspace_ready.as_ref()
    }
    pub fn checkpoint(&self) -> Option<&jeryu_runner_protocol::wire::v2::CheckpointReference> {
        self.checkpoint.as_ref()
    }
    /// Called only after the authenticated guest freeze acknowledgement.
    pub fn mark_workspace_flushed(
        &mut self,
        workspace: Option<WorkspaceReady>,
    ) -> RunnerResult<()> {
        self.record = self.node.journal.mark_flushed(&self.record, workspace)?;
        Ok(())
    }

    pub fn stop(&mut self) -> RunnerResult<()> {
        if self.stopped {
            return Ok(());
        }
        // Direct drivers keep the event reader. SessionService uses its separate
        // reader and marks the same acknowledgement before calling stop.
        if self.reader.is_some() && self.channel.is_some() {
            let id = "host-stop-freeze";
            if write_frame(
                self.channel
                    .as_mut()
                    .ok_or_else(|| failed("microvm_not_running"))?,
                &GuestRequest::Freeze {
                    request_id: id.into(),
                },
            )
            .is_ok()
            {
                let deadline = Instant::now() + Duration::from_secs(3);
                while Instant::now() < deadline {
                    match self
                        .reader
                        .as_mut()
                        .ok_or_else(|| failed("microvm_reader_unavailable"))?
                        .poll(Duration::from_millis(100))
                    {
                        Ok(Some(GuestEvent::Frozen {
                            request_id,
                            workspace,
                        })) if request_id == id => {
                            self.mark_workspace_flushed(workspace)?;
                            break;
                        }
                        Ok(Some(_)) | Ok(None) => (),
                        Err(_) => break,
                    }
                }
            }
        }
        if let Some(channel) = self.channel.take() {
            let _ = channel.shutdown(std::net::Shutdown::Both);
        }
        self.reader.take();
        if let Some(vmm) = &self.vmm {
            vmm.terminate()?;
            vmm.wait_dead()?;
        }
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.checkpoint = self.node.journal.cleanup(&self.record)?;
        self.diagnostics.clear();
        if let Some(cancel) = self.watchdog_cancel.take() {
            let _ = cancel.send(());
        }
        self.stopped = true;
        Ok(())
    }
}

impl Drop for MicroVmSession {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}
fn failed(code: &'static str) -> RunnerError {
    RunnerError::new(code, "microVM lifecycle operation failed")
}
