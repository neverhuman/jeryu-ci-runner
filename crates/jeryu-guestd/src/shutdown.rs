//! Trusted PID-1 timer independent of guest requests, node threads and write
//! locks. Its anchor precedes listener publication and consumes boot/setup time.
use std::{
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

struct Deadline {
    boot: Instant,
    deadline: Instant,
    bound: bool,
}
impl Deadline {
    fn new(boot: Instant) -> Self {
        Self {
            boot,
            deadline: boot + Duration::from_secs(20),
            bound: false,
        }
    }
    fn bind(&mut self, remaining: u32) -> std::io::Result<()> {
        let deadline = self.boot + Duration::from_millis(u64::from(remaining));
        if self.bound
            || remaining == 0
            || Instant::now() >= self.deadline
            || Instant::now() >= deadline
        {
            return Err(std::io::Error::other("guest_lease_deadline_invalid"));
        }
        self.deadline = deadline;
        self.bound = true;
        Ok(())
    }
}
pub struct Guard(Arc<Mutex<Deadline>>);
impl Guard {
    pub fn start() -> std::io::Result<Self> {
        guest_only()?;
        let state = Arc::new(Mutex::new(Deadline::new(Instant::now())));
        let timer = state.clone();
        std::thread::Builder::new()
            .name("guest-lease-shutdown".into())
            .spawn(move || {
                loop {
                    let remaining = match timer.lock() {
                        Ok(state) => state.deadline.saturating_duration_since(Instant::now()),
                        Err(_) => Duration::ZERO,
                    };
                    if remaining.is_zero() {
                        stop();
                    }
                    std::thread::sleep(remaining.min(Duration::from_millis(50)));
                }
            })
            .map_err(|_| std::io::Error::other("guest_shutdown_timer_failed"))?;
        Ok(Self(state))
    }
    pub fn bind(&self, remaining: u32) -> std::io::Result<()> {
        self.0
            .lock()
            .map_err(|_| std::io::Error::other("guest_shutdown_timer_failed"))?
            .bind(remaining)
    }
}
fn guest_only() -> std::io::Result<()> {
    if std::process::id() != 1 {
        return Err(std::io::Error::other("guest_pid1_required"));
    }
    Ok(())
}
fn terminate_vm() -> std::io::Result<()> {
    guest_only()?;
    // Firecracker x86 has no ACPI power-off. With the launcher's reboot=k,
    // guest reset exits the VMM instead of leaving a halted VM allocated.
    nix::sys::reboot::reboot(nix::sys::reboot::RebootMode::RB_AUTOBOOT)
        .map(|never| match never {})
        .map_err(|_| std::io::Error::other("guest_vm_reset_failed"))
}
pub fn stop() -> ! {
    if guest_only().is_err() {
        // Accidental host invocation cannot reach a reboot syscall.
        std::process::exit(1);
    }
    loop {
        let _ = terminate_vm();
        // A failed platform shutdown must not resume execution. Host watchdog
        // and journal recovery remain mandatory even with this guest guard.
        std::thread::sleep(Duration::from_secs(1));
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn slow_bind_consumes_boot_budget_and_never_restarts_at_ready() {
        let boot = Instant::now() - Duration::from_millis(100);
        let mut state = Deadline::new(boot);
        state.bind(200).unwrap();
        assert_eq!(state.deadline, boot + Duration::from_millis(200));
        assert!(
            state.deadline.saturating_duration_since(Instant::now()) <= Duration::from_millis(100)
        );
        assert!(state.bind(300).is_err());
        assert!(Deadline::new(boot).bind(1).is_err());
        assert!(
            Deadline::new(Instant::now() - Duration::from_secs(21))
                .bind(60000)
                .is_err()
        );
    }
    #[test]
    fn host_processes_cannot_start_timer_or_reset() {
        assert_ne!(std::process::id(), 1);
        assert_eq!(
            terminate_vm().unwrap_err().to_string(),
            "guest_pid1_required"
        );
        assert!(Guard::start().is_err());
    }
}
