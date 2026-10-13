//! Internal producer receipt; it never enables a provider profile or binding.
use super::{RunnerResult, denied, elf};
use crate::{
    artifacts::sha256_descriptor,
    custody::{Directory, FileRole, read_bounded},
};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::File,
    os::unix::fs::{FileExt, PermissionsExt},
    path::{Component, Path, PathBuf},
};

mod inventory;
mod paths;
use paths::{alias_target, normalized, resolve, search_paths};

pub(super) fn inventory(root: &Directory) -> RunnerResult<()> {
    inventory::inventory(root)
}

const MAX_METADATA: u64 = 16 << 20;
const MAX_FILE: u64 = 2 << 30;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    schema: String,
    architecture: String,
    files: Vec<Entry>,
    #[serde(deserialize_with = "unique_map")]
    aliases: BTreeMap<String, String>,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    path: String,
    sha256: String,
    bytes: u64,
    mode: u32,
    elf: Option<elf::Elf>,
    #[serde(deserialize_with = "unique_map")]
    dependencies: BTreeMap<String, String>,
}

fn unique_map<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<BTreeMap<String, String>, D::Error> {
    struct Unique;
    impl<'de> serde::de::Visitor<'de> for Unique {
        type Value = BTreeMap<String, String>;
        fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("bounded map with unique keys")
        }
        fn visit_map<M: serde::de::MapAccess<'de>>(
            self,
            mut input: M,
        ) -> Result<Self::Value, M::Error> {
            let mut map = BTreeMap::new();
            while let Some((key, value)) = input.next_entry::<String, String>()? {
                if map.len() == 65536 || map.insert(key, value).is_some() {
                    return Err(serde::de::Error::custom(
                        "duplicate or excess closure entries",
                    ));
                }
            }
            Ok(map)
        }
    }
    deserializer.deserialize_map(Unique)
}

fn invalid() -> jeryu_runner_core::RunnerError {
    denied("image_loader_closure_invalid")
}

fn parent(root: &Directory, path: &Path) -> RunnerResult<Directory> {
    root.descend(
        path.parent()
            .ok_or_else(invalid)?
            .strip_prefix("/")
            .map_err(|_| invalid())?,
    )
    .map_err(|_| invalid())
}
fn file(root: &Directory, path: &Path, maximum: u64) -> RunnerResult<File> {
    parent(root, path)?
        .open_file(
            Path::new(path.file_name().ok_or_else(invalid)?),
            FileRole::Configuration { private: false },
            maximum,
        )
        .map_err(|_| invalid())
}

/// Keep every verified inode alive through durable readiness composition.
pub(super) struct VerifiedClosure {
    _files: Vec<File>,
}

pub(super) fn verify(root: &Directory) -> RunnerResult<VerifiedClosure> {
    let receipt = file(
        root,
        Path::new("/etc/jeryu/runtime-closure.json"),
        MAX_METADATA,
    )?;
    let bytes = read_bounded(receipt, MAX_METADATA).map_err(|_| invalid())?;
    let manifest: Manifest = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    if manifest.schema != "jeryu.runtime-closure.v1"
        || manifest.files.len() > 65536
        || manifest.aliases.len() > 65536
    {
        return Err(invalid());
    }
    let machine = match manifest.architecture.as_str() {
        "x86_64" => 62,
        "aarch64" => 183,
        _ => return Err(invalid()),
    };
    // Fixed provider packets in this lane are x86_64; another architecture
    // requires its own reviewed pins rather than reusing these byte identities.
    if machine != 62 {
        return Err(invalid());
    }
    for (path, target) in &manifest.aliases {
        let path = normalized(Path::new(path), false)?;
        alias_target(&path, target)?;
        let actual_parent = resolve(path.parent().ok_or_else(invalid)?, &manifest.aliases)?;
        let directory = root.descend(actual_parent.strip_prefix("/").map_err(|_| invalid())?)?;
        if directory.read_link(Path::new(path.file_name().ok_or_else(invalid)?))? != *target {
            return Err(invalid());
        }
        resolve(&path, &manifest.aliases)?;
    }
    let mut entries = BTreeMap::new();
    let mut physical = BTreeMap::new();
    let mut held = Vec::new();
    let mut script_interpreters = Vec::new();
    for entry in &manifest.files {
        let path = normalized(Path::new(&entry.path), false)?;
        if path.starts_with("/root")
            || path.starts_with("/home")
            || path.starts_with("/etc/ssh")
            || path.starts_with("/etc/ssl/private")
            || path.components().any(|part| {
                matches!(
                    part.as_os_str().to_str(),
                    Some(".netrc" | ".npmrc" | ".git-credentials" | ".claude" | ".codex" | ".grok")
                )
            })
        {
            return Err(invalid());
        }
        if path
            .components()
            .any(|part| part.as_os_str() == "glibc-hwcaps")
        {
            return Err(invalid());
        }
        let resolved = resolve(&path, &manifest.aliases)?;
        if entries.insert(path.clone(), entry).is_some()
            || physical.insert(resolved.clone(), entry).is_some()
            || entry.mode & !0o777 != 0
            || entry.mode & 0o022 != 0
        {
            return Err(invalid());
        }
        let input = file(root, &resolved, MAX_FILE)?;
        verify_entry(entry, &input, machine)?;
        if (path.starts_with("/usr") || path.starts_with("/lib") || path.starts_with("/lib64"))
            && entry.mode & 0o004 == 0
        {
            return Err(invalid());
        }
        if entry.elf.is_none() && entry.mode & 0o111 != 0 {
            let mut first = [0; 256];
            let count = input.read_at(&mut first, 0)?;
            let line = &first[..count];
            if !line.starts_with(b"#!") {
                return Err(invalid());
            }
            let end = line
                .iter()
                .position(|byte| *byte == b'\n')
                .ok_or_else(invalid)?;
            let interpreter = std::str::from_utf8(&line[2..end])
                .map_err(|_| invalid())?
                .trim();
            // A direct interpreter is bound; env-selected or argument-bearing
            // launchers need an explicit producer policy before acceptance.
            if interpreter.split_whitespace().count() != 1 {
                return Err(invalid());
            }
            script_interpreters.push(interpreter.to_string());
        }
        held.push(input);
    }
    let lookup = |path: &str| -> RunnerResult<&Entry> {
        let resolved = resolve(Path::new(path), &manifest.aliases)?;
        physical.get(&resolved).copied().ok_or_else(invalid)
    };
    let mut actual = BTreeSet::new();
    let mut pending = vec![(root.descend(Path::new(""))?, PathBuf::from("/"))];
    let mut object_count = 0;
    while let Some((directory, base)) = pending.pop() {
        if base.components().count() > 64
            || ((base.starts_with("/usr")
                || base.starts_with("/lib")
                || base.starts_with("/lib64")
                || base == Path::new("/etc")
                || base == Path::new("/etc/jeryu"))
                && directory.mode()? & 0o005 != 0o005)
        {
            return Err(invalid());
        }
        for name in directory.entries()? {
            object_count += 1;
            if object_count > 65536 {
                return Err(invalid());
            }
            let path = base.join(&name);
            match directory.entry_type(&name)? {
                rustix::fs::FileType::Directory => {
                    pending.push((directory.open_directory(&name)?, path))
                }
                rustix::fs::FileType::Symlink | rustix::fs::FileType::RegularFile => {
                    if path != Path::new("/etc/jeryu/runtime-closure.json") {
                        actual.insert(path);
                    }
                }
                _ => return Err(invalid()),
            }
        }
    }
    let expected: BTreeSet<_> = physical
        .keys()
        .cloned()
        .chain(manifest.aliases.keys().map(PathBuf::from))
        .collect();
    if actual != expected {
        return Err(invalid());
    }
    for path in &script_interpreters {
        let interpreter = lookup(path)?;
        if interpreter.mode & 0o111 == 0
            || interpreter
                .elf
                .as_ref()
                .is_none_or(|elf| !matches!(elf.kind, 2 | 3))
        {
            return Err(invalid());
        }
    }
    for entry in &manifest.files {
        if let Some(elf) = &entry.elf {
            for search in [&elf.rpath, &elf.runpath].into_iter().flatten() {
                let origin = resolve(Path::new(&entry.path), &manifest.aliases)?;
                let origin = origin.parent().and_then(Path::to_str).ok_or_else(invalid)?;
                for search in search.split(':') {
                    let search = search
                        .replace("${ORIGIN}", origin)
                        .replace("$ORIGIN", origin);
                    if search.contains('$') {
                        return Err(invalid());
                    }
                    let search = normalized(Path::new(&search), true)?;
                    if !search.starts_with("/usr/lib")
                        && !search.starts_with("/usr/lib64")
                        && !search.starts_with("/lib")
                        && !search.starts_with("/lib64")
                    {
                        return Err(invalid());
                    }
                }
            }
            if let Some(interpreter) = &elf.interpreter {
                if interpreter != "/lib64/ld-linux-x86-64.so.2"
                    && interpreter != "/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"
                {
                    return Err(invalid());
                }
                if lookup(interpreter)?
                    .elf
                    .as_ref()
                    .is_none_or(|elf| elf.kind != 3 || elf.interpreter.is_some())
                {
                    return Err(invalid());
                }
            }
            for (name, path) in &entry.dependencies {
                let dependency = lookup(path)?;
                if dependency
                    .elf
                    .as_ref()
                    .is_none_or(|elf| elf.kind != 3 || elf.soname.as_deref() != Some(name.as_str()))
                {
                    return Err(invalid());
                }
                let declared = resolve(Path::new(path), &manifest.aliases)?;
                let selected = search_paths(Path::new(&entry.path), elf, &manifest.aliases)?
                    .into_iter()
                    .map(|directory| resolve(&directory.join(name), &manifest.aliases))
                    .collect::<RunnerResult<Vec<_>>>()?
                    .into_iter()
                    .find(|path| physical.contains_key(path))
                    .ok_or_else(invalid)?;
                if selected != declared {
                    return Err(invalid());
                }
            }
        }
    }
    for path in [
        "/usr/bin/git",
        "/usr/lib/git-core/git-remote-https",
        "/bin/sh",
        "/bin/bash",
        "/bin/echo",
        "/usr/bin/nohup",
        "/usr/bin/rustc",
        "/usr/bin/cargo",
        "/usr/bin/cc",
        "/usr/bin/ld",
    ] {
        if lookup(path)?.mode & 0o005 != 0o005 {
            return Err(invalid());
        }
    }
    for path in [
        "/usr/share/git-core/templates/description",
        "/usr/share/git-core/templates/info/exclude",
        "/etc/ssl/certs/ca-certificates.crt",
        "/usr/lib/locale/C.utf8/LC_CTYPE",
    ] {
        lookup(path)?;
    }
    for (path, bytes, hash) in [
        (
            "/usr/bin/claude",
            246107320,
            "a186b99e4a9c88366cd49df2f7dad56c61fc306ef0140b19ee64b7c42a8d1348",
        ),
        (
            "/usr/bin/codex",
            292309256,
            "9a820c17865fa825d04db416818679a9d63bd72e50835c396f496e5684626c9c",
        ),
        (
            "/usr/bin/grok",
            171207616,
            "41626a53292324140b92556b9d42ff5542e3dcd04aff85eafb8689dd4adb44fc",
        ),
    ] {
        let entry = lookup(path)?;
        if entry.bytes != bytes
            || entry.sha256 != format!("sha256:{hash}")
            || entry.mode != 0o555
            || entry.elf.is_none()
        {
            return Err(invalid());
        }
    }
    if root.entry_exists(Path::new("home"))?
        && root
            .open_directory(Path::new("home"))?
            .entry_exists(Path::new("ubuntu"))?
    {
        return Err(invalid());
    }
    let etc = root.open_directory(Path::new("etc"))?;
    if etc.entry_exists(Path::new("ld.so.cache"))? {
        return Err(invalid());
    }
    Ok(VerifiedClosure { _files: held })
}

fn verify_entry(entry: &Entry, input: &File, machine: u16) -> RunnerResult<()> {
    let metadata = input.metadata()?;
    if metadata.len() != entry.bytes
        || metadata.permissions().mode() & 0o777 != entry.mode
        || sha256_descriptor(input)? != entry.sha256
        || elf::inspect(input, machine)? != entry.elf
    {
        return Err(invalid());
    }
    if entry
        .elf
        .as_ref()
        .map_or(!entry.dependencies.is_empty(), |elf| {
            elf.needed.iter().collect::<BTreeSet<_>>() != entry.dependencies.keys().collect()
        })
    {
        return Err(invalid());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{io::Write, os::unix::fs::MetadataExt};
    #[test]
    fn tampered_closure_hash_size_mode_and_loader_declarations_preserve_input() {
        let mut input = tempfile::tempfile().unwrap();
        input.write_all(b"public CA fixture").unwrap();
        input
            .set_permissions(std::fs::Permissions::from_mode(0o444))
            .unwrap();
        let metadata = input.metadata().unwrap();
        let mut entry = Entry {
            path: "/etc/ssl/certs/ca-certificates.crt".into(),
            sha256: sha256_descriptor(&input).unwrap(),
            bytes: metadata.len(),
            mode: 0o444,
            elf: None,
            dependencies: BTreeMap::new(),
        };
        verify_entry(&entry, &input, 62).unwrap();
        let hash = entry.sha256.clone();
        entry.sha256 = format!("sha256:{}", "0".repeat(64));
        assert!(verify_entry(&entry, &input, 62).is_err());
        entry.sha256 = hash;
        entry.bytes += 1;
        assert!(verify_entry(&entry, &input, 62).is_err());
        entry.bytes -= 1;
        entry.mode = 0o555;
        assert!(verify_entry(&entry, &input, 62).is_err());
        entry.mode = 0o444;
        entry
            .dependencies
            .insert("libc.so.6".into(), "/lib/libc.so.6".into());
        assert!(verify_entry(&entry, &input, 62).is_err());
        let after = input.metadata().unwrap();
        assert_eq!(
            (metadata.ino(), metadata.uid(), metadata.mode()),
            (after.ino(), after.uid(), after.mode())
        );
        assert_eq!(sha256_descriptor(&input).unwrap(), entry.sha256);
    }
    #[test]
    fn duplicate_alias_keys_and_unknown_metadata_are_rejected() {
        let duplicate = r#"{"schema":"jeryu.runtime-closure.v1","architecture":"x86_64","files":[],"aliases":{"/usr/bin/a":"b","/usr/bin/a":"c"}}"#;
        assert!(serde_json::from_str::<Manifest>(duplicate).is_err());
        let unknown = r#"{"schema":"jeryu.runtime-closure.v1","architecture":"x86_64","files":[],"aliases":{},"qualified":true}"#;
        assert!(serde_json::from_str::<Manifest>(unknown).is_err());
    }
}
