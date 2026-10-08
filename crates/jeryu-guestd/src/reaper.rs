//! PID 1 owns all waits, including orphaned grandchildren. Registration and
//! waitpid share a lock so an immediately exiting child cannot lose its result.
use nix::{
    sys::wait::{WaitPidFlag, WaitStatus, waitpid},
    unistd::Pid,
};
use std::{
    collections::BTreeMap,
    process::Child,
    sync::{Arc, Mutex},
    time::Duration,
};

type Results = Arc<Mutex<BTreeMap<i32, Option<Option<i32>>>>>;
#[derive(Clone)]
pub struct Reaper(Results);

impl Reaper {
    pub fn start() -> Self {
        let results = Arc::new(Mutex::new(BTreeMap::new()));
        let reaper = Self(results.clone());
        std::thread::spawn(move || {
            loop {
                if let Ok(mut results) = results.lock() {
                    for _ in 0..128 {
                        let (pid, code) =
                            match waitpid(Pid::from_raw(-1), Some(WaitPidFlag::WNOHANG)) {
                                Ok(WaitStatus::Exited(pid, code)) => (pid, Some(code)),
                                Ok(WaitStatus::Signaled(pid, _, _)) => (pid, None),
                                _ => break,
                            };
                        if let Some(result) = results.get_mut(&pid.as_raw()) {
                            *result = Some(code);
                        }
                    }
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        });
        reaper
    }

    pub fn spawn(&self, spawn: impl FnOnce() -> std::io::Result<Child>) -> std::io::Result<Pid> {
        let mut results = self
            .0
            .lock()
            .map_err(|_| std::io::Error::other("guest_reaper_failed"))?;
        let child = spawn()?;
        let pid = Pid::from_raw(
            i32::try_from(child.id()).map_err(|_| std::io::Error::other("guest_pid_invalid"))?,
        );
        results.insert(pid.as_raw(), None);
        Ok(pid)
    }

    pub fn result(&self, pid: Pid) -> Option<Option<i32>> {
        let mut results = self.0.lock().ok()?;
        let code = results.get(&pid.as_raw()).copied().flatten()?;
        results.remove(&pid.as_raw());
        Some(code)
    }
}
