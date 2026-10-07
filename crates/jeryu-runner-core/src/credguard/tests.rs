//! Negative cases for the credential-material export guards.

use super::*;

fn roots() -> Vec<PathBuf> {
    vec![PathBuf::from("/workcells/wc-0001/repo")]
}

/// One case per credential shape the guard must refuse, each spelled with `/`,
/// with `\`, and in upper case, because an export manifest can carry either
/// separator and either case.
const CREDENTIAL_PATHS: &[&str] = &[
    // per-run agent homes and the portable auth store
    "/workcells/wc-0001/repo/.home/.config/gh/hosts.yml",
    "/workcells/wc-0001/repo/.claude/.credentials.json",
    "/workcells/wc-0001/repo/.codex/auth.json",
    "/workcells/wc-0001/repo/.jekko/users/jeryu-agent/llm.env",
    "/workcells/wc-0001/repo/agent-auth/claude/env",
    // git and netrc credential stores
    "/workcells/wc-0001/repo/.git-credentials",
    "/workcells/wc-0001/repo/nested/.netrc",
    "/workcells/wc-0001/repo/nested/_netrc",
    // ssh keys
    "/workcells/wc-0001/repo/.ssh/known_hosts",
    "/workcells/wc-0001/repo/keys/id_rsa",
    "/workcells/wc-0001/repo/keys/id_ed25519",
    // cloud credential directories
    "/workcells/wc-0001/repo/.aws/credentials",
    "/workcells/wc-0001/repo/.config/gh/hosts.yml",
    "/workcells/wc-0001/repo/.docker/config.json",
    // refresh tokens
    "/workcells/wc-0001/repo/state/refresh_token.json",
    "/workcells/wc-0001/repo/state/refresh-token",
];

#[test]
fn credential_paths_are_denied_in_every_spelling() {
    for path in CREDENTIAL_PATHS {
        for spelling in [
            (*path).to_string(),
            path.replace('/', "\\"),
            path.to_uppercase(),
        ] {
            let err = deny_credential_material(Path::new(&spelling))
                .err()
                .unwrap_or_else(|| panic!("expected a denial for {spelling}"));
            assert_eq!(err.code(), "credential_material_denied", "{spelling}");

            // The same path must also be refused through the front door, even
            // though it sits inside a permitted export root.
            assert!(
                guard_export_path(Path::new(&spelling), &roots()).is_err(),
                "{spelling} must not be exportable"
            );
        }
    }
}

#[test]
fn ordinary_repository_paths_stay_exportable() {
    for path in [
        "/workcells/wc-0001/repo/src/lib.rs",
        "/workcells/wc-0001/repo/target/junit.xml",
        "/workcells/wc-0001/repo/keys/id_ed25519.pub",
    ] {
        guard_export_path(Path::new(path), &roots())
            .unwrap_or_else(|err| panic!("{path} should be exportable: {err}"));
    }
}

#[test]
fn paths_outside_the_permitted_roots_are_denied() {
    let err = ensure_within_export_roots(Path::new("/workcells/wc-0002/repo/src/lib.rs"), &roots())
        .err()
        .unwrap_or_else(|| panic!("expected a denial"));
    assert_eq!(err.code(), "export_root_denied");

    // An empty allowlist exports nothing: the guard is an allowlist, not a
    // denylist with holes in it.
    let err = ensure_within_export_roots(Path::new("/workcells/wc-0001/repo/src/lib.rs"), &[])
        .err()
        .unwrap_or_else(|| panic!("expected a denial"));
    assert_eq!(err.code(), "export_root_denied");
}

#[test]
fn writing_through_a_destination_symlink_is_denied() {
    let temp = tempfile::tempdir().unwrap_or_else(|err| panic!("{err}"));
    let root = temp.path();
    let host_store = root.join("host-store");
    std::fs::create_dir(&host_store).unwrap_or_else(|err| panic!("{err}"));
    let exports = root.join("exports");
    std::fs::create_dir(&exports).unwrap_or_else(|err| panic!("{err}"));
    let permitted = vec![exports.clone()];

    // A plain destination under the permitted root is fine.
    guard_write_destination(&exports.join("workspace.tar"), &permitted)
        .unwrap_or_else(|err| panic!("{err}"));

    // A symlinked directory component must not be followed.
    let linked_dir = exports.join("linked");
    std::os::unix::fs::symlink(&host_store, &linked_dir).unwrap_or_else(|err| panic!("{err}"));
    let err = guard_write_destination(&linked_dir.join("workspace.tar"), &permitted)
        .err()
        .unwrap_or_else(|| panic!("expected a denial"));
    assert_eq!(err.code(), "destination_symlink_denied");

    // So must a symlinked final component.
    let linked_file = exports.join("workspace.tar.link");
    std::os::unix::fs::symlink(host_store.join("stash.tar"), &linked_file)
        .unwrap_or_else(|err| panic!("{err}"));
    let err = guard_write_destination(&linked_file, &permitted)
        .err()
        .unwrap_or_else(|| panic!("expected a denial"));
    assert_eq!(err.code(), "destination_symlink_denied");
}

#[test]
fn a_token_value_in_captured_text_is_denied() {
    let tokens = vec!["jrt-invented-value-9f3b".to_string()];

    for label in ["log", "capsule"] {
        let err = deny_token_values(
            label,
            "step failed: Authorization: Bearer jrt-invented-value-9f3b",
            &tokens,
        )
        .err()
        .unwrap_or_else(|| panic!("expected a denial for the {label} capture"));
        assert_eq!(err.code(), "token_value_in_capture");
        // The denial names the surface and the length, never the value.
        assert!(err.message().contains(label), "{}", err.message());
        assert!(
            !err.message().contains("jrt-invented-value-9f3b"),
            "the denial must not echo the token value: {}",
            err.message()
        );
    }

    let err =
        deny_token_values_in_bytes("log", b"\xffbinary jrt-invented-value-9f3b tail", &tokens)
            .err()
            .unwrap_or_else(|| panic!("expected a denial"));
    assert_eq!(err.code(), "token_value_in_capture");

    deny_token_values("log", "step failed: exit code 1", &tokens)
        .unwrap_or_else(|err| panic!("{err}"));
    // An empty configured value must not match every line of every log.
    deny_token_values("log", "step failed", &[String::new()]).unwrap_or_else(|err| panic!("{err}"));
}
