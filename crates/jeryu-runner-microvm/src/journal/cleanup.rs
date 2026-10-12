//! Both cgroup and verified pidfd termination precede any disk deletion.
use super::*;
use std::time::{Duration, Instant};
impl NodeJournal {
    pub(super) fn cleanup_locked(
        &self,
        record: &ResourceRecord,
    ) -> RunnerResult<Option<CheckpointReference>> {
        let owned = self
            .records()?
            .into_iter()
            .find(|owned| owned.resource_id == record.resource_id);
        let Some(owned) = owned else {
            let store = crate::checkpoint::CheckpointStore::open(&self.root)?;
            let bytes = u64::from(record.workspace_gib) * 1024 * 1024 * 1024;
            if let Some(reference) = &record.checkpoint {
                store.authenticate_reference(
                    reference,
                    &record.resource_id,
                    &record.context,
                    bytes,
                    record.workspace_flushed,
                    record.workspace.as_ref(),
                )?;
                return Ok(Some(reference.clone()));
            }
            return store.reference_for_resource(
                &record.resource_id,
                &record.context,
                bytes,
                record.workspace_flushed,
                record.workspace.as_ref(),
            );
        };
        if owned.context != record.context || owned.uid != record.uid {
            return Err(failed("node_cleanup_fenced"));
        }
        let fence = crate::guardian::fence::exclusive(&self.root, &owned)?;
        let mut record = owned;
        // A persisted checkpoint is not proof of recoverable encrypted bytes.
        // Preserve its journal inode on authentication refusal. The exclusive
        // launch fence remains held throughout writer termination and cleanup.
        if record.checkpoint.is_none() && !matches!(record.state, ResourceState::Cleaning) {
            record.state = ResourceState::Cleaning;
            self.write(&record)?;
        }
        // A released exclusive launch fence proves no guardian may spawn.
        // Killing its owned subtree also covers recovery after guardian death.
        let guardian = PathBuf::from("/sys/fs/cgroup/jeryu-guardians").join(&record.resource_id);
        if guardian.exists() {
            let group_result = std::fs::write(guardian.join("cgroup.kill"), "1");
            let _ = group_result; // verified empty below; VM pidfd still runs.
        }
        let cgroup = PathBuf::from("/sys/fs/cgroup/jeryu-microvm").join(&record.resource_id);
        let vmm = crate::vmm::VmmGuard::recover(&record, &self.jail_root(&record.resource_id)?);
        kill_writers(
            || {
                if cgroup.exists() {
                    std::fs::write(cgroup.join("cgroup.kill"), "1")?;
                }
                Ok(())
            },
            || {
                if let Some(vmm) = vmm? {
                    vmm.terminate()?;
                    vmm.wait_dead()?;
                }
                Ok(())
            },
            || {
                wait_empty(&guardian)?;
                wait_empty(&cgroup)
            },
        )?;
        if cgroup.exists() {
            std::fs::remove_dir(&cgroup)?;
        }
        if guardian.exists() {
            let launcher = guardian.join("launcher");
            if launcher.exists() {
                std::fs::remove_dir(launcher)?;
            }
            std::fs::remove_dir(&guardian)?;
        }
        // VMM death fences every writer. Retention must commit before deletion;
        // an encryption/storage failure leaves the disk and retry record intact.
        if record.retain_workspace && record.checkpoint.is_none() {
            let store = crate::checkpoint::CheckpointStore::open(&self.root)?;
            let bytes = u64::from(record.workspace_gib) * 1024 * 1024 * 1024;
            let image = crate::custody::Directory::open(&self.root)
                .and_then(|root| root.descend(Path::new("j/firecracker")))
                .and_then(|parent| parent.open_directory(Path::new(&record.resource_id)))
                .and_then(|directory| directory.open_workspace(record.uid, bytes))
                .map_err(|_| crate::checkpoint::workspace_custody_denied())?;
            record.checkpoint = Some(store.retain(
                &record.resource_id,
                &record.context,
                crate::checkpoint::RetainedDisk {
                    image,
                    uid: record.uid,
                    bytes,
                    filesystem_flushed: record.workspace_flushed,
                    workspace: record.workspace.as_ref(),
                },
            )?);
            self.write(&record)?;
        }
        if let Some(reference) = &record.checkpoint {
            crate::checkpoint::CheckpointStore::open(&self.root)?.authenticate_reference(
                reference,
                &record.resource_id,
                &record.context,
                u64::from(record.workspace_gib) * 1024 * 1024 * 1024,
                record.workspace_flushed,
                record.workspace.as_ref(),
            )?;
        }
        // Opaque guest disks are removed as files. They are never mounted here.
        let jail = self
            .jail_root(&record.resource_id)?
            .parent()
            .ok_or_else(|| failed("node_journal_invalid"))?
            .to_path_buf();
        match std::fs::remove_dir_all(jail) {
            Ok(()) => (),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
            Err(e) => return Err(e.into()),
        }
        crate::guardian::fence::remove(&self.root, &record, fence.as_ref())?;
        std::fs::remove_file(
            self.root
                .join("records")
                .join(format!("{}.json", record.resource_id)),
        )?;
        File::open(self.root.join("records"))?.sync_all()?;
        Ok(record.checkpoint)
    }
}

fn kill_writers(
    cgroup: impl FnOnce() -> RunnerResult<()>,
    vmm: impl FnOnce() -> RunnerResult<()>,
    verify_empty: impl FnOnce() -> RunnerResult<()>,
) -> RunnerResult<()> {
    let group_result = cgroup();
    // Neither kill attempt short-circuits the other. Verification also runs.
    let vm_result = vmm();
    let empty_result = verify_empty();
    vm_result?;
    empty_result?;
    if group_result.is_err() {
        eprintln!("jeryu_microvm_cleanup_recovered code=microvm_cgroup_kill_failed");
    }
    Ok(())
}
fn wait_empty(cgroup: &Path) -> RunnerResult<()> {
    if !cgroup.exists() {
        return Ok(());
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let events = std::fs::read_to_string(cgroup.join("cgroup.events"))?;
        if events.lines().any(|v| v == "populated 0") {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(failed("microvm_cleanup_timeout"));
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[cfg(test)]
mod native;

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    #[test]
    fn cgroup_failure_still_terminates_vmm_and_never_authorizes_live_disk_deletion() {
        let killed = Cell::new(false);
        let result = kill_writers(
            || Err(failed("injected_cgroup_failure")),
            || {
                killed.set(true);
                Ok(())
            },
            || Err(failed("microvm_cleanup_timeout")),
        );
        assert!(killed.get());
        assert_eq!(result.unwrap_err().code(), "microvm_cleanup_timeout");
        kill_writers(
            || Err(failed("injected_cgroup_failure")),
            || Ok(()),
            || Ok(()),
        )
        .unwrap();
        assert!(
            kill_writers(
                || Ok(()),
                || Err(failed("microvm_process_uid_denied")),
                || Ok(())
            )
            .is_err()
        );
    }
}
