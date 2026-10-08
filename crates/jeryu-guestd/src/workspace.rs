//! Read-only source import and real main synchronization; all Git runs in guest.
use jeryu_runner_protocol::wire::v2::{
    SessionLease, WorkspaceReady, WorkspaceSource, WorkspaceSyncState,
};
mod authority;
mod git;
use git::run as git;
pub use git::{configure as configure_git, diagnostic as git_diagnostic};
use nix::{
    sys::stat::{Mode, SFlag, makedev, mknod},
    unistd::{Gid, Uid, chown},
};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::OpenOptionsExt,
    path::Path,
};

pub fn prepare(lease: &SessionLease) -> std::io::Result<Option<WorkspaceReady>> {
    lease
        .validate()
        .map_err(|_| failed("guest_lease_invalid"))?;
    let WorkspaceSource::GitBundle {
        bundle,
        bundle_bytes,
        main_revision,
        base_revision,
    } = &lease.workspace
    else {
        return Ok(None);
    };
    let device = fs::read_to_string("/sys/class/block/vdc/dev")
        .map_err(|_| failed("guest_source_device_missing"))?;
    let (major, minor) = device
        .trim()
        .split_once(':')
        .and_then(|(major, minor)| Some((major.parse::<u64>().ok()?, minor.parse::<u64>().ok()?)))
        .filter(|(major, minor)| *major < 4096 && *minor < (1 << 20))
        .ok_or_else(|| failed("guest_source_device_invalid"))?;
    mknod(
        "/dev/vdc",
        SFlag::S_IFBLK,
        Mode::from_bits_truncate(0o400),
        makedev(major, minor),
    )
    .map_err(|_| failed("guest_source_device_invalid"))?;
    let source_path = Path::new("/workspace/source.bundle");
    if lease.checkpoint.is_some() {
        match fs::remove_file(source_path) {
            Ok(()) => (),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
            Err(error) => return Err(error),
        }
    }
    let mut source = OpenOptions::new()
        .write(true)
        .create_new(true)
        .custom_flags(nix::libc::O_NOFOLLOW)
        .open(source_path)?;
    let mut disk = File::open("/dev/vdc")?.take(bundle_bytes.div_ceil(512) * 512);
    let mut hash = Sha256::new();
    let mut copied = 0_u64;
    let mut buffer = [0; 64 * 1024];
    loop {
        let length = disk.read(&mut buffer)?;
        if length == 0 {
            break;
        }
        hash.update(&buffer[..length]);
        let write_length = u64::try_from(length)
            .unwrap_or(0)
            .min(bundle_bytes.saturating_sub(copied));
        source.write_all(&buffer[..write_length as usize])?;
        copied += length as u64;
    }
    let digest: String = hash
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    if copied != bundle_bytes.div_ceil(512) * 512 || format!("sha256:{digest}") != bundle.digest {
        return Err(failed("guest_source_digest_mismatch"));
    }
    source.sync_all()?;
    drop(source);
    let repo = Path::new("/workspace/repo");
    let restored = lease.checkpoint.is_some();
    if !restored {
        fs::create_dir(repo)?;
        chown(repo, Some(Uid::from_raw(1000)), Some(Gid::from_raw(1000)))
            .map_err(|_| failed("guest_source_identity_failed"))?;
    } else if git(repo, &["rev-parse", "--verify", "HEAD"])?.trim() != lease.context.source_revision
    {
        return receipt(
            lease,
            repo,
            main_revision,
            WorkspaceSyncState::RebaseRequired,
        );
    }
    let object_format = if lease.context.source_revision.len() == 64 {
        "--object-format=sha256"
    } else {
        "--object-format=sha1"
    };
    if !restored {
        git(repo, &["init", "-q", object_format])?;
    }
    git(repo, &["bundle", "verify", "/workspace/source.bundle"])?;
    git(
        repo,
        &[
            "fetch",
            "-q",
            "--no-tags",
            "/workspace/source.bundle",
            "+refs/jeryu/source:refs/jeryu-import/source",
            "+refs/jeryu/main:refs/jeryu-import/main",
            "+refs/jeryu/base:refs/jeryu-import/base",
        ],
    )?;
    for (reference, expected) in [
        ("refs/jeryu-import/source", &lease.context.source_revision),
        ("refs/jeryu-import/main", main_revision),
        ("refs/jeryu-import/base", base_revision),
    ] {
        if reference == "refs/jeryu-import/source" && restored {
            continue;
        }
        if git(repo, &["rev-parse", "--verify", reference])?.trim() != expected {
            return Err(failed("guest_source_revision_mismatch"));
        }
    }
    git(
        repo,
        &[
            "merge-base",
            "--is-ancestor",
            base_revision,
            &lease.context.source_revision,
        ],
    )?;
    if !restored
        || (!repo.join(".git/rebase-merge").exists() && !repo.join(".git/rebase-apply").exists())
    {
        let session_hash: String = Sha256::digest(lease.context.session_id.as_bytes())
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let branch = format!("jeryu/session/{session_hash}/g{}", lease.context.generation);
        git(
            repo,
            &[
                "checkout",
                "-q",
                "-B",
                &branch,
                &lease.context.source_revision,
            ],
        )?;
    }
    if repo.join(".git/rebase-merge").exists()
        || repo.join(".git/rebase-apply").exists()
        || !git(repo, &["diff", "--name-only", "--diff-filter=U", "-z"])?.is_empty()
    {
        return receipt(
            lease,
            repo,
            main_revision,
            WorkspaceSyncState::RebaseRequired,
        );
    }
    let dirty = !git(
        repo,
        &[
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
            "--ignored=matching",
        ],
    )?
    .is_empty();
    let stash = if dirty {
        git(
            repo,
            &["stash", "push", "--all", "--message", "jeryu-main-sync"],
        )?;
        Some(
            git(repo, &["rev-parse", "--verify", "refs/stash"])?
                .trim()
                .to_owned(),
        )
    } else {
        None
    };
    if git(
        repo,
        &["rebase", "--quiet", "--onto", main_revision, base_revision],
    )
    .is_err()
    {
        if repo.join(".git/rebase-merge").exists() || repo.join(".git/rebase-apply").exists() {
            return receipt(
                lease,
                repo,
                main_revision,
                WorkspaceSyncState::RebaseRequired,
            );
        }
        return Err(failed("guest_main_sync_failed"));
    }
    git(
        repo,
        &["merge-base", "--is-ancestor", main_revision, "HEAD"],
    )?;
    if let Some(stash) = stash {
        if git(repo, &["stash", "apply", "--index", &stash]).is_err() {
            return receipt(
                lease,
                repo,
                main_revision,
                WorkspaceSyncState::RebaseRequired,
            );
        }
        git(repo, &["stash", "drop", "--quiet"])?;
    }
    fs::remove_file(source_path)?;
    receipt(lease, repo, main_revision, WorkspaceSyncState::Ready)
}
fn receipt(
    lease: &SessionLease,
    repo: &Path,
    main_revision: &str,
    sync_state: WorkspaceSyncState,
) -> std::io::Result<Option<WorkspaceReady>> {
    authority::source_refs(
        repo,
        &lease.context.source_revision,
        main_revision,
        match &lease.workspace {
            WorkspaceSource::GitBundle { base_revision, .. } => base_revision,
            _ => return Err(failed("guest_git_authority_invalid")),
        },
    )?;
    let head_revision = git(repo, &["rev-parse", "--verify", "HEAD"])?
        .trim()
        .to_owned();
    let ready = WorkspaceReady {
        source_revision: lease.context.source_revision.clone(),
        main_revision: main_revision.to_owned(),
        head_revision,
        sync_state,
    };
    ready
        .validate()
        .map_err(|_| failed("guest_main_sync_receipt_invalid"))?;
    Ok(Some(ready))
}

fn failed(code: &'static str) -> std::io::Error {
    std::io::Error::other(code)
}

/// Stash-format private commit captures working tree, index, and all untracked
/// and ignored files. Restore it immediately so the disk keeps exact user state.
/// Conflict indexes cannot form a Git tree; their opaque disk remains retained.
pub fn checkpoint_ref(generation: u64, reaper: &crate::reaper::Reaper) -> std::io::Result<()> {
    let repo = Path::new("/workspace/repo");
    let run = |args: &[&str]| git::with_reaper(repo, args, reaper);
    let dirty = !run(&[
        "status",
        "--porcelain=v1",
        "--untracked-files=all",
        "--ignored=matching",
    ])?
    .is_empty();
    let commit = if dirty {
        run(&[
            "stash",
            "push",
            "--all",
            "--message",
            "jeryu-workspace-checkpoint",
        ])?;
        run(&["rev-parse", "--verify", "refs/stash"])?
            .trim()
            .to_owned()
    } else {
        run(&["rev-parse", "--verify", "HEAD"])?.trim().to_owned()
    };
    crate::freeze::quiesce_users()?;
    authority::checkpoint(repo, generation, &commit)?;
    if dirty {
        run(&["stash", "apply", "--index", &commit])?;
        run(&["stash", "drop", "--quiet"])?;
    }
    Ok(())
}

pub fn frozen_receipt(
    ready: &Option<WorkspaceReady>,
    reaper: &crate::reaper::Reaper,
) -> std::io::Result<Option<WorkspaceReady>> {
    let Some(mut receipt) = ready.clone() else {
        return Ok(None);
    };
    let repo = Path::new("/workspace/repo");
    receipt.head_revision = git::with_reaper(repo, &["rev-parse", "--verify", "HEAD"], reaper)?
        .trim()
        .to_owned();
    let conflict = repo.join(".git/rebase-merge").exists()
        || repo.join(".git/rebase-apply").exists()
        || !git::with_reaper(
            repo,
            &["diff", "--name-only", "--diff-filter=U", "-z"],
            reaper,
        )?
        .is_empty()
        || git::with_reaper(
            repo,
            &[
                "merge-base",
                "--is-ancestor",
                &receipt.main_revision,
                "HEAD",
            ],
            reaper,
        )
        .is_err();
    receipt.sync_state = if conflict {
        WorkspaceSyncState::RebaseRequired
    } else {
        WorkspaceSyncState::Ready
    };
    receipt
        .validate()
        .map_err(|_| failed("guest_checkpoint_receipt_invalid"))?;
    Ok(Some(receipt))
}
