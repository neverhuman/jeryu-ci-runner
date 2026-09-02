use std::collections::BTreeSet;
use std::fs;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

const SOURCE: &str = "https://github.com/neverhuman/jeryu-core.git";
const HOSTED: &str = "https://git.neverhuman.org/git/jeryu/jeryu-core.git";
const TAG: &str = "jeryu-core-v5.0.0-split.0";
const COMMIT: &str = "0e29dc90673ffdf9959aaaa1f05482301f15fabe";
const SUPPORT_REF: &str = "refs/heads/preserve/hosted-cargo/jeryu-core-v5.0.0-split.0";

struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock after epoch")
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "jeryu-ci-runner-hosted-transport-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir(&path).expect("create unique scratch directory");
        Self(path)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("workspace root")
        .to_path_buf()
}

fn parse_mappings(contents: &str) -> BTreeSet<(String, String)> {
    let mut target = None;
    let mut mappings = BTreeSet::new();
    for line in contents.lines().map(str::trim) {
        if let Some(value) = line
            .strip_prefix("[url \"")
            .and_then(|value| value.strip_suffix("\"]"))
        {
            target = Some(value.to_owned());
        } else if let Some(source) = line.strip_prefix("insteadOf = ") {
            mappings.insert((
                source.to_owned(),
                target.clone().expect("insteadOf follows a URL section"),
            ));
        }
    }
    mappings
}

fn parse_pins(contents: &str) -> BTreeSet<(String, String, String, String)> {
    contents
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(|line| {
            let fields = line.split('|').collect::<Vec<_>>();
            assert_eq!(fields.len(), 4, "hosted pin row has four fields");
            (
                fields[0].to_owned(),
                fields[1].to_owned(),
                fields[2].to_owned(),
                fields[3].to_owned(),
            )
        })
        .collect()
}

fn scrub_git_config_env(command: &mut Command) {
    for (name, _) in std::env::vars() {
        if name == "GIT_CONFIG"
            || name == "GIT_CONFIG_COUNT"
            || name == "GIT_CONFIG_PARAMETERS"
            || name == "GIT_CONFIG_SYSTEM"
            || name.starts_with("GIT_CONFIG_KEY_")
            || name.starts_with("GIT_CONFIG_VALUE_")
        {
            command.env_remove(name);
        }
    }
}

fn effective_url(overlay: &Path, source: &str) -> String {
    let mut command = Command::new("git");
    command
        .current_dir("/")
        .args(["ls-remote", "--get-url", source])
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", overlay)
        .env("GIT_TERMINAL_PROMPT", "0");
    scrub_git_config_env(&mut command);
    let output = command.output().expect("run Git URL resolver");
    assert!(
        output.status.success(),
        "Git URL resolution failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("UTF-8 URL")
        .trim()
        .to_owned()
}

fn source_helper(helper: &Path, global: &Path, body: &str) -> Output {
    let mut command = Command::new("bash");
    command
        .current_dir(root())
        .args(["-c", body, "_", helper.to_str().expect("UTF-8 helper")])
        .env("GIT_CONFIG_GLOBAL", global);
    scrub_git_config_env(&mut command);
    command.output().expect("run hosted Git environment helper")
}

#[test]
fn cargo_identity_and_effective_transport_are_exact() {
    let root = root();
    let cargo_config = fs::read_to_string(root.join(".cargo/config.toml")).expect("Cargo config");
    assert!(cargo_config.contains("git-fetch-with-cli = true"));
    assert!(!cargo_config.contains("GIT_CONFIG_GLOBAL"));

    let overlay_path = root.join(".cargo/hosted-gitconfig");
    let overlay = fs::read_to_string(&overlay_path).expect("hosted Git overlay");
    let expected_mapping = BTreeSet::from([(SOURCE.to_owned(), HOSTED.to_owned())]);
    assert_eq!(parse_mappings(&overlay), expected_mapping);
    assert!(!overlay.contains("[include]"));
    assert!(!overlay.contains("[includeIf"));
    assert!(
        overlay.contains("helper = /home/ubuntu/.config/jeryu/bin/git-credential-neverhuman-org")
    );
    assert!(overlay.contains("[http \"https://git.neverhuman.org\"]\n\tpostBuffer = 1"));
    assert_eq!(effective_url(&overlay_path, SOURCE), HOSTED);

    let pin_policy =
        fs::read_to_string(root.join(".cargo/hosted-pin-refs.tsv")).expect("hosted pin policy");
    let expected_pin = BTreeSet::from([(
        "jeryu-core".to_owned(),
        TAG.to_owned(),
        COMMIT.to_owned(),
        SUPPORT_REF.to_owned(),
    )]);
    assert_eq!(parse_pins(&pin_policy), expected_pin);

    let lock = fs::read_to_string(root.join("Cargo.lock")).expect("Cargo lock");
    let expected_lock_source = format!("git+{SOURCE}?tag={TAG}#{COMMIT}");
    let locked_git_rows = lock
        .lines()
        .filter_map(|line| {
            line.trim()
                .strip_prefix("source = \"")
                .and_then(|value| value.strip_suffix('"'))
                .filter(|value| value.starts_with("git+"))
        })
        .collect::<Vec<_>>();
    assert_eq!(locked_git_rows, vec![expected_lock_source.as_str(); 2]);

    let deny = fs::read_to_string(root.join("deny.toml")).expect("Cargo Deny policy");
    assert!(deny.contains("unknown-git = \"deny\""));
    assert!(deny.contains(&format!("allow-git = [\"{SOURCE}\"]")));

    let missing = overlay.replacen(&format!("\tinsteadOf = {SOURCE}\n"), "", 1);
    assert_ne!(parse_mappings(&missing), expected_mapping);
    let wrong = overlay.replacen(HOSTED, "https://attacker.invalid/core.git", 1);
    assert_ne!(parse_mappings(&wrong), expected_mapping);
    let extra = format!(
        "{overlay}\n[url \"https://attacker.invalid/repo.git\"]\n\tinsteadOf = https://unlisted.invalid/repo.git\n"
    );
    assert_ne!(parse_mappings(&extra), expected_mapping);

    let missing_pin = pin_policy
        .lines()
        .filter(|line| line.trim().starts_with('#') || line.trim().is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    assert_ne!(parse_pins(&missing_pin), expected_pin);
    let wrong_pin = pin_policy.replacen(COMMIT, "0000000000000000000000000000000000000000", 1);
    assert_ne!(parse_pins(&wrong_pin), expected_pin);
    let extra_pin = format!(
        "{pin_policy}attacker|attacker-v1.0.0|1111111111111111111111111111111111111111|refs/heads/preserve/hosted-cargo/attacker-v1.0.0\n"
    );
    assert_ne!(parse_pins(&extra_pin), expected_pin);
}

#[test]
fn source_helper_rejects_unsafe_caller_configs_and_scrubs_injections() {
    let root = root();
    let helper = root.join("ops/ci/hosted-git-env.sh");
    let overlay = root.join(".cargo/hosted-gitconfig");
    let scratch = Scratch::new();
    let regular = scratch.0.join("regular.config");
    fs::copy(&overlay, &regular).expect("copy test config");
    let symlink_path = scratch.0.join("symlink.config");
    symlink(&regular, &symlink_path).expect("create test symlink");
    let hardlink_path = scratch.0.join("hardlink.config");
    fs::hard_link(&regular, &hardlink_path).expect("create test hardlink");
    let equivalent = scratch.0.join("equivalent.config");
    fs::copy(&overlay, &equivalent).expect("copy independent equivalent config");

    for invalid in [
        scratch.0.join("missing.config"),
        symlink_path,
        hardlink_path,
    ] {
        let output = source_helper(&helper, &invalid, "source \"$1\"");
        assert!(
            !output.status.success(),
            "unsafe caller config was accepted"
        );
    }
    let relative = source_helper(&helper, Path::new("relative.config"), "source \"$1\"");
    assert!(
        !relative.status.success(),
        "relative caller config was accepted"
    );

    let accepted = source_helper(
        &helper,
        &equivalent,
        "source \"$1\"; printf '%s' \"$GIT_CONFIG_GLOBAL\"",
    );
    assert!(
        accepted.status.success(),
        "equivalent caller config was rejected: {}",
        String::from_utf8_lossy(&accepted.stderr)
    );
    assert_eq!(
        String::from_utf8(accepted.stdout).expect("UTF-8 canonical config path"),
        overlay.to_str().expect("UTF-8 overlay path")
    );

    let mismatched = source_helper(&helper, &root.join("deny.toml"), "source \"$1\"");
    assert!(!mismatched.status.success());
    assert!(
        String::from_utf8_lossy(&mismatched.stderr).contains("differs from the exact reviewed")
    );

    let mut command = Command::new("bash");
    command
        .current_dir(&root)
        .args([
            "-c",
            "source \"$1\"; [[ -z ${GIT_CONFIG_COUNT+x} && -z ${GIT_CONFIG_KEY_0+x} && -z ${GIT_CONFIG_VALUE_0+x} && -z ${GIT_SSL_NO_VERIFY+x} && -z ${GIT_TRACE_CURL+x} && -z ${GIT_EXEC_PATH+x} && -z ${GIT_DIR+x} && -z ${GIT_OBJECT_DIRECTORY+x} && -z ${HTTPS_PROXY+x} && -z ${https_proxy+x} && -z ${CURL_CA_BUNDLE+x} && -z ${SSL_CERT_FILE+x} && $GIT_TERMINAL_PROMPT == 0 && $CARGO_NET_GIT_FETCH_WITH_CLI == true ]]",
            "_",
            helper.to_str().expect("UTF-8 helper"),
        ])
        .env("GIT_CONFIG_GLOBAL", &overlay)
        .env("GIT_CONFIG_COUNT", "1")
        .env("GIT_CONFIG_KEY_0", "url.https://attacker.invalid.insteadOf")
        .env("GIT_CONFIG_VALUE_0", SOURCE)
        .env("GIT_SSL_NO_VERIFY", "1")
        .env("GIT_TRACE_CURL", "1")
        .env("GIT_EXEC_PATH", "/tmp/attacker-git-core")
        .env("GIT_DIR", "/tmp/attacker.git")
        .env("GIT_OBJECT_DIRECTORY", "/tmp/attacker-objects")
        .env("HTTPS_PROXY", "http://attacker.invalid:8080")
        .env("https_proxy", "http://attacker.invalid:8081")
        .env("CURL_CA_BUNDLE", "/tmp/attacker-ca.pem")
        .env("SSL_CERT_FILE", "/tmp/attacker-ca.pem")
        .env("GIT_TERMINAL_PROMPT", "1")
        .env("CARGO_NET_GIT_FETCH_WITH_CLI", "false");
    let scrubbed = command.output().expect("run injected helper test");
    assert!(
        scrubbed.status.success(),
        "Git config injection was not scrubbed: {}",
        String::from_utf8_lossy(&scrubbed.stderr)
    );
}
