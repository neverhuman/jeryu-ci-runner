//! K4 accepts opaque, digest-bound source bytes only. No guest filesystem is
//! mounted or parsed here; Git bundle verification remains inside the guest.
mod custody;
mod staging;
mod verify;
use crate::{
    artifacts::trusted_directory,
    supervisor::{HostStorageReservation, Node},
};
use jeryu_runner_core::{RunnerError, RunnerResult};
use jeryu_runner_protocol::wire::v2::{
    ArtifactIdentity, BundleRegistered, BundleUpload, PROTOCOL_VERSION,
};
use nix::fcntl::{Flock, FlockArg};
use std::{
    fs::{File, OpenOptions},
    io::Write,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};

const OBJECT_LIMIT: usize = 4096;
const METADATA_CHARGE: u64 = 65536;
struct Usage {
    bytes: u64,
    objects: usize,
    active: usize,
}
pub struct SourceBundleRegistry {
    root: PathBuf,
    staging: PathBuf,
    node: Arc<Node>,
    budget_bytes: u64,
    usage: Mutex<Usage>,
    clean: AtomicBool,
    _lock: Flock<File>,
}

impl SourceBundleRegistry {
    pub fn open(root: &Path, budget_gib: u32, node: Arc<Node>) -> RunnerResult<Arc<Self>> {
        if !(1..=64).contains(&budget_gib) {
            return Err(failed("bundle_registry_budget_invalid"));
        }
        node.require_storage_filesystem(root)?;
        let staging = root.join(".source-staging");
        custody::private_directory(&staging)?;
        let file = custody::private_file(&staging.join("registry.lock"), true)?;
        let lock = Flock::lock(file, FlockArg::LockExclusiveNonblock)
            .map_err(|_| failed("bundle_registry_already_running"))?;
        let clean = staging::reconcile(&staging)?;
        let (bytes, objects) = custody::inventory(root)?;
        if !clean {
            eprintln!("jeryu_bundle_registry_reconciliation_required");
        }
        Ok(Arc::new(Self {
            root: root.into(),
            staging,
            node,
            budget_bytes: u64::from(budget_gib) << 30,
            usage: Mutex::new(Usage {
                bytes,
                objects,
                active: 0,
            }),
            clean: AtomicBool::new(clean),
            _lock: lock,
        }))
    }

    pub fn begin(self: &Arc<Self>, upload: BundleUpload) -> RunnerResult<UploadStage> {
        upload
            .validate()
            .map_err(|_| failed("bundle_upload_invalid"))?;
        if !self.clean.load(Ordering::Acquire) {
            return Err(failed("bundle_registry_reconciliation_required"));
        }
        let charge = upload.stored_bytes + METADATA_CHARGE;
        // Quota reservation is atomic with registration. No lock stays held
        // during body reads, disk writes, hashing, or VM boot.
        let mut usage = self
            .usage
            .lock()
            .map_err(|_| failed("bundle_registry_unavailable"))?;
        if usage.active >= 4
            || usage.objects >= OBJECT_LIMIT
            || usage.bytes.saturating_add(charge) > self.budget_bytes
        {
            return Err(failed("bundle_registry_capacity_unavailable"));
        }
        let reservation = self.node.reserve_host_storage(charge)?;
        let id = uuid::Uuid::new_v4().simple().to_string();
        let file = match staging::create(&self.staging, &id, &upload) {
            Ok(file) => file,
            Err(error) => {
                // The journal was written before creating the data file.
                if staging::discard(&self.staging, &id).is_err() {
                    self.clean.store(false, Ordering::Release);
                }
                return Err(error);
            }
        };
        usage.bytes += charge;
        usage.objects += 1;
        usage.active += 1;
        drop(usage);
        Ok(UploadStage {
            registry: self.clone(),
            id,
            verifier: verify::Verifier::new(&upload),
            upload,
            file: Some(file),
            _reservation: reservation,
            retained: false,
            discarded: false,
        })
    }
}

pub struct UploadStage {
    registry: Arc<SourceBundleRegistry>,
    id: String,
    upload: BundleUpload,
    verifier: verify::Verifier,
    file: Option<File>,
    _reservation: HostStorageReservation,
    retained: bool,
    discarded: bool,
}
impl UploadStage {
    pub fn write_chunk(&mut self, bytes: &[u8]) -> RunnerResult<()> {
        self.verifier.push(bytes)?;
        self.file
            .as_mut()
            .ok_or_else(|| failed("bundle_upload_closed"))?
            .write_all(bytes)?;
        Ok(())
    }
    pub fn finish(mut self) -> RunnerResult<BundleRegistered> {
        self.verifier.finish()?;
        let file = self
            .file
            .take()
            .ok_or_else(|| failed("bundle_upload_closed"))?;
        file.sync_all()?;
        file.set_permissions(std::fs::Permissions::from_mode(0o444))?;
        file.sync_all()?;
        drop(file);
        let digest = &self.upload.digest[7..];
        let directory = self.registry.root.join(digest);
        match std::fs::create_dir(&directory) {
            Ok(()) => std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o755))?,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => (),
            Err(error) => return Err(error.into()),
        }
        trusted_directory(&directory)?;
        let target = directory.join("source-bundle");
        match rustix::fs::renameat_with(
            rustix::fs::CWD,
            self.registry.staging.join(format!("{}.bin", self.id)),
            rustix::fs::CWD,
            &target,
            rustix::fs::RenameFlags::NOREPLACE,
        ) {
            Ok(()) => {
                // Once renamed, keep the quota charge even if fsync fails.
                self.retained = true;
                File::open(&directory)?.sync_all()?;
                File::open(&self.registry.root)?.sync_all()?;
            }
            Err(rustix::io::Errno::EXIST) => {
                let mut existing = crate::artifacts::trusted_file(&target, false)?;
                if existing.metadata()?.len() != self.upload.stored_bytes
                    || crate::artifacts::sha256_reader(&mut existing)? != self.upload.digest
                {
                    return Err(failed("bundle_registry_collision"));
                }
            }
            Err(error) => return Err(std::io::Error::from(error).into()),
        }
        staging::discard(&self.registry.staging, &self.id)?;
        self.discarded = true;
        Ok(BundleRegistered {
            protocol_version: PROTOCOL_VERSION.into(),
            message_type: "bundle-registered".into(),
            request_id: self.upload.request_id.clone(),
            role: self.upload.role,
            artifact: ArtifactIdentity {
                artifact_id: format!("bundle-{}", &digest[..32]),
                digest: self.upload.digest.clone(),
            },
            bundle_bytes: self.upload.bundle_bytes,
            stored_bytes: self.upload.stored_bytes,
        })
    }
}
impl Drop for UploadStage {
    fn drop(&mut self) {
        self.file.take();
        let clean = self.discarded || staging::discard(&self.registry.staging, &self.id).is_ok();
        if !clean {
            self.registry.clean.store(false, Ordering::Release);
            eprintln!("jeryu_bundle_registry_reconciliation_required");
        }
        if let Ok(mut usage) = self.registry.usage.lock() {
            usage.active = usage.active.saturating_sub(1);
            if !self.retained && clean {
                usage.bytes = usage
                    .bytes
                    .saturating_sub(self.upload.stored_bytes + METADATA_CHARGE);
                usage.objects = usage.objects.saturating_sub(1);
            }
        } else {
            self.registry.clean.store(false, Ordering::Release);
        }
    }
}
fn failed(code: &'static str) -> RunnerError {
    RunnerError::new(code, "source bundle registration failed")
}
