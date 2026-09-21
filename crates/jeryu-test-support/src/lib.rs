//! Shared helpers for jeryu-ci-runner tests.
//!
//! Test binaries run in parallel (threads within one process, and several
//! processes under nextest-style runners), so a scratch path keyed on
//! `process::id()` alone collides. Every path handed out here combines the pid,
//! a wall-clock nanosecond stamp and a process-wide counter.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// A fresh, not-yet-created path under the system temp dir, named
/// `{prefix}-{pid}-{nanos}-{counter}`. Unique across threads and processes.
pub fn unique_temp_path(prefix: &str) -> PathBuf {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!("{prefix}-{}-{nanos}-{unique}", std::process::id()))
}

/// Like [`unique_temp_path`], but creates the directory. Panics on failure,
/// which is the right behavior inside a test.
pub fn unique_temp_dir(prefix: &str) -> PathBuf {
    let dir = unique_temp_path(prefix);
    std::fs::create_dir_all(&dir)
        .unwrap_or_else(|err| panic!("create per-test directory {}: {err}", dir.display()));
    dir
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn paths_are_distinct_across_threads() {
        let handles: Vec<_> = (0..8)
            .map(|_| {
                std::thread::spawn(|| {
                    (0..64)
                        .map(|_| unique_temp_path("jeryu-ts"))
                        .collect::<Vec<_>>()
                })
            })
            .collect();
        let mut seen = HashSet::new();
        for handle in handles {
            for path in handle.join().unwrap() {
                assert!(seen.insert(path), "duplicate temp path");
            }
        }
        assert_eq!(seen.len(), 8 * 64);
    }

    #[test]
    fn path_carries_prefix_and_pid_under_temp_dir() {
        let path = unique_temp_path("jeryu-ts-prefix");
        assert_eq!(path.parent(), Some(std::env::temp_dir().as_path()));
        let name = path.file_name().unwrap().to_str().unwrap();
        assert!(name.starts_with(&format!("jeryu-ts-prefix-{}-", std::process::id())));
    }

    #[test]
    fn dir_is_created() {
        let dir = unique_temp_dir("jeryu-ts-dir");
        assert!(dir.is_dir());
        std::fs::remove_dir(&dir).unwrap();
    }
}
