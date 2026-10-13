//! Crash-safe resource ownership. Cleanup derives paths solely from node-owned
//! identifiers; guest paths and process IDs never authorize host deletion.
use crate::artifacts::trusted_directory;
use jeryu_runner_core::{RunnerError, RunnerResult};
use jeryu_runner_protocol::wire::v2::{CheckpointReference, SessionContext, WorkspaceReady};
use nix::fcntl::{Flock, FlockArg};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, Weak};
mod cleanup;
mod records;
mod uid_range;
pub use uid_range::LEGACY_UID_BASE;
pub(crate) use uid_range::UidRange;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResourceRecord {
    pub resource_id: String,
    pub uid: u32,
    #[serde(default = "maximum_cpu_charge")]
    pub vcpus: u8,
    #[serde(default = "historic_artifact_charge")]
    pub artifact_bytes: u64,
    pub memory_mib: u32,
    pub workspace_gib: u32,
    pub context: SessionContext,
    pub expires_at_unix_millis: u64,
    pub state: ResourceState,
    pub firecracker_digest: String,
    pub vmm: Option<crate::vmm::VmmIdentity>,
    #[serde(default)]
    pub deadline: Option<crate::guardian::Deadline>,
    #[serde(default)]
    pub retain_workspace: bool,
    #[serde(default)]
    pub workspace_flushed: bool,
    pub checkpoint: Option<CheckpointReference>,
    pub workspace: Option<WorkspaceReady>,
}

fn maximum_cpu_charge() -> u8 {
    32
}
fn historic_artifact_charge() -> u64 {
    1 << 30
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ResourceState {
    Provisioning,
    Running,
    Cleaning,
}

pub struct NodeJournal {
    root: PathBuf,
    _lock: Flock<File>,
    cleanup_locks: Mutex<BTreeMap<String, Weak<Mutex<()>>>>,
    uid_range: UidRange,
}

impl NodeJournal {
    pub fn open(root: &Path) -> RunnerResult<Self> {
        Self::open_with_uid_base(root, LEGACY_UID_BASE)
    }

    pub fn open_with_uid_base(root: &Path, uid_base: u32) -> RunnerResult<Self> {
        trusted_directory(root)?;
        let journals = root.join("records");
        if !journals.exists() {
            std::fs::create_dir(&journals)?;
        }
        trusted_directory(&journals)?;
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(nix::libc::O_NOFOLLOW)
            .open(root.join("node.lock"))?;
        let meta = file.metadata()?;
        if !meta.is_file() || meta.uid() != 0 || meta.mode() & 0o077 != 0 || meta.nlink() != 1 {
            return Err(failed("node_journal_custody_denied"));
        }
        let lock = Flock::lock(file, FlockArg::LockExclusiveNonblock)
            .map_err(|_| failed("node_already_running"))?;
        let uid_range = UidRange::enroll(root, uid_base)?;
        Ok(Self {
            root: root.to_path_buf(),
            _lock: lock,
            cleanup_locks: Mutex::new(BTreeMap::new()),
            uid_range,
        })
    }

    pub fn records(&self) -> RunnerResult<Vec<ResourceRecord>> {
        records::load(&self.root, self.uid_range)
    }

    /// Unknown resource ownership must never permit UID/capacity reuse.
    pub(crate) fn require_clean_admission(&self) -> RunnerResult<()> {
        let path = self.root.join("quarantine");
        if path.exists() {
            trusted_directory(&path)?;
            if std::fs::read_dir(path)?.next().is_some() {
                return Err(failed("node_journal_quarantined"));
            }
        }
        crate::guardian::fence::require_owned(&self.root, &self.records()?)?;
        Ok(())
    }

    pub fn write(&self, record: &ResourceRecord) -> RunnerResult<()> {
        valid_id(&record.resource_id)?;
        if !self.uid_range.contains(record.uid) {
            return Err(failed("node_journal_invalid"));
        }
        let directory = self.root.join("records");
        let temporary = directory.join(format!("{}.new", record.resource_id));
        // A prior crash's incomplete replacement is discarded, without following it.
        match std::fs::remove_file(&temporary) {
            Ok(()) => (),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
            Err(e) => return Err(e.into()),
        }
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(&serde_json::to_vec(record).map_err(|_| failed("node_journal_invalid"))?)?;
        file.sync_all()?;
        std::fs::rename(
            temporary,
            directory.join(format!("{}.json", record.resource_id)),
        )?;
        File::open(directory)?.sync_all()?;
        Ok(())
    }

    pub fn jail_root(&self, id: &str) -> RunnerResult<PathBuf> {
        valid_id(id)?;
        Ok(self
            .root
            .join("j")
            .join("firecracker")
            .join(id)
            .join("root"))
    }

    pub fn cleanup(&self, record: &ResourceRecord) -> RunnerResult<Option<CheckpointReference>> {
        valid_id(&record.resource_id)?;
        if !self.uid_range.contains(record.uid) {
            return Err(failed("node_journal_invalid"));
        }
        // Only this resource is held while waiting for its cgroup to empty.
        // Another session can reserve/admit capacity without waiting five seconds.
        let resource_lock = self.resource_lock(&record.resource_id)?;
        let _guard = resource_lock
            .lock()
            .map_err(|_| failed("node_journal_unavailable"))?;
        self.cleanup_locked(record)
    }
    pub(crate) fn mark_flushed(
        &self,
        expected: &ResourceRecord,
        workspace: Option<WorkspaceReady>,
    ) -> RunnerResult<ResourceRecord> {
        let resource_lock = self.resource_lock(&expected.resource_id)?;
        let _guard = resource_lock
            .lock()
            .map_err(|_| failed("node_journal_unavailable"))?;
        let mut record = self
            .records()?
            .into_iter()
            .find(|record| record.resource_id == expected.resource_id)
            .ok_or_else(|| failed("node_cleanup_fenced"))?;
        if record.context != expected.context
            || record.uid != expected.uid
            || !matches!(record.state, ResourceState::Running)
        {
            return Err(failed("node_cleanup_fenced"));
        }
        record.workspace_flushed = true;
        match (&record.workspace, &workspace) {
            (Some(previous), Some(frozen))
                if frozen.source_revision == record.context.source_revision
                    && frozen.main_revision == previous.main_revision =>
            {
                frozen
                    .validate()
                    .map_err(|_| failed("checkpoint_workspace_invalid"))?;
            }
            (None, None) => (),
            _ => return Err(failed("checkpoint_workspace_fenced")),
        }
        record.workspace = workspace;
        self.write(&record)?;
        Ok(record)
    }
    fn resource_lock(&self, id: &str) -> RunnerResult<Arc<Mutex<()>>> {
        valid_id(id)?;
        let resource_lock = {
            let mut locks = self
                .cleanup_locks
                .lock()
                .map_err(|_| failed("node_journal_unavailable"))?;
            locks.retain(|_, lock| lock.strong_count() != 0);
            if let Some(lock) = locks.get(id).and_then(Weak::upgrade) {
                lock
            } else {
                let lock = Arc::new(Mutex::new(()));
                locks.insert(id.into(), Arc::downgrade(&lock));
                lock
            }
        };
        Ok(resource_lock)
    }
}

fn valid_id(id: &str) -> RunnerResult<()> {
    if id.len() != 32
        || !id
            .bytes()
            .all(|v| v.is_ascii_digit() || (b'a'..=b'f').contains(&v))
    {
        return Err(failed("node_resource_id_invalid"));
    }
    Ok(())
}
fn failed(code: &'static str) -> RunnerError {
    RunnerError::new(code, "node journal operation failed")
}
