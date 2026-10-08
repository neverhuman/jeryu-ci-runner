//! Guest-root authority refs. Sticky root-owned ancestors prevent rename bypass.
use nix::unistd::{Gid, Uid, chown};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::Path,
};

pub fn seal(repo: &Path) -> std::io::Result<()> {
    crate::freeze::quiesce_users()?;
    for path in [
        Path::new("/workspace"),
        repo,
        &repo.join(".git"),
        &repo.join(".git/refs"),
    ] {
        directory(path, 0o1777)?;
    }
    let refs = repo.join(".git/refs/jeryu");
    if !refs.exists() {
        fs::create_dir(&refs)?;
    }
    let mut nodes = 0;
    seal_tree(&refs, &mut nodes)?;
    let common = repo.join(".git/commondir");
    if common.exists() {
        let meta = fs::symlink_metadata(&common)?;
        if !meta.is_file()
            || meta.uid() != 0
            || meta.nlink() != 1
            || meta.len() != 2
            || meta.mode() & 0o222 != 0
            || fs::read(&common)? != b".\n"
        {
            return Err(failed());
        }
    } else {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o444)
            .open(common)?;
        file.write_all(b".\n")?;
        file.sync_all()?;
    }
    // A root-owned worktree needs an explicit safe.directory for normal Git.
    // Fresh tmpfs home contains no old provider material or operator settings.
    let config = Path::new("/run/agent-home/.gitconfig");
    if !config.exists() {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(config)?;
        file.write_all(b"[safe]\n\tdirectory = /workspace/repo\n")?;
        chown(config, Some(Uid::from_raw(1000)), Some(Gid::from_raw(1000)))
            .map_err(|_| failed())?;
    }
    Ok(())
}

pub fn source_refs(repo: &Path, source: &str, main: &str, base: &str) -> std::io::Result<()> {
    seal(repo)?;
    for (name, oid) in [("source", source), ("main", main), ("base", base)] {
        write_ref(&repo.join(".git/refs/jeryu").join(name), oid, true)?;
    }
    Ok(())
}
pub fn checkpoint(repo: &Path, generation: u64, oid: &str) -> std::io::Result<()> {
    let directory_path = repo.join(".git/refs/jeryu/checkpoints");
    if !directory_path.exists() {
        fs::create_dir(&directory_path)?;
    }
    directory(&directory_path, 0o755)?;
    write_ref(
        &directory_path.join(format!("generation-{generation}")),
        oid,
        false,
    )
}
fn write_ref(path: &Path, oid: &str, replace: bool) -> std::io::Result<()> {
    if !matches!(oid.len(), 40 | 64)
        || !oid
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(failed());
    }
    if replace && path.exists() {
        let meta = fs::symlink_metadata(path)?;
        if !meta.is_file() || meta.uid() != 0 || meta.nlink() != 1 {
            return Err(failed());
        }
        fs::remove_file(path)?;
    }
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o444)
        .custom_flags(nix::libc::O_NOFOLLOW)
        .open(path)?;
    writeln!(file, "{oid}")?;
    file.sync_all()
}
fn directory(path: &Path, mode: u32) -> std::io::Result<()> {
    if !fs::symlink_metadata(path)?.is_dir() {
        return Err(failed());
    }
    chown(path, Some(Uid::from_raw(0)), Some(Gid::from_raw(0))).map_err(|_| failed())?;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}
fn seal_tree(path: &Path, count: &mut usize) -> std::io::Result<()> {
    *count += 1;
    if *count > 4096 {
        return Err(failed());
    }
    let meta = fs::symlink_metadata(path)?;
    if meta.is_dir() {
        directory(path, 0o755)?;
        for entry in fs::read_dir(path)? {
            seal_tree(&entry?.path(), count)?;
        }
    } else if meta.is_file() && meta.nlink() == 1 {
        chown(path, Some(Uid::from_raw(0)), Some(Gid::from_raw(0))).map_err(|_| failed())?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o444))?;
    } else {
        return Err(failed());
    }
    Ok(())
}
fn failed() -> std::io::Error {
    std::io::Error::other("guest_git_authority_invalid")
}
