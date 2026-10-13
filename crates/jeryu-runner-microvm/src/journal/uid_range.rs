//! A node's immutable enrolled range, separate from guest-controlled records.
use super::*;
use crate::custody::{Directory, FileRole, read_bounded};

pub const LEGACY_UID_BASE: u32 = 200000;
const UID_COUNT: u32 = 64;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct UidRange {
    uid_base: u32,
    uid_count: u32,
}

impl UidRange {
    pub fn new(uid_base: u32) -> RunnerResult<Self> {
        if uid_base < 65536
            || uid_base.checked_add(UID_COUNT).is_none()
            || (uid_base != LEGACY_UID_BASE && !uid_base.is_multiple_of(UID_COUNT))
        {
            return Err(failed("node_uid_range_invalid"));
        }
        Ok(Self {
            uid_base,
            uid_count: UID_COUNT,
        })
    }

    pub fn contains(self, uid: u32) -> bool {
        self.ids().contains(&uid)
    }

    pub fn ids(self) -> std::ops::Range<u32> {
        self.uid_base..self.uid_base + UID_COUNT
    }

    fn overlaps(self, start: u32, end: u32) -> bool {
        self.uid_base < end && start < self.uid_base + UID_COUNT
    }

    pub(super) fn enroll(root: &Path, uid_base: u32) -> RunnerResult<Self> {
        let range = Self::new(uid_base)?;
        let directory = Directory::open(root)?;
        let name = Path::new("uid-range.json");
        if directory.entry_exists(name)? {
            let bytes = read_bounded(
                directory.open_file(name, FileRole::Immutable { executable: false }, 1024)?,
                1024,
            )?;
            return decode_enrollment(&bytes, range);
        }
        // Existing legacy records retain their original interpretation. A new
        // range is never retroactively assigned to nonempty state.
        if uid_base != LEGACY_UID_BASE && nonempty(root)? {
            return Err(failed("node_uid_state_not_empty"));
        }
        directory.create_immutable(
            name,
            &serde_json::to_vec(&range).map_err(|_| failed("node_uid_enrollment_invalid"))?,
        )?;
        Ok(range)
    }

    pub(crate) fn read_enrolled(root: &Path) -> RunnerResult<Self> {
        let directory = Directory::open(root)?;
        let bytes = read_bounded(
            directory.open_file(
                Path::new("uid-range.json"),
                FileRole::Immutable { executable: false },
                1024,
            )?,
            1024,
        )?;
        let enrolled: Self =
            serde_json::from_slice(&bytes).map_err(|_| failed("node_uid_enrollment_invalid"))?;
        decode_enrollment(&bytes, Self::new(enrolled.uid_base)?)
    }

    /// A protected host claim remains reserved across node restarts/removal.
    /// The operator must reconcile legacy nodes and task reservations before
    /// creating a claim; this method additionally fences concurrent new nodes.
    pub(crate) fn claim_host(self, root: &Path) -> RunnerResult<()> {
        if self.uid_base == LEGACY_UID_BASE {
            return Ok(());
        }
        if self.overlaps(LEGACY_UID_BASE, LEGACY_UID_BASE + UID_COUNT) {
            return Err(failed("node_uid_range_overlap"));
        }
        let registry = Directory::open(Path::new("/var/lib"))?
            .child_directory(Path::new("jeryu-runtime-uid-reservations"))?;
        let _lock = registry.lock(Path::new("enrollment.lock"))?;
        for uid in self.ids() {
            if nix::unistd::User::from_uid(nix::unistd::Uid::from_raw(uid))
                .map_err(|_| failed("node_uid_inventory_invalid"))?
                .is_some()
                || nix::unistd::Group::from_gid(nix::unistd::Gid::from_raw(uid))
                    .map_err(|_| failed("node_uid_inventory_invalid"))?
                    .is_some()
            {
                return Err(failed("node_uid_range_overlap"));
            }
        }
        for path in ["/etc/subuid", "/etc/subgid"] {
            let bytes = read_bounded(
                crate::custody::open_file(
                    Path::new(path),
                    FileRole::Configuration { private: false },
                    1024 * 1024,
                )?,
                1024 * 1024,
            )?;
            self.reject_subordinate(&bytes)?;
        }
        for name in registry.entries()? {
            if name.extension().is_none_or(|extension| extension != "json") {
                continue;
            }
            let receipt: serde_json::Value = serde_json::from_slice(&read_bounded(
                registry.open_file(&name, FileRole::Immutable { executable: false }, 64 * 1024)?,
                64 * 1024,
            )?)
            .map_err(|_| failed("node_uid_inventory_invalid"))?;
            self.reject_reservations(&receipt, root)?;
        }
        let claims = registry.child_directory(Path::new("nodes"))?;
        let name = std::path::PathBuf::from(format!("{}.json", self.uid_base));
        let expected = HostClaim {
            range: self,
            state_dir: root.to_path_buf(),
        };
        if claims.entry_exists(&name)? {
            let actual: HostClaim = serde_json::from_slice(&read_bounded(
                claims.open_file(&name, FileRole::Immutable { executable: false }, 4096)?,
                4096,
            )?)
            .map_err(|_| failed("node_uid_enrollment_invalid"))?;
            if actual != expected {
                return Err(failed("node_uid_range_overlap"));
            }
        } else {
            // Every nonlegacy block is aligned and exactly 64 IDs: exclusive
            // creation at its base also excludes every overlapping new claim.
            claims.create_immutable(
                &name,
                &serde_json::to_vec(&expected)
                    .map_err(|_| failed("node_uid_enrollment_invalid"))?,
            )?;
        }
        Ok(())
    }

    fn reject_subordinate(self, bytes: &[u8]) -> RunnerResult<()> {
        let text = std::str::from_utf8(bytes).map_err(|_| failed("node_uid_inventory_invalid"))?;
        for line in text.lines().filter(|line| !line.is_empty()) {
            let mut parts = line.split(':');
            let _account = parts
                .next()
                .ok_or_else(|| failed("node_uid_inventory_invalid"))?;
            let start: u32 = parts
                .next()
                .and_then(|s| s.parse().ok())
                .ok_or_else(|| failed("node_uid_inventory_invalid"))?;
            let count: u32 = parts
                .next()
                .and_then(|s| s.parse().ok())
                .ok_or_else(|| failed("node_uid_inventory_invalid"))?;
            let end = start
                .checked_add(count)
                .ok_or_else(|| failed("node_uid_inventory_invalid"))?;
            if parts.next().is_some() || self.overlaps(start, end) {
                return Err(failed("node_uid_range_overlap"));
            }
        }
        Ok(())
    }

    fn reject_reservations(self, receipt: &serde_json::Value, root: &Path) -> RunnerResult<()> {
        if receipt["schema"] != "jeryu.host-uid-reservation.v1" {
            return Err(failed("node_uid_inventory_invalid"));
        }
        let task_root = receipt["task_root"]
            .as_str()
            .map(Path::new)
            .filter(|p| p.is_absolute())
            .ok_or_else(|| failed("node_uid_inventory_invalid"))?;
        for reservation in receipt["reservations"]
            .as_array()
            .ok_or_else(|| failed("node_uid_inventory_invalid"))?
        {
            let start = reservation["start"]
                .as_u64()
                .and_then(|n| u32::try_from(n).ok())
                .ok_or_else(|| failed("node_uid_inventory_invalid"))?;
            let count = reservation["count"]
                .as_u64()
                .and_then(|n| u32::try_from(n).ok())
                .filter(|n| *n > 0)
                .ok_or_else(|| failed("node_uid_inventory_invalid"))?;
            let end = start
                .checked_add(count)
                .ok_or_else(|| failed("node_uid_inventory_invalid"))?;
            // A pre-reserved node block may only be claimed by state beneath
            // that task's protected root. Single-user/producer reservations
            // and reservations belonging to other tasks remain unavailable.
            let own = start == self.uid_base
                && count == UID_COUNT
                && root != task_root
                && root.starts_with(task_root);
            if self.overlaps(start, end) && !own {
                return Err(failed("node_uid_range_overlap"));
            }
        }
        Ok(())
    }
}

fn decode_enrollment(bytes: &[u8], expected: UidRange) -> RunnerResult<UidRange> {
    let enrolled: UidRange =
        serde_json::from_slice(bytes).map_err(|_| failed("node_uid_enrollment_invalid"))?;
    if enrolled != expected {
        return Err(failed("node_uid_enrollment_mismatch"));
    }
    Ok(enrolled)
}

#[derive(PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct HostClaim {
    range: UidRange,
    state_dir: PathBuf,
}

fn nonempty(root: &Path) -> RunnerResult<bool> {
    for entry in std::fs::read_dir(root)? {
        let entry = entry?;
        if entry.file_name() == "node.lock" {
            continue;
        }
        if entry.file_name() == "records"
            && entry.file_type()?.is_dir()
            && std::fs::read_dir(entry.path())?.next().is_none()
        {
            continue;
        }
        return Ok(true);
    }
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn immutable_enrollment_rejects_config_change_broader_blocks_and_corruption() {
        let range = UidRange::new(231104).unwrap();
        let bytes = serde_json::to_vec(&range).unwrap();
        assert_eq!(decode_enrollment(&bytes, range).unwrap(), range);
        assert!(decode_enrollment(&bytes, UidRange::new(231168).unwrap()).is_err());
        for bytes in [
            b"{\"uid_base\":231104,\"uid_count\":128}".as_slice(),
            b"{\"uid_base\":231104,\"uid_count\":64,\"extra\":true}",
            b"{truncated",
        ] {
            assert!(decode_enrollment(bytes, range).is_err());
        }
    }

    #[test]
    fn nonempty_state_cannot_be_treated_as_fresh_enrollment() {
        let temp = tempfile::tempdir().unwrap();
        std::fs::create_dir(temp.path().join("records")).unwrap();
        std::fs::write(temp.path().join("node.lock"), b"").unwrap();
        assert!(!nonempty(temp.path()).unwrap());
        for name in ["records/retained.json", "checkpoint", "quarantine"] {
            std::fs::write(temp.path().join(name), b"retained").unwrap();
            assert!(nonempty(temp.path()).unwrap());
            assert_eq!(std::fs::read(temp.path().join(name)).unwrap(), b"retained");
            std::fs::remove_file(temp.path().join(name)).unwrap();
        }
    }

    #[test]
    fn legacy_and_isolated_ranges_are_exact_and_cannot_overflow() {
        for base in [LEGACY_UID_BASE, 231104] {
            let range = UidRange::new(base).unwrap();
            assert_eq!(range.ids().count(), 64);
            assert!(range.contains(base));
            assert!(range.contains(base + 63));
            assert!(!range.contains(base - 1));
            assert!(!range.contains(base + 64));
        }
        for base in [0, 1000, 231105, u32::MAX, u32::MAX - 63] {
            assert!(UidRange::new(base).is_err());
        }
    }

    #[test]
    fn subordinate_overlaps_bad_inventories_and_adjacent_ranges() {
        let range = UidRange::new(231104).unwrap();
        assert!(
            range
                .reject_subordinate(b"ubuntu:100000:65536\ndeploy:165536:65536\n")
                .is_ok()
        );
        for bytes in [
            b"account:231104:1\n".as_slice(),
            b"account:231100:5\n",
            b"account:0:4294967295\n",
            b"account:4294967295:2\n",
            b"corrupt\n",
            b"account:1:2:3\n",
        ] {
            assert!(range.reject_subordinate(bytes).is_err());
        }
        assert!(!range.overlaps(231168, 231232));
        assert!(!range.overlaps(231040, 231104));
        assert!(range.overlaps(231167, 231168));
    }

    #[test]
    fn protected_task_reservations_fence_other_nodes_and_producer_ids() {
        let receipt = serde_json::json!({"schema":"jeryu.host-uid-reservation.v1", "task_root":"/var/lib/task", "reservations":[{"start":231104,"count":64},{"start":231168,"count":1}]});
        let range = UidRange::new(231104).unwrap();
        assert!(
            range
                .reject_reservations(&receipt, Path::new("/var/lib/task/node"))
                .is_ok()
        );
        for root in [
            "/var/lib/foreign/node",
            "/var/lib/task-other/node",
            "/var/lib/task",
        ] {
            assert!(
                range
                    .reject_reservations(&receipt, Path::new(root))
                    .is_err()
            );
        }
        assert!(
            UidRange::new(231168)
                .unwrap()
                .reject_reservations(&receipt, Path::new("/var/lib/task/node"))
                .is_err()
        );
        assert!(
            range
                .reject_reservations(&serde_json::json!({}), Path::new("/var/lib/task/node"))
                .is_err()
        );
    }
}
