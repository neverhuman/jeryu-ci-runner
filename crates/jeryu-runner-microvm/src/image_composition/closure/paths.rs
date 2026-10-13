use super::*;

pub(super) fn normalized(path: &Path, traversal: bool) -> RunnerResult<PathBuf> {
    if !path.is_absolute()
        || (!traversal
            && path
                .to_str()
                .ok_or_else(invalid)?
                .split('/')
                .any(|part| part == "." || part == ".."))
    {
        return Err(invalid());
    }
    let mut result = PathBuf::from("/");
    for component in path.components() {
        match component {
            Component::RootDir => (),
            Component::Normal(name) => result.push(name),
            Component::CurDir if traversal => (),
            Component::ParentDir if traversal && result != Path::new("/") => {
                result.pop();
            }
            _ => return Err(invalid()),
        }
    }
    Ok(result)
}

pub(super) fn alias_target(path: &Path, target: &str) -> RunnerResult<PathBuf> {
    let target = normalized(&path.parent().ok_or_else(invalid)?.join(target), true)?;
    let allowed = match path.to_str().ok_or_else(invalid)? {
        "/bin" => target == Path::new("/usr/bin"),
        "/sbin" => target == Path::new("/usr/sbin"),
        "/lib" | "/lib64" => target.starts_with("/usr/lib") || target == Path::new("/usr/lib64"),
        "/usr/lib/ssl/cert.pem" => target == Path::new("/etc/ssl/certs/ca-certificates.crt"),
        "/usr/lib/ssl/certs" => target == Path::new("/etc/ssl/certs"),
        "/usr/lib/ssl/openssl.cnf" => target == Path::new("/etc/ssl/openssl.cnf"),
        "/etc/os-release" => target == Path::new("/usr/lib/os-release"),
        "/etc/localtime" => target.starts_with("/usr/share/zoneinfo"),
        "/var/run" => target == Path::new("/run"),
        "/var/lock" => target == Path::new("/run/lock"),
        _ if path.starts_with("/etc/ssl/certs") => {
            target.starts_with("/etc/ssl/certs") || target.starts_with("/usr/share/ca-certificates")
        }
        _ if path.starts_with("/usr") => {
            target.starts_with("/usr") || target.starts_with("/etc/alternatives")
        }
        _ if path.starts_with("/etc/alternatives") => target.starts_with("/usr"),
        _ if path.starts_with("/lib") || path.starts_with("/lib64") => {
            target.starts_with("/lib")
                || target.starts_with("/lib64")
                || target.starts_with("/usr/lib")
                || target.starts_with("/usr/lib64")
        }
        _ => false,
    };
    if !allowed {
        return Err(invalid());
    }
    Ok(target)
}

pub(super) fn resolve(path: &Path, aliases: &BTreeMap<String, String>) -> RunnerResult<PathBuf> {
    let mut path = normalized(path, false)?;
    for _ in 0..32 {
        let mut prefix = PathBuf::from("/");
        let mut replacement = None;
        for component in path.components().skip(1) {
            prefix.push(component.as_os_str());
            if let Some(target) = aliases.get(prefix.to_str().ok_or_else(invalid)?) {
                replacement = Some(
                    alias_target(&prefix, target)?
                        .join(path.strip_prefix(&prefix).map_err(|_| invalid())?),
                );
                break;
            }
        }
        match replacement {
            Some(next) => path = next,
            None => return Ok(path),
        }
    }
    Err(invalid())
}

pub(super) fn search_paths(
    path: &Path,
    elf: &elf::Elf,
    aliases: &BTreeMap<String, String>,
) -> RunnerResult<Vec<PathBuf>> {
    let origin = resolve(path, aliases)?;
    let origin = origin.parent().and_then(Path::to_str).ok_or_else(invalid)?;
    let mut paths = Vec::new();
    if let Some(search) = elf.runpath.as_ref().or(elf.rpath.as_ref()) {
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
            paths.push(search);
        }
    }
    paths.extend(
        [
            "/lib/x86_64-linux-gnu",
            "/usr/lib/x86_64-linux-gnu",
            "/lib64",
            "/usr/lib64",
            "/lib",
            "/usr/lib",
        ]
        .map(PathBuf::from),
    );
    Ok(paths)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn aliases_are_image_relative_and_cycles_traversal_and_escape_fail() {
        let aliases = BTreeMap::from([
            ("/bin".into(), "usr/bin".into()),
            (
                "/usr/bin/claude".into(),
                "../lib/jeryu/providers/claude/2.1.289/bin/claude".into(),
            ),
        ]);
        assert_eq!(
            resolve(Path::new("/bin/claude"), &aliases).unwrap(),
            Path::new("/usr/lib/jeryu/providers/claude/2.1.289/bin/claude")
        );
        assert!(resolve(Path::new("/bin/../root"), &aliases).is_err());
        assert!(alias_target(Path::new("/usr/bin/claude"), "/home/ubuntu/claude").is_err());
        assert!(alias_target(Path::new("/usr/bin/claude"), "../../../outside").is_err());
        let cycle = BTreeMap::from([
            ("/usr/bin/a".into(), "b".into()),
            ("/usr/bin/b".into(), "a".into()),
        ]);
        assert!(resolve(Path::new("/usr/bin/a"), &cycle).is_err());
    }
}
