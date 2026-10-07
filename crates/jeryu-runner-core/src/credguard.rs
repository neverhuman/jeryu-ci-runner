#![doc = "Host credential-material guards for workspace export, artifact upload, and log capture."]

//! Every path that leaves a workcell — a workspace export tarball, an uploaded
//! artifact, a captured log or an evidence capsule — passes through here first.
//!
//! Two independent checks run on every path, and both must pass:
//!
//! 1. an ALLOWLIST of permitted export roots supplied by the caller from site
//!    configuration ([`ensure_within_export_roots`]); nothing is exportable by
//!    default, and
//! 2. a refusal of host credential material ([`deny_credential_material`]),
//!    which also covers credential files that sit *inside* a permitted root —
//!    the per-run agent home the native runner mints under the workspace is the
//!    common case.
//!
//! Matching is case-insensitive and treats `\` as a separator too, so a path
//! spelled `WORKSPACE\.SSH\id_rsa` is refused exactly like `workspace/.ssh/id_rsa`.
//! Writes additionally refuse to follow a symlink anywhere in the destination
//! ([`deny_destination_symlink`]), and captured text is rejected outright when a
//! configured token value appears in it ([`deny_token_values`]).

use crate::error::{RunnerError, RunnerResult};
use std::path::{Component, Path, PathBuf};

/// Path segments that always carry credential material: per-run agent homes,
/// the Jeryu-owned portable auth store, and the well-known cloud credential
/// directories.
pub const DENIED_PATH_SEGMENTS: &[&str] = &[
    ".home",
    ".claude",
    ".codex",
    ".jekko",
    "agent-auth",
    ".ssh",
    ".aws",
    ".gnupg",
    ".docker",
];

/// File names that always carry credential material.
pub const DENIED_FILE_NAMES: &[&str] = &[
    ".git-credentials",
    "git-credentials",
    ".netrc",
    "_netrc",
    "netrc",
    "credentials",
    "credentials.json",
    ".credentials.json",
    "auth.json",
];

/// Credential files that are only refused under their owning directory, because
/// the bare file name is too common to deny on its own.
pub const DENIED_PARENT_FILE_PAIRS: &[(&str, &str)] =
    &[("gh", "hosts.yml"), (".docker", "config.json")];

/// Lowercase substrings that mark a refresh-token file wherever it appears.
pub const DENIED_NAME_FRAGMENTS: &[&str] = &["refresh_token", "refresh-token"];

/// Split a path into lowercase segments, treating `\` as a separator so a
/// Windows-spelled path cannot slip a denied segment past the check.
fn lowercase_segments(path: &Path) -> Vec<String> {
    path.to_string_lossy()
        .split(['/', '\\'])
        .filter(|segment| !segment.is_empty() && *segment != ".")
        .map(str::to_lowercase)
        .collect()
}

/// True for an SSH private key file name (`id_rsa`, `id_ed25519`, ...). The
/// matching `.pub` public half is not credential material.
fn is_private_key_name(name: &str) -> bool {
    name.starts_with("id_") && !name.ends_with(".pub")
}

/// Refuse a path that names host credential material anywhere along it.
pub fn deny_credential_material(path: &Path) -> RunnerResult<()> {
    let segments = lowercase_segments(path);
    for (index, segment) in segments.iter().enumerate() {
        let denied = DENIED_PATH_SEGMENTS.contains(&segment.as_str())
            || DENIED_FILE_NAMES.contains(&segment.as_str())
            || is_private_key_name(segment)
            || DENIED_NAME_FRAGMENTS
                .iter()
                .any(|fragment| segment.contains(fragment))
            || index
                .checked_sub(1)
                .and_then(|parent| segments.get(parent))
                .is_some_and(|parent| {
                    DENIED_PARENT_FILE_PAIRS
                        .iter()
                        .any(|(dir, file)| parent == dir && segment == file)
                });
        if denied {
            return Err(RunnerError::new(
                "credential_material_denied",
                format!(
                    "path '{}' names host credential material ('{segment}') and cannot leave the workcell",
                    path.display()
                ),
            ));
        }
    }
    Ok(())
}

/// Require that `path` sits inside one of the permitted export roots. The roots
/// come from site configuration; an empty allowlist exports nothing.
pub fn ensure_within_export_roots(path: &Path, permitted_roots: &[PathBuf]) -> RunnerResult<()> {
    if permitted_roots.iter().any(|root| path.starts_with(root)) {
        return Ok(());
    }
    Err(RunnerError::new(
        "export_root_denied",
        format!(
            "path '{}' is outside the {} permitted export root(s)",
            path.display(),
            permitted_roots.len()
        ),
    ))
}

/// Refuse to write through a symlink: no component of `path` that already
/// exists may be one, so an attacker-placed link cannot redirect an export,
/// upload or log write onto host credential material.
pub fn deny_destination_symlink(path: &Path) -> RunnerResult<()> {
    let mut walked = PathBuf::new();
    for component in path.components() {
        walked.push(component.as_os_str());
        if matches!(component, Component::Prefix(_) | Component::RootDir) {
            continue;
        }
        match std::fs::symlink_metadata(&walked) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(RunnerError::new(
                    "destination_symlink_denied",
                    format!(
                        "destination '{}' passes through symlink '{}'",
                        path.display(),
                        walked.display()
                    ),
                ));
            }
            // A component that does not exist yet cannot be a symlink, and the
            // write itself creates it.
            _ => {}
        }
    }
    Ok(())
}

/// Guard one path that is about to leave the workcell read-only (an export
/// manifest entry, an artifact upload path).
pub fn guard_export_path(path: &Path, permitted_roots: &[PathBuf]) -> RunnerResult<()> {
    ensure_within_export_roots(path, permitted_roots)?;
    deny_credential_material(path)
}

/// Guard one path the runner is about to WRITE (an export tarball, a log or
/// capsule file): the read-only guards plus the symlink refusal.
pub fn guard_write_destination(path: &Path, permitted_roots: &[PathBuf]) -> RunnerResult<()> {
    guard_export_path(path, permitted_roots)?;
    deny_destination_symlink(path)
}

/// Fail when a configured token value appears in captured text. `label` names
/// the capture surface ("log", "capsule", ...) so the denial points at it.
/// Empty token values are ignored; the token value itself is never echoed.
pub fn deny_token_values(label: &str, text: &str, token_values: &[String]) -> RunnerResult<()> {
    for token in token_values.iter().filter(|token| !token.is_empty()) {
        if text.contains(token.as_str()) {
            return Err(RunnerError::new(
                "token_value_in_capture",
                format!(
                    "a configured token value ({} chars) appears in the captured {label}",
                    token.len()
                ),
            ));
        }
    }
    Ok(())
}

/// [`deny_token_values`] for captured bytes that may not be valid UTF-8.
pub fn deny_token_values_in_bytes(
    label: &str,
    bytes: &[u8],
    token_values: &[String],
) -> RunnerResult<()> {
    deny_token_values(label, &String::from_utf8_lossy(bytes), token_values)
}

#[cfg(test)]
mod tests;
