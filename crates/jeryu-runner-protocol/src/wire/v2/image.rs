//! Test agents cannot become production entrypoints or obtain provider access.
use crate::wire::validation::{WireError, WireErrorCode};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum RuntimeImageClass {
    Production,
    Test,
}

/// Declaration is necessary but does not qualify an adapter or authentication.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum RuntimeProfile {
    Claude,
    Codex,
    Fixture,
    Grok,
    MockClaude,
    MockCodex,
    MockGrok,
    Shell,
}
impl RuntimeProfile {
    pub fn id(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Fixture => "fixture",
            Self::Grok => "grok",
            Self::MockClaude => "mock-claude",
            Self::MockCodex => "mock-codex",
            Self::MockGrok => "mock-grok",
            Self::Shell => "shell",
        }
    }
    fn test_only(self) -> bool {
        matches!(
            self,
            Self::Fixture | Self::MockClaude | Self::MockCodex | Self::MockGrok
        )
    }
}
pub(super) fn validate_profiles(
    class: RuntimeImageClass,
    profiles: &[RuntimeProfile],
) -> Result<(), WireError> {
    if profiles.is_empty()
        || profiles.len() > 8
        || !profiles.contains(&RuntimeProfile::Shell)
        || profiles.windows(2).any(|pair| pair[0].id() >= pair[1].id())
        || profiles.iter().any(|profile| {
            *profile != RuntimeProfile::Shell
                && profile.test_only() != (class == RuntimeImageClass::Test)
        })
    {
        return Err(WireError::new(
            WireErrorCode::InvalidField,
            "runtime_profiles",
        ));
    }
    Ok(())
}
