#![doc = "Configuration for the per-host MODEL egress proxy."]
#![doc = ""]
#![doc = "Agent containers run `--network none`, so the only way an agent session can"]
#![doc = "reach a model API is the proxy this config describes: a per-host forward"]
#![doc = "proxy bound on a dedicated bridge, with an allow-list of model API hosts."]
#![doc = "The container is attached to that bridge and given `HTTPS_PROXY` pointing at"]
#![doc = "the proxy, so every other destination stays unreachable exactly as it is"]
#![doc = "under `--network none`."]
#![doc = ""]
#![doc = "The allow-list, the bridge name and the proxy endpoint all come from one"]
#![doc = "TOML file (see `configs/model-egress.toml`). With no file the defaults allow"]
#![doc = "only the Anthropic API host and attach no bridge at all, which keeps the"]
#![doc = "container on `--network none`."]

use crate::Allowlist;
use serde::Deserialize;
use std::path::{Path, PathBuf};

/// Environment variable holding the path to the model-egress TOML file.
pub const CONFIG_PATH_ENV: &str = "JERYU_MODEL_EGRESS_CONFIG";

/// The model API hosts allowed when the config names none.
pub const DEFAULT_MODEL_HOSTS: &[&str] = &["api.anthropic.com"];

/// The proxy's default bind address: loopback, so an unconfigured host never
/// exposes the proxy on a bridge by accident.
pub const DEFAULT_BIND: &str = "127.0.0.1:8889";

/// What an agent container needs to reach the proxy and nothing else: the
/// bridge to attach to and the proxy endpoint to point `HTTPS_PROXY` at.
///
/// A route exists only when the operator configured BOTH, so a half-configured
/// host keeps `--network none` instead of attaching a bridge with no proxy on it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContainerRoute {
    /// Container network (a dedicated, internal bridge) the agent is attached to.
    pub network: String,
    /// Proxy endpoint as the container sees it, e.g. `http://10.88.0.1:8889`.
    pub proxy_endpoint: String,
}

impl ContainerRoute {
    /// The container environment that sends model traffic through the proxy.
    ///
    /// Both the upper- and lower-case spellings are emitted because agent CLIs
    /// and the libraries they use disagree on which they read. `NO_PROXY` keeps
    /// loopback direct so an in-container service is never tunnelled out.
    #[must_use]
    pub fn env(&self) -> Vec<(String, String)> {
        let endpoint = self.proxy_endpoint.clone();
        [
            ("HTTPS_PROXY", endpoint.as_str()),
            ("https_proxy", endpoint.as_str()),
            ("HTTP_PROXY", endpoint.as_str()),
            ("http_proxy", endpoint.as_str()),
            ("NO_PROXY", "localhost,127.0.0.1"),
            ("no_proxy", "localhost,127.0.0.1"),
        ]
        .into_iter()
        .map(|(key, value)| (key.to_string(), value.to_string()))
        .collect()
    }
}

/// The on-disk shape of the `[model_egress]` table.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct ModelEgressTable {
    #[serde(default)]
    bind: Option<String>,
    #[serde(default)]
    network: Option<String>,
    #[serde(default)]
    proxy_endpoint: Option<String>,
    #[serde(default)]
    allow_hosts: Option<Vec<String>>,
    #[serde(default)]
    allow_suffixes: Option<Vec<String>>,
}

/// The whole file: one `[model_egress]` table, everything else rejected so a
/// typo in a key name fails loudly instead of silently widening the allow-list.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfigFile {
    #[serde(default)]
    model_egress: ModelEgressTable,
}

/// Resolved model-egress configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelEgressConfig {
    /// Address the proxy listens on (the bridge-side address of the host).
    pub bind: String,
    /// Container network the agent is attached to; empty means none.
    pub network: String,
    /// Proxy endpoint as the container sees it; empty means none.
    pub proxy_endpoint: String,
    /// Exact model API hosts the proxy forwards to.
    pub allow_hosts: Vec<String>,
    /// DNS suffixes the proxy forwards to (dot-boundary matched).
    pub allow_suffixes: Vec<String>,
}

impl Default for ModelEgressConfig {
    fn default() -> Self {
        Self {
            bind: DEFAULT_BIND.to_string(),
            network: String::new(),
            proxy_endpoint: String::new(),
            allow_hosts: DEFAULT_MODEL_HOSTS
                .iter()
                .map(|h| (*h).to_string())
                .collect(),
            allow_suffixes: Vec::new(),
        }
    }
}

/// Why a model-egress config could not be resolved.
///
/// Every variant is fatal on purpose: a host that cannot read its own egress
/// policy must refuse to attach a bridge rather than guess at one.
#[derive(Debug)]
pub enum ConfigError {
    /// The configured file could not be read.
    Unreadable {
        path: PathBuf,
        source: std::io::Error,
    },
    /// The file is not valid TOML, or carries unknown keys.
    Malformed { path: PathBuf, message: String },
}

impl std::fmt::Display for ConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConfigError::Unreadable { path, source } => {
                write!(
                    f,
                    "cannot read model-egress config {}: {source}",
                    path.display()
                )
            }
            ConfigError::Malformed { path, message } => {
                write!(
                    f,
                    "invalid model-egress config {}: {message}",
                    path.display()
                )
            }
        }
    }
}

impl std::error::Error for ConfigError {}

impl ModelEgressConfig {
    /// Parse a config from TOML text.
    ///
    /// Missing keys keep their default, so a file that only sets `allow_hosts`
    /// still gets the default bind address.
    ///
    /// # Errors
    /// Returns [`ConfigError::Malformed`] when the text is not valid TOML or
    /// carries a key outside `[model_egress]`.
    pub fn from_toml_str(path: &Path, text: &str) -> Result<Self, ConfigError> {
        let parsed: ConfigFile = toml::from_str(text).map_err(|err| ConfigError::Malformed {
            path: path.to_path_buf(),
            message: err.to_string(),
        })?;
        let table = parsed.model_egress;
        let mut config = Self::default();
        if let Some(bind) = table.bind {
            config.bind = bind;
        }
        if let Some(network) = table.network {
            config.network = network;
        }
        if let Some(endpoint) = table.proxy_endpoint {
            config.proxy_endpoint = endpoint;
        }
        if let Some(hosts) = table.allow_hosts {
            config.allow_hosts = hosts;
        }
        if let Some(suffixes) = table.allow_suffixes {
            config.allow_suffixes = suffixes;
        }
        Ok(config)
    }

    /// Read the config from `path`.
    ///
    /// # Errors
    /// Returns [`ConfigError::Unreadable`] if the file cannot be read and
    /// [`ConfigError::Malformed`] if it does not parse.
    pub fn from_path(path: &Path) -> Result<Self, ConfigError> {
        let text = std::fs::read_to_string(path).map_err(|source| ConfigError::Unreadable {
            path: path.to_path_buf(),
            source,
        })?;
        Self::from_toml_str(path, &text)
    }

    /// Resolve the config the host is running under.
    ///
    /// With `JERYU_MODEL_EGRESS_CONFIG` unset the defaults apply: the Anthropic
    /// API host only, and no container route, so agent containers stay on
    /// `--network none`. With it set the file must exist and parse — an
    /// unreadable policy is an error, never an open one.
    ///
    /// # Errors
    /// Propagates the failure of [`ModelEgressConfig::from_path`].
    pub fn load() -> Result<Self, ConfigError> {
        match std::env::var(CONFIG_PATH_ENV) {
            Ok(path) if !path.trim().is_empty() => Self::from_path(Path::new(path.trim())),
            _ => Ok(Self::default()),
        }
    }

    /// The allow-list this config enforces.
    #[must_use]
    pub fn allowlist(&self) -> Allowlist {
        Allowlist::new(
            self.allow_hosts.iter().cloned(),
            self.allow_suffixes.iter().cloned(),
        )
    }

    /// The container route, when the host configured both a bridge and an
    /// endpoint on it. `None` keeps the container on `--network none`.
    #[must_use]
    pub fn container_route(&self) -> Option<ContainerRoute> {
        let network = self.network.trim();
        let endpoint = self.proxy_endpoint.trim();
        if network.is_empty() || endpoint.is_empty() {
            return None;
        }
        Some(ContainerRoute {
            network: network.to_string(),
            proxy_endpoint: endpoint.to_string(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> ModelEgressConfig {
        ModelEgressConfig::from_toml_str(Path::new("test.toml"), text)
            .unwrap_or_else(|err| panic!("{err}"))
    }

    #[test]
    fn default_allows_only_the_anthropic_api_host() {
        let allow = ModelEgressConfig::default().allowlist();
        assert!(allow.permits("api.anthropic.com"));
        assert!(!allow.permits("api.openai.com"));
        assert!(!allow.permits("github.com"));
        assert!(!allow.permits("evil.example.com"));
    }

    #[test]
    fn default_config_has_no_container_route() {
        // No bridge configured means the agent container keeps --network none.
        assert_eq!(ModelEgressConfig::default().container_route(), None);
    }

    #[test]
    fn configured_allow_list_replaces_the_default_host() {
        let config = parse(
            r#"
            [model_egress]
            allow_hosts = ["api.example-model.test"]
            "#,
        );
        let allow = config.allowlist();
        assert!(allow.permits("api.example-model.test"));
        assert!(
            !allow.permits("api.anthropic.com"),
            "a configured list replaces the default, it does not extend it"
        );
        assert_eq!(config.bind, DEFAULT_BIND, "unset keys keep their default");
    }

    #[test]
    fn suffix_rules_match_on_a_dot_boundary() {
        let config = parse(
            r#"
            [model_egress]
            allow_hosts = []
            allow_suffixes = ["models.example.test"]
            "#,
        );
        let allow = config.allowlist();
        assert!(allow.permits("models.example.test"));
        assert!(allow.permits("eu.models.example.test"));
        assert!(!allow.permits("notmodels.example.test"));
        assert!(!allow.permits("models.example.test.attacker.com"));
    }

    #[test]
    fn empty_allow_hosts_denies_everything() {
        let config = parse(
            r#"
            [model_egress]
            allow_hosts = []
            "#,
        );
        let allow = config.allowlist();
        assert!(!allow.permits("api.anthropic.com"));
    }

    #[test]
    fn a_bridge_and_endpoint_yield_a_container_route() {
        let config = parse(
            r#"
            [model_egress]
            bind = "10.88.0.1:8889"
            network = "jeryu-model-egress"
            proxy_endpoint = "http://10.88.0.1:8889"
            "#,
        );
        let route = config
            .container_route()
            .unwrap_or_else(|| panic!("expected a route"));
        assert_eq!(route.network, "jeryu-model-egress");
        assert_eq!(route.proxy_endpoint, "http://10.88.0.1:8889");
        assert_eq!(config.bind, "10.88.0.1:8889");
    }

    #[test]
    fn a_bridge_without_an_endpoint_yields_no_route() {
        // Attaching a bridge with no proxy on it would widen the container's
        // reach without giving it model egress, so it must not happen.
        let config = parse(
            r#"
            [model_egress]
            network = "jeryu-model-egress"
            "#,
        );
        assert_eq!(config.container_route(), None);
    }

    #[test]
    fn an_endpoint_without_a_bridge_yields_no_route() {
        let config = parse(
            r#"
            [model_egress]
            proxy_endpoint = "http://10.88.0.1:8889"
            "#,
        );
        assert_eq!(config.container_route(), None);
    }

    #[test]
    fn unknown_keys_are_rejected() {
        let err = ModelEgressConfig::from_toml_str(
            Path::new("test.toml"),
            "[model_egress]\nallow_host = [\"api.anthropic.com\"]\n",
        )
        .err()
        .unwrap_or_else(|| panic!("a misspelled key must fail the load"));
        assert!(matches!(err, ConfigError::Malformed { .. }), "{err}");
    }

    #[test]
    fn a_missing_file_is_an_error_not_an_open_policy() {
        let err = ModelEgressConfig::from_path(Path::new("/nonexistent/jeryu-model-egress.toml"))
            .err()
            .unwrap_or_else(|| panic!("a missing configured file must fail the load"));
        assert!(matches!(err, ConfigError::Unreadable { .. }), "{err}");
    }

    #[test]
    fn route_env_points_both_spellings_at_the_proxy_and_keeps_loopback_direct() {
        let route = ContainerRoute {
            network: "jeryu-model-egress".to_string(),
            proxy_endpoint: "http://10.88.0.1:8889".to_string(),
        };
        let env = route.env();
        for key in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"] {
            assert!(
                env.iter()
                    .any(|(k, v)| k == key && v == "http://10.88.0.1:8889"),
                "env: {env:?}"
            );
        }
        assert!(
            env.iter()
                .any(|(k, v)| k == "NO_PROXY" && v.contains("127.0.0.1"))
        );
    }
}
