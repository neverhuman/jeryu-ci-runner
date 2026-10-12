use super::*;

/// Measure only protected public staging data, without executing staged bytes.
/// This producer inventory is not upstream provenance or provider qualification.
pub(super) fn inventory(root: &Directory) -> RunnerResult<()> {
    let mut pending = vec![(root.descend(Path::new(""))?, PathBuf::from("/"))];
    let mut files = Vec::new();
    let mut aliases = BTreeMap::new();
    let mut held = Vec::new();
    let mut count = 0;
    while let Some((directory, base)) = pending.pop() {
        if base.components().count() > 64 {
            return Err(invalid());
        }
        let mut names = directory.entries()?;
        names.sort();
        for name in names {
            count += 1;
            if count > 65536 {
                return Err(invalid());
            }
            let path = base.join(&name);
            match directory.entry_type(&name)? {
                rustix::fs::FileType::Directory => {
                    pending.push((directory.open_directory(&name)?, path))
                }
                rustix::fs::FileType::Symlink => {
                    let target = directory.read_link(&name)?;
                    alias_target(&path, &target)?;
                    aliases.insert(path.to_str().ok_or_else(invalid)?.to_string(), target);
                }
                rustix::fs::FileType::RegularFile => {
                    if path == Path::new("/etc/jeryu/runtime-closure.json")
                        || path == Path::new("/etc/jeryu/runtime-image-class")
                    {
                        return Err(invalid());
                    }
                    let file = directory.open_file(
                        &name,
                        FileRole::Configuration { private: false },
                        MAX_FILE,
                    )?;
                    let metadata = file.metadata()?;
                    files.push(Entry {
                        path: path.to_str().ok_or_else(invalid)?.into(),
                        sha256: sha256_descriptor(&file)?,
                        bytes: metadata.len(),
                        mode: metadata.permissions().mode() & 0o777,
                        elf: elf::inspect(&file, 62)?,
                        dependencies: BTreeMap::new(),
                    });
                    held.push(file);
                }
                _ => return Err(invalid()),
            }
        }
    }
    files.sort_by(|left, right| left.path.cmp(&right.path));
    let paths: BTreeSet<_> = files
        .iter()
        .map(|entry| PathBuf::from(&entry.path))
        .collect();
    for entry in &mut files {
        if let Some(elf) = &entry.elf {
            for name in &elf.needed {
                let mut selected = None;
                for directory in search_paths(Path::new(&entry.path), elf, &aliases)? {
                    let candidate = resolve(&directory.join(name), &aliases)?;
                    if paths.contains(&candidate) {
                        selected = Some(candidate);
                        break;
                    }
                }
                let selected = selected.ok_or_else(invalid)?;
                entry.dependencies.insert(
                    name.clone(),
                    selected.to_str().ok_or_else(invalid)?.to_string(),
                );
            }
        }
    }
    let manifest = Manifest {
        schema: "jeryu.runtime-closure.v1".into(),
        architecture: "x86_64".into(),
        files,
        aliases,
    };
    let bytes = serde_json::to_vec(&manifest).map_err(|_| invalid())?;
    if bytes.len() as u64 > MAX_METADATA {
        return Err(invalid());
    }
    let descriptor = root.descend(Path::new(""))?.into_fd();
    let config =
        super::super::io::directories(&descriptor, &["etc", "jeryu"], true)?.ok_or_else(invalid)?;
    super::super::io::write_fixed(&config, "runtime-closure.json", &bytes, 0o444)?;
    drop(held);
    Ok(())
}
