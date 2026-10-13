//! Independent cgroup placement and launch ownership, before guest Bind.
use super::*;
use rustix::process::{Pid, PidfdFlags, Signal, pidfd_open, pidfd_send_signal};

struct Writers {
    vmm: OnceLock<Arc<VmmGuard>>,
    launcher: OnceLock<OwnedFd>,
    forced: AtomicBool,
    complete: AtomicBool,
    vm_group: PathBuf,
    launcher_group: PathBuf,
}
impl Writers {
    fn fence(&self) {
        // Neither cgroup failure nor one pidfd failure skips another attempt.
        for group in [&self.vm_group, &self.launcher_group] {
            let _ = fs::write(group.join("cgroup.kill"), "1");
        }
        if let Some(vmm) = self.vmm.get() {
            let _ = vmm.terminate();
        }
        if let Some(launcher) = self.launcher.get() {
            let _ = pidfd_send_signal(launcher, Signal::KILL);
        }
    }
}

pub(super) fn run(
    launch: Launch,
    mut channel: UnixStream,
    jailer: fs::File,
    firecracker: fs::File,
) -> RunnerResult<()> {
    let parent = Path::new("/sys/fs/cgroup/jeryu-guardians");
    fs::create_dir_all(parent)?;
    trusted_directory(parent)?;
    let group = parent.join(&launch.record.resource_id);
    fs::create_dir(&group)?;
    trusted_directory(&group)?;
    // Move the whole guardian process out of the node's service cgroup before
    // spawning. A systemd node-unit stop cannot include this sibling group.
    fs::write(group.join("cgroup.procs"), std::process::id().to_string())?;
    let launcher_group = group.join("launcher");
    fs::create_dir(&launcher_group)?;
    let writers = Arc::new(Writers {
        vmm: OnceLock::new(),
        launcher: OnceLock::new(),
        forced: AtomicBool::new(false),
        complete: AtomicBool::new(false),
        vm_group: Path::new("/sys/fs/cgroup/jeryu-microvm").join(&launch.record.resource_id),
        launcher_group,
    });
    let watcher = writers.clone();
    let mut monitor = channel.try_clone()?;
    monitor.set_nonblocking(true)?;
    let recovery_record = launch.record.clone();
    let recovery_root = launch.jail_root.clone();
    let deadline = launch
        .record
        .deadline
        .clone()
        .ok_or_else(|| failed("microvm_guardian_binding_invalid"))?;
    // Arm before Command::spawn, which itself may block on child setup/exec.
    let timer = std::thread::spawn(move || {
        while !watcher.complete.load(Ordering::Acquire) {
            let mut byte = [0];
            let lost_parent = match monitor.read(&mut byte) {
                Ok(_) => true,
                Err(error) => !matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                ),
            };
            if lost_parent
                || watcher.forced.load(Ordering::Acquire)
                || deadline.expired().unwrap_or(true)
            {
                watcher.forced.store(true, Ordering::Release);
                watcher.fence();
                // Even after expiry or failed cgroup.kill, keep discovering the
                // verified VMM pidfd. An exited jailer parent is insufficient.
                if watcher.vmm.get().is_none()
                    && let Ok(Some(vmm)) = VmmGuard::recover(&recovery_record, &recovery_root)
                {
                    let _ = watcher.vmm.set(Arc::new(vmm));
                }
                watcher.fence();
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    });
    let result = (|| {
        if writers.forced.load(Ordering::Acquire) {
            return Err(failed("microvm_lease_expired"));
        }
        let mut launcher = jeryu_sandbox_linux::microvm::spawn_guarded_jailer_files(
            &jailer,
            &firecracker,
            &launch.arguments,
            &writers.launcher_group.join("cgroup.procs"),
        )?;
        let pid =
            Pid::from_raw(i32::try_from(launcher.id()).map_err(|_| failed("microvm_pid_invalid"))?)
                .ok_or_else(|| failed("microvm_pid_invalid"))?;
        // Child identity comes from our own spawn, never a supplied PID.
        match pidfd_open(pid, PidfdFlags::empty()) {
            Ok(fd) => {
                let _ = writers.launcher.set(fd);
            }
            Err(rustix::io::Errno::SRCH) => (),
            Err(_) => return Err(failed("microvm_pidfd_unavailable")),
        }
        let startup = Instant::now() + Duration::from_secs(60);
        loop {
            if writers.forced.load(Ordering::Acquire) || Instant::now() >= startup {
                return Err(failed("microvm_guardian_boot_timeout"));
            }
            if let Ok(Some(vmm)) = VmmGuard::recover(&launch.record, &launch.jail_root) {
                let vmm = Arc::new(vmm);
                let identity = vmm.identity.clone();
                let _ = writers.vmm.set(vmm);
                // This separate immutable ownership file does not race node
                // journal or checkpoint updates. It commits before readiness.
                let mut file = fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .custom_flags(nix::libc::O_NOFOLLOW)
                    .open(launch.jail_root.join("guardian-vmm.json"))?;
                file.write_all(
                    &serde_json::to_vec(&identity)
                        .map_err(|_| failed("microvm_guardian_record_invalid"))?,
                )?;
                file.sync_all()?;
                fs::File::open(&launch.jail_root)?.sync_all()?;
                write_message(&mut channel, &identity)?;
                break;
            }
            if launcher.try_wait()?.is_some_and(|status| !status.success()) {
                return Err(failed("microvm_guardian_launch_failed"));
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        channel.set_nonblocking(true)?;
        let mut byte = [0];
        loop {
            if writers.forced.load(Ordering::Acquire) {
                break;
            }
            match channel.read(&mut byte) {
                Ok(_) => break, // EOF or unexpected input requests fencing.
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock
                            | std::io::ErrorKind::TimedOut
                            | std::io::ErrorKind::Interrupted
                    ) =>
                {
                    std::thread::sleep(Duration::from_millis(10))
                }
                Err(_) => break,
            }
        }
        Ok(())
    })();
    writers.forced.store(true, Ordering::Release);
    writers.fence();
    // Keep the independent process and timer alive until BOTH launch and VM
    // groups prove empty. A missing PID file cannot authorize early exit.
    loop {
        writers.fence();
        let vmm_dead = writers.vmm.get().is_none_or(|vmm| vmm.wait_dead().is_ok());
        // Launch has completed, and descendants only move from launcher into VM.
        // Confirm launcher empty before sampling VM, avoiding a migration gap.
        let empty =
            [&writers.launcher_group, &writers.vm_group].iter().all(
                |group| match fs::read_to_string(group.join("cgroup.events")) {
                    Ok(events) => events.lines().any(|line| line == "populated 0"),
                    Err(error) => error.kind() == std::io::ErrorKind::NotFound,
                },
            );
        if vmm_dead && empty {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    writers.complete.store(true, Ordering::Release);
    let _ = timer.join();
    // No filesystems, disks or checkpoint keys are handled in this process.
    let _ = fs::remove_dir(&writers.launcher_group);
    fs::write(parent.join("cgroup.procs"), std::process::id().to_string())?;
    let _ = fs::remove_dir(&group);
    result
}
