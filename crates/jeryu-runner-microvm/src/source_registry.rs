//! K4 accepts opaque, digest-bound source bytes only. No guest filesystem is
//! mounted or parsed here; Git bundle verification remains inside the guest.
mod custody;
mod staging;
mod verify;
use crate::{
    custody::{Directory, FileRole},
    supervisor::{HostStorageReservation, Node},
};
use jeryu_runner_core::{RunnerError, RunnerResult};
use jeryu_runner_protocol::wire::v2::{
    ArtifactIdentity, BundleRegistered, BundleUpload, PROTOCOL_VERSION,
};
use nix::fcntl::Flock;
use std::{
    fs::File,
    io::Write,
    os::unix::fs::PermissionsExt,
    path::Path,
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
    root: Directory,
    staging: Directory,
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
        let root = custody::directory(root)?;
        node.require_storage_directory(&root)?;
        let staging = custody::staging_directory(&root)?;
        let lock = staging
            .lock(Path::new("registry.lock"))
            .map_err(|_| failed("bundle_registry_already_running"))?;
        let clean = staging::reconcile(&staging)?;
        let (bytes, objects) = custody::inventory(&root)?;
        if !clean {
            eprintln!("jeryu_bundle_registry_reconciliation_required");
        }
        Ok(Arc::new(Self {
            root,
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
                // Creation did not prove ownership of a data file. Preserve
                // ambiguous entries rather than deleting a colliding leaf.
                self.clean.store(false, Ordering::Release);
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
    pub fn finish(self) -> RunnerResult<BundleRegistered> {
        self.finish_with_sync(|file, directory, staging, root| {
            file.sync_all()?;
            directory.sync()?;
            staging.sync()?;
            root.sync()
        })
    }

    fn finish_with_sync(
        mut self,
        sync: impl FnOnce(&File, &Directory, &Directory, &Directory) -> RunnerResult<()>,
    ) -> RunnerResult<BundleRegistered> {
        self.verifier.finish()?;
        let file = self
            .file
            .as_mut()
            .ok_or_else(|| failed("bundle_upload_closed"))?;
        file.sync_all()?;
        // Verify the bytes actually written through this same descriptor,
        // rather than treating the body-stream hash as a disk receipt.
        verify::file(file, &self.upload)?;
        file.set_permissions(std::fs::Permissions::from_mode(0o444))?;
        file.sync_all()?;
        crate::custody::verify_file(
            file,
            FileRole::Immutable { executable: false },
            self.upload.stored_bytes,
        )
        .map_err(|_| failed("bundle_staging_custody_denied"))?;
        let digest = &self.upload.digest[7..];
        let directory = self
            .registry
            .root
            .child_directory(Path::new(digest))
            .map_err(|_| failed("bundle_registry_custody_denied"))?;
        let target = Path::new("source-bundle");
        if self
            .registry
            .staging
            .promote_file(
                Path::new(&format!("{}.bin", self.id)),
                file,
                &directory,
                target,
            )
            .map_err(|_| failed("bundle_staging_custody_denied"))?
        {
            // Once renamed, keep the quota charge even if identity/sync fails.
            self.retained = true;
            directory.require_file_identity(target, file)?;
            sync(
                file,
                &directory,
                &self.registry.staging,
                &self.registry.root,
            )?;
        } else {
            let mut existing = directory
                .open_file(
                    target,
                    FileRole::Immutable { executable: false },
                    self.upload.stored_bytes,
                )
                .map_err(|_| failed("bundle_registry_collision"))?;
            verify::file(&mut existing, &self.upload)
                .map_err(|_| failed("bundle_registry_collision"))?;
            // A duplicate may be retrying an earlier promotion whose parent
            // sync failed. Do not return a registration until it is durable.
            sync(
                &existing,
                &directory,
                &self.registry.staging,
                &self.registry.root,
            )?;
        }
        staging::discard(
            &self.registry.staging,
            &self.id,
            self.file.as_ref(),
            self.retained,
        )?;
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
        let clean = self.discarded
            || staging::discard(
                &self.registry.staging,
                &self.id,
                self.file.as_ref(),
                self.retained,
            )
            .is_ok();
        self.file.take();
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

#[cfg(test)]
mod tests;
