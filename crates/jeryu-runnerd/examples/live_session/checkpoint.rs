//! Two real VMs; an encrypted workspace survives and runtime tmpfs does not.
use super::*;
use jeryu_runner_microvm::supervisor::Node;

pub fn run(
    service: &SessionService,
    node: &Node,
    mut lease: SessionLease,
    main_sync: bool,
) -> Result<()> {
    let first_context = lease.context.clone();
    let first = DispatchEngine::new().dispatch_managed_session(service, lease.clone())?;
    wait_build(&first)?;
    let initial_head = first
        .snapshot(OWNER)?
        .workspace
        .map(|ready| ready.head_revision);
    if main_sync {
        apply(&first, &first_context, ControlCommand::Input { bytes:
            b"printf 'USER_COMMIT' > committed.txt; git add committed.txt; git -c user.name=Fixture -c user.email=fixture@jeryu.invalid commit -qm 'User work'; printf 'INDEX_PERSISTED\\n' > retained.txt; git add retained.txt; printf 'UNSTAGED_PERSISTED\\n' >> retained.txt; printf 'UNTRACKED_PERSISTED' > untracked.txt; printf '*.ignored\\n' > .gitignore; printf 'IGNORED_PERSISTED' > cache.ignored; printf '\\nDIRTY_STATE_CREATED\\n'\n".to_vec() })?;
        wait_output(&first, b"DIRTY_STATE_CREATED\r", Duration::from_secs(5))?;
    }
    apply(&first, &first_context, ControlCommand::Input { bytes:
        b"printf 'WORKSPACE_PERSISTED' > workspace-marker.txt; printf 'TMPFS_SENTINEL' > /run/agent-home/runtime-marker; printf 'TMPFS_SENTINEL' > /tmp/runtime-marker; sync; printf '\\nCHECKPOINT_WRITES_VERIFIED\\n'\n".to_vec() })?;
    wait_output(
        &first,
        b"CHECKPOINT_WRITES_VERIFIED\r",
        Duration::from_secs(5),
    )?;
    apply(&first, &first_context, ControlCommand::Stop)?;
    let checkpoint = first
        .snapshot(OWNER)?
        .checkpoint
        .ok_or("checkpoint absent after applied stop")?;
    let manifest = node.checkpoints().manifest(&checkpoint)?;
    if !manifest.filesystem_flushed {
        return Err("guest filesystem flush was not acknowledged".into());
    }
    let retention = manifest.expires_at_unix_millis - manifest.created_at_unix_millis;
    if retention != 7 * 24 * 60 * 60 * 1000 {
        return Err("retention is not seven days".into());
    }
    assert_journal_empty()?;
    lease.context.generation += 1;
    lease.context.run_id = "fixture-resume-run".into();
    lease.context.lease_id = "fixture-resume-lease".into();
    lease.context.lease_epoch += 1;
    lease.checkpoint = Some(checkpoint.clone());
    lease.issued_at_unix_millis = u64::try_from(now_ms())?;
    lease.expires_at_unix_millis = lease.issued_at_unix_millis + 120000;
    if main_sync {
        let workspace = manifest
            .workspace
            .as_ref()
            .ok_or("checkpoint Git receipt missing")?;
        if initial_head.as_ref() == Some(&workspace.head_revision) {
            return Err("freeze did not capture the user's new commit".into());
        }
        source::configure(&mut lease, "resume-main")?;
        lease.context.source_revision = workspace.head_revision.clone();
    }
    lease.context.job_digest = lease.job_digest()?;
    authority::sign(&mut lease)?;
    let mut other_user = lease.clone();
    other_user.context.owner_id = "user/other-user".into();
    other_user.context.job_digest = other_user.job_digest()?;
    authority::sign(&mut other_user)?;
    match DispatchEngine::new().dispatch_managed_session(service, other_user) {
        Err(error) if error.code() == "checkpoint_resume_fenced" => (),
        _ => return Err("cross-user checkpoint reuse was not fenced".into()),
    }
    assert_journal_empty()?;
    let second_context = lease.context.clone();
    let second = DispatchEngine::new().dispatch_managed_session(service, lease)?;
    wait_build(&second)?;
    if main_sync {
        apply(&second, &second_context, ControlCommand::Input { bytes:
            b"test \"$(git show :retained.txt)\" = INDEX_PERSISTED && /bin/grep -q UNSTAGED_PERSISTED retained.txt && test \"$(cat untracked.txt)\" = UNTRACKED_PERSISTED && test \"$(cat cache.ignored)\" = IGNORED_PERSISTED && test -f next-main.txt && test \"$(git show HEAD:committed.txt)\" = USER_COMMIT && git merge-base --is-ancestor refs/jeryu/main HEAD && git show refs/jeryu/checkpoints/generation-1:retained.txt | /bin/grep -q UNSTAGED_PERSISTED && test \"$(git show refs/jeryu/checkpoints/generation-1^2:retained.txt)\" = INDEX_PERSISTED && test \"$(git show refs/jeryu/checkpoints/generation-1^3:untracked.txt)\" = UNTRACKED_PERSISTED && printf '\\nDIRTY_MAIN_RESUME_VERIFIED\\n'\n".to_vec() })?;
        wait_output(
            &second,
            b"DIRTY_MAIN_RESUME_VERIFIED\r",
            Duration::from_secs(5),
        )?;
    }
    apply(&second, &second_context, ControlCommand::Input { bytes:
        b"test \"$(cat workspace-marker.txt)\" = WORKSPACE_PERSISTED && test ! -e /run/agent-home/runtime-marker && test ! -e /tmp/runtime-marker && printf '\\nWORKSPACE_RESUME_VERIFIED\\n'\n".to_vec() })?;
    wait_output(
        &second,
        b"WORKSPACE_RESUME_VERIFIED\r",
        Duration::from_secs(5),
    )?;
    apply(&second, &second_context, ControlCommand::Stop)?;
    let successor = second
        .snapshot(OWNER)?
        .checkpoint
        .ok_or("successor checkpoint absent")?;
    if checkpoint == successor || node.checkpoints().manifest(&checkpoint)? != manifest {
        return Err("resume mutated predecessor checkpoint".into());
    }
    let successor_manifest = node.checkpoints().manifest(&successor)?;
    if successor_manifest.context.generation != 2 || !successor_manifest.filesystem_flushed {
        return Err("successor checkpoint generation or flush invalid".into());
    }
    // Fixture-owned data is discarded explicitly; this is not merge cleanup.
    node.checkpoints().destroy(&checkpoint, &first_context)?;
    node.checkpoints().destroy(&successor, &second_context)?;
    node.checkpoints().destroy(&successor, &second_context)?;
    assert_journal_empty()?;
    println!(
        "checkpoint_resume=passed real_vms=2 encrypted_workspace=true fresh_tmpfs=true owner_fenced=true predecessor_immutable=true retention_days=7 fixture_cleanup_idempotent=true"
    );
    if main_sync {
        println!(
            "dirty_main_resume=passed user_commit=true staged=true unstaged=true untracked=true ignored=true newer_main=true"
        );
    }
    Ok(())
}
fn wait_build(handle: &SessionHandle) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let snapshot = handle.snapshot(OWNER)?;
        if snapshot.phase != RuntimePhase::Running {
            return Err("resumed VM failed".into());
        }
        if let Some(agent) = snapshot
            .channels
            .iter()
            .find(|channel| channel.channel_id == "agent")
            && agent.exited
        {
            if agent.exit_code != Some(0) {
                return Err("guest build failed".into());
            }
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err("guest build timeout".into());
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}
fn assert_journal_empty() -> Result<()> {
    if fs::read_dir(Path::new(ROOT).join("node/records"))?
        .next()
        .is_some()
    {
        return Err("stopped VM retained an active resource".into());
    }
    Ok(())
}
