//! A persisted CLOCK_BOOTTIME ceiling survives rollback and counts suspension.
use super::*;
use rustix::time::{ClockId, clock_gettime};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Deadline {
    boot_id: String,
    boottime_millis: u64,
    signed_expiry_millis: u64,
}
impl Deadline {
    pub(crate) fn new(expiry: u64) -> RunnerResult<Self> {
        // Sample the boot clock first: time spent reading UTC cannot extend it.
        Self::from_observations(boot_id()?, boottime()?, walltime()?, expiry)
    }
    fn from_observations(boot_id: String, boot: u64, wall: u64, expiry: u64) -> RunnerResult<Self> {
        let remaining = expiry
            .checked_sub(wall)
            .and_then(|ms| ms.checked_sub(1000))
            .filter(|ms| *ms > 0)
            .ok_or_else(|| failed("microvm_lease_expired"))?;
        Ok(Self {
            boot_id,
            boottime_millis: boot
                .checked_add(remaining)
                .ok_or_else(|| failed("microvm_clock_invalid"))?,
            signed_expiry_millis: expiry,
        })
    }
    pub(crate) fn expired(&self) -> RunnerResult<bool> {
        Ok(self.expired_at(&boot_id()?, boottime()?, walltime()?))
    }
    fn expired_at(&self, boot_id: &str, boot: u64, wall: u64) -> bool {
        self.boot_id != boot_id
            || boot >= self.boottime_millis
            || wall >= self.signed_expiry_millis.saturating_sub(1000)
    }
    pub(crate) fn matches(&self, expiry: u64) -> bool {
        self.signed_expiry_millis == expiry
    }
}
fn boot_id() -> RunnerResult<String> {
    Ok(std::fs::read_to_string("/proc/sys/kernel/random/boot_id")?
        .trim()
        .into())
}
fn boottime() -> RunnerResult<u64> {
    let time = clock_gettime(ClockId::Boottime);
    u64::try_from(time.tv_sec)
        .ok()
        .and_then(|sec| sec.checked_mul(1000))
        .and_then(|ms| ms.checked_add(u64::try_from(time.tv_nsec).ok()? / 1_000_000))
        .ok_or_else(|| failed("microvm_clock_invalid"))
}
fn walltime() -> RunnerResult<u64> {
    u64::try_from(jeryu_runner_core::receipt::now_ms()).map_err(|_| failed("microvm_clock_invalid"))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn persisted_ceiling_never_extends_for_rollback_restart_or_suspend() {
        let deadline = Deadline::from_observations("boot-a".into(), 5000, 10000, 15000).unwrap();
        let restarted: Deadline =
            serde_json::from_slice(&serde_json::to_vec(&deadline).unwrap()).unwrap();
        assert!(!restarted.expired_at("boot-a", 8999, 1));
        assert!(restarted.expired_at("boot-a", 9000, 1));
        assert!(restarted.expired_at("boot-a", 5001, 14000));
        assert!(restarted.expired_at("boot-b", 1, 1));
        assert!(Deadline::from_observations("boot-a".into(), 0, 10000, 11000).is_err());
        assert!(Deadline::from_observations("boot-a".into(), u64::MAX, 0, 2000).is_err());
    }
}
