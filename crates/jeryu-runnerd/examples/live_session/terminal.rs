//! Model-free real-KVM writer fencing and headless terminal qualification.
use super::*;
use sha2::{Digest, Sha256};

pub fn run(
    handle: &SessionHandle,
    context: &SessionContext,
    node: &jeryu_runner_microvm::supervisor::Node,
) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !handle
        .snapshot(OWNER)?
        .channels
        .iter()
        .any(|c| c.channel_id == "shell" && c.started)
    {
        if Instant::now() > deadline {
            return Err("shell start timed out".into());
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    // A delegated controller is fenced inside the actual guest on revocation.
    handle.grant(OWNER, "fixture-controller", Some(AccessGrant::Controller))?;
    let delegate = handle.acquire_control("fixture-controller", "delegate-client", &[], false)?;
    send(
        handle,
        "fixture-controller",
        &delegate,
        ControlCommand::Input {
            bytes: b"stty -echo; printf '\\nDELEGATE_READY\\n'\n".to_vec(),
        },
    )?;
    wait_output(handle, b"DELEGATE_READY\r", Duration::from_secs(5))?;
    handle.grant(OWNER, "fixture-controller", Some(AccessGrant::Viewer))?;
    if submit(
        handle,
        "fixture-controller",
        &delegate,
        ControlCommand::Input {
            bytes: b"forbidden\n".to_vec(),
        },
    )
    .is_ok()
    {
        return Err("revoked delegate wrote to guest".into());
    }

    let headless = handle.acquire_control(OWNER, "headless-client", &[], false)?;
    let expected = hash(b"\x1b[1;1R");
    let command = format!(
        "stty raw -echo; printf '\\033[2J\\033[H\\033[6n'; /usr/bin/busybox dd bs=1 count=6 of=cpr.bin 2>/dev/null; stty sane; stty -echo; set -- $(/usr/bin/busybox sha256sum cpr.bin); test \"$1\" = {expected} && printf '\\nHEADLESS_CPR_VERIFIED\\n'\n"
    );
    send(
        handle,
        OWNER,
        &headless,
        ControlCommand::Input {
            bytes: command.into_bytes(),
        },
    )?;
    wait_output(handle, b"HEADLESS_CPR_VERIFIED\r", Duration::from_secs(5))?;
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let screen = handle.screen(OWNER, "shell")?;
        if screen.screen.text.contains("HEADLESS_CPR_VERIFIED") {
            screen.validate()?;
            break;
        }
        if Instant::now() > deadline {
            return Err("headless screen was not updated".into());
        }
        std::thread::sleep(Duration::from_millis(20));
    }

    let tty = handle.acquire_control(OWNER, "tty-client", &["shell".into()], true)?;
    if handle
        .acquire_control(OWNER, "second-client", &[], false)
        .is_ok()
    {
        return Err("same-user clients shared writer".into());
    }
    let renew = handle.acquire_control(OWNER, "tty-client", &["shell".into()], false)?;
    if renew.epoch != tty.epoch {
        return Err("renewal changed writer epoch".into());
    }
    let expected = hash(b"\x1b[9;8R");
    let command = format!(
        "stty raw -echo; printf '\\033[2J\\033[H\\033[6n'; /usr/bin/busybox dd bs=1 count=6 of=tty-cpr.bin 2>/dev/null; stty sane; stty -echo; set -- $(/usr/bin/busybox sha256sum tty-cpr.bin); test \"$1\" = {expected} && printf '\\nREAL_TERMINAL_REPLY_VERIFIED\\n'\n"
    );
    let cursor = handle
        .snapshot(OWNER)?
        .channels
        .iter()
        .find(|c| c.channel_id == "shell")
        .unwrap()
        .cursor;
    send(
        handle,
        OWNER,
        &renew,
        ControlCommand::Input {
            bytes: command.into_bytes(),
        },
    )?;
    let deadline = Instant::now() + Duration::from_secs(3);
    let mut raw = vec![];
    let mut after = cursor;
    while !raw.windows(4).any(|b| b == b"\x1b[6n") {
        for frame in handle.replay(OWNER, "shell", after, 128)? {
            after = frame.sequence;
            raw.extend(frame.bytes);
        }
        if Instant::now() > deadline {
            return Err("query was not passed to real terminal".into());
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    std::thread::sleep(Duration::from_millis(250));
    let tty = handle.acquire_control(OWNER, "tty-client", &["shell".into()], false)?;
    send(
        handle,
        OWNER,
        &tty,
        ControlCommand::Input {
            bytes: b"\x1b[9;8R".to_vec(),
        },
    )?;
    wait_output(
        handle,
        b"REAL_TERMINAL_REPLY_VERIFIED\r",
        Duration::from_secs(5),
    )?;

    let old = handle.acquire_control(OWNER, "slow-client", &[], true)?;
    send(handle, OWNER, &old, ControlCommand::Input { bytes: b"stty raw -echo; printf '\\nHANDOFF_INPUT_READY\\n'; sleep 2; /usr/bin/busybox timeout 1 /bin/cat > handoff.bin; stty sane; stty -echo; n=$(/usr/bin/busybox wc -c < handoff.bin); test $n -lt 32768 && printf '\\nOLD_INPUT_CANCELLED\\n'\n".to_vec() })?;
    wait_output(handle, b"HANDOFF_INPUT_READY\n", Duration::from_secs(5))?;
    let old = handle.acquire_control(OWNER, "slow-client", &[], false)?;
    let pending = submit(
        handle,
        OWNER,
        &old,
        ControlCommand::Input {
            bytes: vec![b'X'; MAX_TERMINAL_BYTES],
        },
    )?;
    std::thread::sleep(Duration::from_millis(100));
    let next = handle.acquire_control(OWNER, "new-client", &[], true)?;
    if next.epoch <= old.epoch {
        return Err("handoff did not advance epoch".into());
    }
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let ack = handle.acknowledgement(OWNER, &pending.request_id)?;
        ack.validate_for(&pending)?;
        if ack.state == ControlState::Rejected {
            if ack.reason != "input_fenced_or_closed_after_partial_input" {
                return Err("unexpected cancelled input reason".into());
            }
            break;
        }
        if ack.state == ControlState::Applied || Instant::now() > deadline {
            return Err("old input survived handoff barrier".into());
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    wait_output(handle, b"OLD_INPUT_CANCELLED\r", Duration::from_secs(6))?;
    if submit(
        handle,
        OWNER,
        &old,
        ControlCommand::Resize { rows: 20, cols: 60 },
    )
    .is_ok()
    {
        return Err("old client retained control".into());
    }
    let next = handle.acquire_control(OWNER, "new-client", &[], false)?;
    send(handle, OWNER, &next, ControlCommand::Stop)?;
    let snapshot = handle.snapshot(OWNER)?;
    if snapshot.phase != RuntimePhase::Stopped
        || fs::read_dir(Path::new(ROOT).join("node/records"))?
            .next()
            .is_some()
    {
        return Err("terminal fixture VM not destroyed".into());
    }
    if let Some(checkpoint) = snapshot.checkpoint {
        node.checkpoints().destroy(&checkpoint, context)?;
    }
    println!(
        "control_terminal=passed scope=development guest_v2=true same_owner_single_writer=true renew=true revoked_delegate=true headless_cpr=true raw_query_passthrough=true screen=true partial_input_cancelled=true vm_destroyed=true"
    );
    Ok(())
}
fn submit(
    handle: &SessionHandle,
    actor: &str,
    lease: &ControllerLease,
    command: ControlCommand,
) -> Result<ControlRequest> {
    let request = ControlRequest {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-control".into(),
        context: lease.context.clone(),
        request_id: format!("terminal-{}-{}", lease.epoch, lease.next_sequence),
        channel_id: "shell".into(),
        controller_id: lease.controller_id.clone(),
        control_lease_epoch: lease.epoch,
        control_sequence: lease.next_sequence,
        command,
    };
    handle
        .control(actor, request.clone())?
        .validate_for(&request)?;
    Ok(request)
}
fn send(
    handle: &SessionHandle,
    actor: &str,
    lease: &ControllerLease,
    command: ControlCommand,
) -> Result<()> {
    let stop = matches!(command, ControlCommand::Stop);
    let request = submit(handle, actor, lease, command)?;
    let deadline = Instant::now() + Duration::from_secs(if stop { 30 } else { 5 });
    loop {
        let ack = handle.acknowledgement(actor, &request.request_id)?;
        ack.validate_for(&request)?;
        if ack.state == ControlState::Applied {
            return Ok(());
        }
        if ack.state == ControlState::Rejected || Instant::now() > deadline {
            return Err("terminal control not applied".into());
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}
fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
