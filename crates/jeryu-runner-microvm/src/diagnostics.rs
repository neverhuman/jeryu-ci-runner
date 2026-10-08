//! VM-owned FIFO drains keep VMM diagnostics from filling guest disks or blocking
//! the VM. Raw records are discarded; production telemetry integration is pending.
use jeryu_runner_core::RunnerResult;
use nix::unistd::{Gid, Uid, chown, mkfifo};
use std::{
    fs::OpenOptions,
    io::Read,
    os::unix::fs::OpenOptionsExt,
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

pub(crate) struct DiagnosticDrain(Arc<AtomicBool>);

impl DiagnosticDrain {
    pub(crate) fn cancellation(&self) -> Arc<AtomicBool> {
        self.0.clone()
    }
    pub(crate) fn open(path: &Path, uid: u32) -> RunnerResult<Self> {
        mkfifo(path, nix::sys::stat::Mode::from_bits_truncate(0o600))
            .map_err(std::io::Error::from)?;
        chown(path, Some(Uid::from_raw(uid)), Some(Gid::from_raw(uid)))
            .map_err(std::io::Error::from)?;
        // Read/write keeps a reader present before Firecracker opens its writer.
        let mut pipe = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(nix::libc::O_NONBLOCK | nix::libc::O_NOFOLLOW)
            .open(path)?;
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        std::thread::spawn(move || {
            let mut bytes = [0; 8192];
            while !stopped.load(Ordering::Acquire) {
                match pipe.read(&mut bytes) {
                    Ok(0) => std::thread::sleep(Duration::from_millis(10)),
                    Ok(_) => (),
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(10));
                    }
                    Err(_) => break,
                }
            }
        });
        Ok(Self(stop))
    }
}

impl Drop for DiagnosticDrain {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
    }
}
