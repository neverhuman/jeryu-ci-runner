//! Upload staging shares the VM's physical reservation boundary. Once a file
//! is published its allocated blocks are charged by statvfs, not promised twice.
use super::*;
use std::path::Path;
use std::sync::atomic::Ordering;

pub struct HostStorageReservation {
    node: Arc<Node>,
    bytes: u64,
}

impl Node {
    pub fn require_storage_filesystem(&self, path: &Path) -> RunnerResult<()> {
        self.require_storage_directory(&crate::custody::Directory::open(path)?)
    }

    pub(crate) fn require_storage_directory(
        &self,
        directory: &crate::custody::Directory,
    ) -> RunnerResult<()> {
        let state = crate::custody::Directory::open(&self.config.state_dir)?;
        if directory.device()? != state.device()? {
            return Err(failed("bundle_registry_filesystem_mismatch"));
        }
        Ok(())
    }

    pub fn reserve_host_storage(
        self: &Arc<Self>,
        bytes: u64,
    ) -> RunnerResult<HostStorageReservation> {
        if bytes == 0 || bytes > (1 << 30) + 65536 {
            return Err(failed("bundle_storage_reservation_invalid"));
        }
        let _admission = self
            .admission
            .lock()
            .map_err(|_| failed("node_journal_unavailable"))?;
        self.journal.require_clean_admission()?;
        let total = self
            .upload_reserved_bytes
            .load(Ordering::Acquire)
            .checked_add(bytes)
            .ok_or_else(|| failed("bundle_storage_reservation_invalid"))?;
        admission::check_free_space(
            &self.journal,
            &self.config.state_dir,
            &self.journal.records()?,
            u128::from(total),
        )?;
        self.upload_reserved_bytes
            .fetch_add(bytes, Ordering::AcqRel);
        Ok(HostStorageReservation {
            node: self.clone(),
            bytes,
        })
    }
}

impl Drop for HostStorageReservation {
    fn drop(&mut self) {
        self.node
            .upload_reserved_bytes
            .fetch_sub(self.bytes, Ordering::AcqRel);
    }
}
