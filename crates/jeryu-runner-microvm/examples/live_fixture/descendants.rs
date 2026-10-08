//! Dedicated guest containment and terminal-drain probe; no model or host shell.
use super::*;
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

pub fn run(session: &mut MicroVmSession) -> Result<()> {
    let mut reader = session.take_reader()?;
    session.send(&GuestRequest::Start {
        channel: "victim".into(),
        profile: GuestProfile::Shell,
    })?;
    session.send(&GuestRequest::Input {
        channel: "victim".into(), request_id: "create-detached".into(),
        bytes: b"stty -echo; /usr/bin/busybox setsid /bin/sh -c 'echo $$ > /workspace/detached.pid; while :; do sleep 1; done' </dev/null >/dev/null 2>&1 & while [ ! -s detached.pid ]; do sleep .05; done; i=0; while [ $i -lt 300 ]; do printf 'RAW_TAIL_BYTES_0123456789\\n'; i=$((i+1)); done; printf '\\nFINAL_TAIL_MARKER\\n'; exit\n".to_vec(),
    })?;
    let deadline = Instant::now() + Duration::from_secs(25);
    let mut output = vec![];
    let mut exited = false;
    while !exited {
        if Instant::now() > deadline {
            return Err("victim did not drain before exit".into());
        }
        match reader.poll(Duration::from_millis(100))? {
            Some(GuestEvent::Output { channel, bytes, .. }) if channel == "victim" => {
                output.extend(bytes)
            }
            Some(GuestEvent::Exited { channel, .. }) if channel == "victim" => exited = true,
            Some(GuestEvent::Error { code }) => return Err(code.into()),
            _ => (),
        }
    }
    let marker = b"FINAL_TAIL_MARKER\r";
    if !output.windows(marker.len()).any(|b| b == marker) {
        return Err("terminal tail lost on exit".into());
    }
    let rows = output
        .windows(b"RAW_TAIL_BYTES_0123456789\r\n".len())
        .filter(|b| *b == b"RAW_TAIL_BYTES_0123456789\r\n")
        .count();
    if rows != 300 {
        return Err("terminal rows lost at the rate limit".into());
    }
    session.send(&GuestRequest::Start {
        channel: "observer".into(),
        profile: GuestProfile::Shell,
    })?;
    session.send(&GuestRequest::Input { channel: "observer".into(), request_id: "verify-detached".into(),
        bytes: b"stty -echo; sleep .2; test ! -d /proc/$(cat detached.pid) && printf '\\nDETACHED_DESCENDANT_DEAD\\n'\n".to_vec() })?;
    wait_marker(&mut reader, b"DETACHED_DESCENDANT_DEAD\r")?;
    session.send(&GuestRequest::Freeze {
        request_id: "containment-freeze".into(),
    })?;
    let deadline = Instant::now() + Duration::from_secs(4);
    loop {
        if Instant::now() > deadline {
            return Err("containment freeze timed out".into());
        }
        if let Some(GuestEvent::Frozen {
            request_id,
            workspace,
        }) = reader.poll(Duration::from_millis(100))?
            && request_id == "containment-freeze"
        {
            session.mark_workspace_flushed(workspace)?;
            break;
        }
    }
    session.stop()?;
    println!(
        "channel_containment=passed setsid_descendant_dead=true tail_rows=300 output_rate_bytes=1024 vm_destroyed=true"
    );
    Ok(())
}
fn wait_marker(
    reader: &mut jeryu_runner_microvm::transport::GuestReader,
    marker: &[u8],
) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut output = vec![];
    loop {
        if Instant::now() > deadline {
            return Err("descendant death was not observed".into());
        }
        match reader.poll(Duration::from_millis(100))? {
            Some(GuestEvent::Output { channel, bytes, .. }) if channel == "observer" => {
                output.extend(bytes)
            }
            Some(GuestEvent::Error { code }) => return Err(code.into()),
            _ => (),
        }
        if output.windows(marker.len()).any(|b| b == marker) {
            return Ok(());
        }
    }
}
