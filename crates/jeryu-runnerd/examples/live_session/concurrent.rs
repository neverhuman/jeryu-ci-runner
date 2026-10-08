//! Three independent live guests under an explicit trusted canary quota.
use super::*;

pub fn run(
    service: &SessionService,
    node: &jeryu_runner_microvm::supervisor::Node,
    original: SessionLease,
) -> Result<()> {
    let mut handles = Vec::new();
    let leases = (0..3)
        .map(|index| {
            let mut lease = original.clone();
            lease.context.session_id = format!("concurrent-session-{index}");
            lease.context.run_id = format!("concurrent-run-{index}");
            lease.context.lease_id = format!("concurrent-lease-{index}");
            lease.context.job_digest = lease.job_digest().expect("valid fixture job");
            authority::sign(&mut lease).expect("fixture lease signing");
            lease
        })
        .collect::<Vec<_>>();
    let started = Instant::now();
    let results = std::thread::scope(|scope| {
        let joins = leases
            .into_iter()
            .map(|lease| {
                scope.spawn(move || {
                    let context = lease.context.clone();
                    DispatchEngine::new()
                        .dispatch_managed_session(service, lease)
                        .map(|handle| (context, handle))
                })
            })
            .collect::<Vec<_>>();
        joins
            .into_iter()
            .map(|join| join.join().expect("fixture launch thread"))
            .collect::<Vec<_>>()
    });
    for result in results {
        handles.push(result?);
    }
    println!("parallel_boot_ms={}", started.elapsed().as_millis());
    let mut fourth = original;
    fourth.context.session_id = "concurrent-session-fourth".into();
    fourth.context.job_digest = fourth.job_digest()?;
    authority::sign(&mut fourth)?;
    if !matches!(service.start(fourth), Err(error) if error.code() == "session_owner_capacity") {
        return Err("canary owner quota did not reject fourth VM".into());
    }
    let records = fs::read_dir(Path::new(ROOT).join("node/records"))?.count();
    if records != 3 {
        return Err("three sessions do not have three VM resources".into());
    }
    let deadline = Instant::now() + Duration::from_secs(20);
    for (context, handle) in &handles {
        loop {
            let snapshot = handle.snapshot(OWNER)?;
            let agent = snapshot
                .channels
                .iter()
                .find(|channel| channel.channel_id == "agent")
                .ok_or("missing agent channel")?;
            if agent.exited {
                if agent.exit_code != Some(0) {
                    return Err("concurrent guest build failed".into());
                }
                break;
            }
            if snapshot.phase != RuntimePhase::Running || Instant::now() >= deadline {
                return Err("concurrent session failed or timed out".into());
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        apply(
            handle,
            context,
            ControlCommand::Input {
                bytes: format!(
                    "printf '%s\\n' '{}' > session-id.txt; printf '\\nCONCURRENT_VERIFIED\\n'\n",
                    context.session_id
                )
                .into_bytes(),
            },
        )?;
        wait_output(handle, b"CONCURRENT_VERIFIED\r", Duration::from_secs(5))?;
    }
    for (context, handle) in &handles {
        apply(handle, context, ControlCommand::Input {
            bytes: format!("test \"$(cat session-id.txt)\" = '{}' && printf '\\nPRIVATE_WORKSPACE_VERIFIED\\n'\n", context.session_id).into_bytes(),
        })?;
        wait_output(
            handle,
            b"PRIVATE_WORKSPACE_VERIFIED\r",
            Duration::from_secs(5),
        )?;
        apply(handle, context, ControlCommand::Stop)?;
        if handle.snapshot(OWNER)?.phase != RuntimePhase::Stopped {
            return Err("concurrent stop did not clean its VM".into());
        }
        let checkpoint = handle
            .snapshot(OWNER)?
            .checkpoint
            .ok_or("concurrent checkpoint missing")?;
        node.checkpoints().destroy(&checkpoint, context)?;
    }
    if fs::read_dir(Path::new(ROOT).join("node/records"))?
        .next()
        .is_some()
    {
        return Err("concurrent VM resources retained".into());
    }
    println!(
        "concurrent_sessions=passed scope=development count=3 owner=one private_workspaces=true quota_enforced=true vm_destroyed=true provider_auth_qualified=false"
    );
    Ok(())
}
