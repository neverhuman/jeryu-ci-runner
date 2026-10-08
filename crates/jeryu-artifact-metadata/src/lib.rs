use jeryu_ci_ir::{ArtifactWhen, Pipeline, deterministic_hash};
use jeryu_runner_core::credguard::deny_credential_material;
use std::fmt;
use std::path::Path;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArtifactRecord {
    pub id: String,
    pub pipeline_id: String,
    pub job_id: String,
    pub name: String,
    pub paths: Vec<String>,
    pub when: ArtifactWhen,
    pub retention_days: u32,
    pub digest_hint: String,
    pub provenance_required: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ArtifactError {
    AbsolutePath { job_id: String, path: String },
    ParentTraversal { job_id: String, path: String },
    EmptyPath { job_id: String },
    OutsidePermittedRoot { job_id: String, path: String },
    CredentialMaterial { job_id: String, detail: String },
}

impl fmt::Display for ArtifactError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::AbsolutePath { job_id, path } => {
                write!(f, "artifact path for {job_id} must be relative: {path}")
            }
            Self::ParentTraversal { job_id, path } => write!(
                f,
                "artifact path for {job_id} cannot traverse parent dirs: {path}"
            ),
            Self::EmptyPath { job_id } => write!(f, "artifact path for {job_id} cannot be empty"),
            Self::OutsidePermittedRoot { job_id, path } => write!(
                f,
                "artifact path for {job_id} is outside the permitted export roots: {path}"
            ),
            Self::CredentialMaterial { job_id, detail } => {
                write!(f, "artifact path for {job_id} is refused: {detail}")
            }
        }
    }
}

impl std::error::Error for ArtifactError {}

pub fn plan_artifacts(pipeline: &Pipeline) -> Result<Vec<ArtifactRecord>, ArtifactError> {
    let mut records = Vec::new();
    for job in &pipeline.jobs {
        for artifact in &job.artifact_paths {
            validate_paths(
                &job.id,
                &artifact.paths,
                pipeline.artifact_policy.allow_absolute_paths,
                &pipeline.artifact_policy.permitted_export_roots,
            )?;
            let canonical = format!(
                "artifact|{}|{}|{}|{}|{}|{}",
                pipeline.id,
                job.id,
                artifact.name,
                artifact.when.as_str(),
                artifact.retention_days,
                artifact.paths.join(",")
            );
            records.push(ArtifactRecord {
                id: deterministic_hash(&canonical),
                pipeline_id: pipeline.id.clone(),
                job_id: job.id.clone(),
                name: artifact.name.clone(),
                paths: artifact.paths.clone(),
                when: artifact.when.clone(),
                retention_days: artifact.retention_days,
                digest_hint: deterministic_hash(&format!("digest-hint|{canonical}")),
                provenance_required: pipeline.signing_policy.provenance_required,
            });
        }
    }
    records.sort_by(|a, b| (&a.job_id, &a.name).cmp(&(&b.job_id, &b.name)));
    Ok(records)
}

/// `permitted_roots` is the configured allowlist of workspace-relative roots an
/// upload may collect from; empty adds no restriction beyond the relative-path
/// and traversal rules above (see `ArtifactPolicy::permitted_export_roots`). Credential
/// material is refused on top of the allowlist, because a per-run agent home
/// lives under the workspace and would otherwise be inside a permitted root.
fn validate_paths(
    job_id: &str,
    paths: &[String],
    allow_absolute: bool,
    permitted_roots: &[String],
) -> Result<(), ArtifactError> {
    for path in paths {
        let trimmed = path.trim();
        if trimmed.is_empty() {
            return Err(ArtifactError::EmptyPath {
                job_id: job_id.to_string(),
            });
        }
        if !allow_absolute && trimmed.starts_with('/') {
            return Err(ArtifactError::AbsolutePath {
                job_id: job_id.to_string(),
                path: path.clone(),
            });
        }
        if trimmed.split(['/', '\\']).any(|part| part == "..") {
            return Err(ArtifactError::ParentTraversal {
                job_id: job_id.to_string(),
                path: path.clone(),
            });
        }
        if !permitted_roots.is_empty()
            && !permitted_roots
                .iter()
                .any(|root| Path::new(trimmed).starts_with(root))
        {
            return Err(ArtifactError::OutsidePermittedRoot {
                job_id: job_id.to_string(),
                path: path.clone(),
            });
        }
        deny_credential_material(Path::new(trimmed)).map_err(|err| {
            ArtifactError::CredentialMaterial {
                job_id: job_id.to_string(),
                detail: err.message().to_string(),
            }
        })?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use jeryu_ci_ir::{
        ArtifactPath, ArtifactWhen, Job, Pipeline, PipelineSource, RunnerClass, Step, TrustTier,
    };

    fn pipeline_with_path(path: &str) -> Pipeline {
        let mut pipeline = Pipeline::new(
            PipelineSource::NativeToml,
            "acme/demo",
            "abc123",
            TrustTier::InternalBranch,
        );
        let mut job = Job::new("test", "test", RunnerClass::NativeRustClean);
        job.steps.push(Step::run("s", "test", "cargo test"));
        job.artifact_paths.push(ArtifactPath {
            name: "junit".to_string(),
            paths: vec![path.to_string()],
            when: ArtifactWhen::Always,
            retention_days: 14,
        });
        pipeline.jobs.push(job);
        pipeline
    }

    #[test]
    fn plans_artifact_records() -> Result<(), Box<dyn std::error::Error>> {
        let records = plan_artifacts(&pipeline_with_path("target/junit.xml"))?;
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].job_id, "test");
        Ok(())
    }

    #[test]
    fn rejects_absolute_path_by_default() {
        let result = plan_artifacts(&pipeline_with_path("/etc/passwd"));
        assert!(matches!(result, Err(ArtifactError::AbsolutePath { .. })));
    }

    #[test]
    fn rejects_parent_traversal() {
        let result = plan_artifacts(&pipeline_with_path("target/../secret"));
        assert!(matches!(result, Err(ArtifactError::ParentTraversal { .. })));
        let windows = plan_artifacts(&pipeline_with_path("target\\..\\secret"));
        assert!(matches!(
            windows,
            Err(ArtifactError::ParentTraversal { .. })
        ));
    }

    /// One upload case per credential shape. All of them are workspace-relative
    /// and traversal-free, so only the credential guard can refuse them.
    #[test]
    fn rejects_host_credential_material_in_an_upload() {
        for path in [
            ".home/.config/gh/hosts.yml",
            ".claude/.credentials.json",
            ".codex/auth.json",
            ".jekko/users/jeryu-agent/llm.env",
            "agent-auth/claude/env",
            ".git-credentials",
            "nested/.netrc",
            "nested/_netrc",
            ".ssh/known_hosts",
            "keys/id_rsa",
            "keys/id_ed25519",
            ".aws/credentials",
            ".config/gh/hosts.yml",
            ".docker/config.json",
            "state/refresh_token.json",
            "state/refresh-token",
        ] {
            for spelling in [
                path.to_string(),
                path.replace('/', "\\"),
                path.to_uppercase(),
            ] {
                let result = plan_artifacts(&pipeline_with_path(&spelling));
                assert!(
                    matches!(result, Err(ArtifactError::CredentialMaterial { .. })),
                    "{spelling} must not be uploadable: {result:?}"
                );
            }
        }
    }

    #[test]
    fn rejects_an_upload_outside_the_permitted_export_roots() {
        let mut pipeline = pipeline_with_path("fixtures/junit.xml");
        pipeline.artifact_policy.permitted_export_roots = vec!["target".to_string()];
        let result = plan_artifacts(&pipeline);
        assert!(
            matches!(result, Err(ArtifactError::OutsidePermittedRoot { .. })),
            "{result:?}"
        );

        let mut permitted = pipeline_with_path("target/junit.xml");
        permitted.artifact_policy.permitted_export_roots = vec!["target".to_string()];
        plan_artifacts(&permitted).unwrap_or_else(|err| panic!("{err}"));
    }
}
