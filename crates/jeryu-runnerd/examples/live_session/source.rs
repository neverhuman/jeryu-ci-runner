//! Local source fixtures; all application work runs inside the managed VM.
use super::*;
use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SourceFixture {
    source_revision: String,
    workspace: WorkspaceSource,
}

pub fn configure(lease: &mut SessionLease, mode: &str) -> Result<()> {
    if mode == "empty" {
        return Ok(());
    }
    if mode == "uploaded" {
        let path = Path::new(ROOT).join("uploaded-source-inputs.json");
        use std::os::unix::fs::MetadataExt;
        let metadata = fs::symlink_metadata(&path)?;
        if !metadata.is_file()
            || metadata.uid() != 0
            || metadata.nlink() != 1
            || metadata.mode() & 0o077 != 0
            || metadata.len() > 16384
        {
            return Err("uploaded fixture input custody denied".into());
        }
        let input: SourceFixture = serde_json::from_slice(&fs::read(path)?)?;
        lease.context.source_revision = input.source_revision;
        lease.workspace = input.workspace;
        lease.context.job_digest = lease.job_digest()?;
        lease.validate()?;
        return Ok(());
    }
    if !["main-sync", "conflict", "mismatch", "resume-main"].contains(&mode) {
        return Err("unsupported live fixture mode".into());
    }
    let inputs: BTreeMap<String, SourceFixture> =
        serde_json::from_slice(&fs::read(Path::new(ROOT).join("source-inputs.json"))?)?;
    let input = inputs.get(mode).ok_or("source fixture absent")?;
    lease.context.source_revision = input.source_revision.clone();
    lease.workspace = input.workspace.clone();
    lease.context.job_digest = lease.job_digest()?;
    lease.validate()?;
    Ok(())
}

pub fn conflict(
    handle: &SessionHandle,
    context: &SessionContext,
    node: &jeryu_runner_microvm::supervisor::Node,
) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(3);
    while !handle
        .snapshot(OWNER)?
        .channels
        .iter()
        .any(|c| c.channel_id == "shell" && c.started)
    {
        if Instant::now() >= deadline {
            return Err("conflict companion shell did not start".into());
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let snapshot = handle.snapshot(OWNER)?;
    if snapshot.phase != RuntimePhase::RebaseRequired
        || snapshot
            .workspace
            .as_ref()
            .is_none_or(|ready| ready.sync_state != WorkspaceSyncState::RebaseRequired)
        || snapshot
            .channels
            .iter()
            .any(|channel| channel.channel_id == "agent" && channel.started)
    {
        return Err("conflict did not preserve a shell-only rebase-required session".into());
    }
    apply(handle, context, ControlCommand::Input { bytes:
        b"test -d .git/rebase-merge && git diff --name-only --diff-filter=U | /bin/grep -q tracked.txt && printf '\\nREBASE_CONFLICT_RETAINED\\n'\n".to_vec() })?;
    wait_output(
        handle,
        b"REBASE_CONFLICT_RETAINED\r",
        Duration::from_secs(5),
    )?;
    handle.stop(OWNER)?;
    let deadline = Instant::now() + Duration::from_secs(120);
    loop {
        let snapshot = handle.snapshot(OWNER)?;
        if snapshot.phase == RuntimePhase::Stopped {
            if snapshot.reason.as_deref() != Some("main_sync_conflict") {
                return Err("direct conflict stop lost its context".into());
            }
            break;
        }
        if snapshot.phase == RuntimePhase::Failed || Instant::now() > deadline {
            return Err("direct conflict stop failed during retention".into());
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let checkpoint = handle
        .snapshot(OWNER)?
        .checkpoint
        .ok_or("conflict checkpoint missing")?;
    let manifest = node.checkpoints().manifest(&checkpoint)?;
    if !manifest.filesystem_flushed
        || manifest
            .workspace
            .as_ref()
            .is_none_or(|ready| ready.sync_state != WorkspaceSyncState::RebaseRequired)
    {
        return Err("conflict was not frozen and retained".into());
    }
    node.checkpoints().destroy(&checkpoint, context)?;
    if fs::read_dir(Path::new(ROOT).join("node/records"))?
        .next()
        .is_some()
    {
        return Err("conflict VM survived stop".into());
    }
    println!(
        "main_sync_conflict=passed phase=rebase_required shell_attachable=true agent_started=false direct_stop=true stopped=true encrypted_checkpoint=true vm_destroyed=true"
    );
    Ok(())
}

pub fn verify(handle: &SessionHandle, context: &SessionContext) -> Result<()> {
    let ready = handle
        .snapshot(OWNER)?
        .workspace
        .ok_or("missing main-sync receipt")?;
    if ready.source_revision != context.source_revision
        || ready.source_revision == ready.head_revision
    {
        return Err("retained work was not actually rebased".into());
    }
    apply(handle, context, ControlCommand::Input { bytes: b"test -f main-only.txt && test -f retained.txt && git merge-base --is-ancestor refs/jeryu/main HEAD && printf '\\nMAIN_SYNC_VERIFIED\\n'\n".to_vec() })?;
    wait_output(handle, b"MAIN_SYNC_VERIFIED\r", Duration::from_secs(5))?;
    apply(handle, context, ControlCommand::Input { bytes: b"case $(git symbolic-ref HEAD) in refs/heads/jeryu/session/*) ;; *) exit 17 ;; esac; ! git update-ref refs/jeryu/main HEAD >/dev/null 2>&1 && ! /bin/mv .git/refs/jeryu .git/refs/jeryu-moved >/dev/null 2>&1 && ! /bin/mv .git/refs .git/refs-moved >/dev/null 2>&1 && ! /bin/mv .git .git-moved >/dev/null 2>&1 && ! /bin/mv /workspace/repo /workspace/repo-moved >/dev/null 2>&1 && git add main.c && git -c user.name=Fixture -c user.email=fixture@invalid commit -qm ordinary-guest-commit && printf '\\nAUTHORITY_REFS_READONLY_BRANCH_WRITABLE\\n'\n".to_vec() })?;
    wait_output(
        handle,
        b"AUTHORITY_REFS_READONLY_BRANCH_WRITABLE\r",
        Duration::from_secs(5),
    )?;
    println!(
        "main_sync=passed source={} main={} rebased_head={}",
        ready.source_revision, ready.main_revision, ready.head_revision
    );
    Ok(())
}

/// The uid-1000 shell lies to ordinary Git without changing the protected refs.
/// Trusted freeze must ignore BOTH replacement refs and the legacy graft file.
pub fn graph_override(
    handle: &SessionHandle,
    context: &SessionContext,
    node: &jeryu_runner_microvm::supervisor::Node,
) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let snapshot = handle.snapshot(OWNER)?;
        if snapshot
            .channels
            .iter()
            .any(|c| c.channel_id == "agent" && c.exited)
            && snapshot
                .channels
                .iter()
                .any(|c| c.channel_id == "shell" && c.started)
        {
            break;
        }
        if Instant::now() >= deadline {
            return Err("graph fixture build or shell timeout".into());
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    apply(handle, context, ControlCommand::Input { bytes:
        b"git checkout -q -B graph-attack refs/jeryu/base && ! git merge-base --is-ancestor refs/jeryu/main HEAD && git replace --graft HEAD refs/jeryu/main && mkdir -p .git/info && printf '%s %s\\n' \"$(git rev-parse HEAD)\" \"$(git rev-parse refs/jeryu/main)\" > .git/info/grafts && git merge-base --is-ancestor refs/jeryu/main HEAD && printf '\\nGUEST_GRAPH_SPOOF_VERIFIED\\n'\n".to_vec() })?;
    wait_output(
        handle,
        b"GUEST_GRAPH_SPOOF_VERIFIED\r",
        Duration::from_secs(5),
    )?;
    apply(handle, context, ControlCommand::Stop)?;
    let snapshot = handle.snapshot(OWNER)?;
    let reference = snapshot.checkpoint.ok_or("graph workspace not retained")?;
    let manifest = node.checkpoints().manifest(&reference)?;
    if !manifest.filesystem_flushed
        || manifest
            .workspace
            .as_ref()
            .is_none_or(|ready| ready.sync_state != WorkspaceSyncState::RebaseRequired)
    {
        return Err("trusted main ancestry was fooled by guest graph metadata".into());
    }
    node.checkpoints().destroy(&reference, context)?;
    if fs::read_dir(Path::new(ROOT).join("node/records"))?
        .next()
        .is_some()
    {
        return Err("graph fixture VM survived stop".into());
    }
    println!(
        "graph_override=passed guest_false_ancestry=true trusted_true_ancestry=true encrypted_workspace_preserved=true vm_destroyed=true"
    );
    Ok(())
}
