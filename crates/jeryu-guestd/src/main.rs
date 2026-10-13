//! PID 1 supervisor for the credential-free fixture runtime.
mod authority;
mod filesystem;
mod freeze;
mod groups;
mod identity;
mod input;
mod process;
mod reaper;
mod shutdown;
mod terminal;
mod workspace;
use jeryu_runner_protocol::{
    guest::{EXECUTION_PORT, GuestEvent, GuestRequest, read_frame, write_frame},
    wire::v2::{GUEST_PROTOCOL_VERSION, SessionLease, WorkspaceSyncState},
};
use jeryu_sandbox_linux::guest::GuestListener;
use std::{
    collections::BTreeMap,
    fs::File,
    sync::{Arc, Mutex, mpsc},
    time::{Duration, Instant},
};

fn main() {
    if run().is_err() {
        // Stable diagnostics exclude prompts, credentials, and rejected payloads.
        eprintln!("jeryu_guestd_failed");
    }
    // PID 1 never returns or remains alive with no supervising control plane.
    // Give a previously written fixed Error frame a short drain opportunity.
    std::thread::sleep(Duration::from_millis(50));
    shutdown::stop();
}

fn run() -> std::io::Result<()> {
    if std::process::id() != 1 {
        return Err(std::io::Error::other("guest_pid1_required"));
    }
    let shutdown = shutdown::Guard::start()?;
    let listener = GuestListener::bind(EXECUTION_PORT)?;
    let mut transport = listener.accept_host()?;
    let (lease, challenge, remaining) = match read_frame::<GuestRequest>(&mut transport)? {
        GuestRequest::Bind {
            lease,
            challenge,
            remaining_lease_millis,
        } => (*lease, challenge, remaining_lease_millis),
        _ => return Err(std::io::Error::other("guest_bind_required")),
    };
    shutdown.bind(remaining)?;
    workspace::configure_git(lease.resources.git_limits)?;
    if let Err(error) = filesystem::initialize(lease.checkpoint.is_some()) {
        // Bootstrap errors originate from fixed trusted setup operations. Emit
        // their stable phase, never a path, rejected request, or OS payload.
        write_frame(
            &mut transport,
            &GuestEvent::Error {
                code: error.to_string(),
            },
        )?;
        return Err(error);
    }
    if identity::verify(&lease.runtime.guestd.digest).is_err() {
        write_frame(
            &mut transport,
            &GuestEvent::Error {
                code: "guestd_identity_mismatch".into(),
            },
        )?;
        return Err(std::io::Error::other("guestd_identity_mismatch"));
    }
    if identity::verify_class(lease.runtime.image_class).is_err() {
        write_frame(
            &mut transport,
            &GuestEvent::Error {
                code: "guest_image_class_mismatch".into(),
            },
        )?;
        return Err(std::io::Error::other("guest_image_class_mismatch"));
    }
    if let Err(error) = jeryu_sandbox_linux::guest_network::initialize_loopback() {
        write_frame(
            &mut transport,
            &GuestEvent::Error {
                code: error.to_string(),
            },
        )?;
        return Err(error);
    }
    let workspace = match workspace::prepare(&lease) {
        Ok(ready) => ready,
        Err(error) => {
            let code = match error.to_string().as_str() {
                "guest_main_sync_conflict" => "guest_main_sync_conflict",
                "guest_source_revision_mismatch" => "guest_source_revision_mismatch",
                "guest_source_digest_mismatch" => "guest_source_digest_mismatch",
                "guest_git_unavailable" => "guest_git_unavailable",
                _ => "guest_workspace_prepare_failed",
            };
            let code = workspace::git_diagnostic(&error).unwrap_or_else(|| code.into());
            write_frame(&mut transport, &GuestEvent::Error { code })?;
            return Err(error);
        }
    };
    let session_workspace = workspace.clone();
    write_frame(
        &mut transport,
        &GuestEvent::Ready {
            protocol_version: GUEST_PROTOCOL_VERSION.into(),
            challenge,
            session_id: lease.context.session_id.clone(),
            generation: lease.context.generation,
            run_id: lease.context.run_id.clone(),
            workspace,
        },
    )?;
    session(transport, lease, session_workspace)
}

fn session(
    mut transport: File,
    lease: SessionLease,
    workspace: Option<jeryu_runner_protocol::wire::v2::WorkspaceReady>,
) -> std::io::Result<()> {
    let repo_ready = workspace.is_some();
    let rebase_required = workspace
        .as_ref()
        .is_some_and(|ready| ready.sync_state == WorkspaceSyncState::RebaseRequired);
    let (requests_tx, requests) = mpsc::sync_channel(16);
    let writer = Arc::new(Mutex::new(transport.try_clone()?));
    std::thread::spawn(move || {
        while let Ok(request) = read_frame::<GuestRequest>(&mut transport) {
            if requests_tx.send(request).is_err() {
                break;
            }
        }
    });
    let started = Instant::now();
    let reaper = reaper::Reaper::start();
    let activity = Arc::new(Mutex::new(Instant::now()));
    let mut processes = BTreeMap::<String, process::GuestProcess>::new();
    let mut frozen = false;
    let authority = Arc::new(Mutex::new(authority::Authority::default()));
    loop {
        let runtime_limit =
            started.elapsed() >= Duration::from_secs(lease.resources.runtime_seconds.into());
        if !frozen
            && (runtime_limit
                || (!processes.values().any(process::GuestProcess::active_agent)
                    && activity
                        .lock()
                        .map_err(|_| std::io::Error::other("guest_activity_failed"))?
                        .elapsed()
                        >= Duration::from_secs(lease.resources.idle_seconds.into())))
        {
            processes.clear();
            let workspace = freeze::workspace(&reaper, &workspace, lease.context.generation)?;
            emit(
                &writer,
                &GuestEvent::LifecycleStopped {
                    reason: if runtime_limit {
                        jeryu_runner_protocol::guest::LifecycleReason::RuntimeLimit
                    } else {
                        jeryu_runner_protocol::guest::LifecycleReason::IdleTimeout
                    },
                    workspace,
                },
            )?;
            frozen = true;
        }
        let request = match requests.recv_timeout(Duration::from_millis(100)) {
            Ok(request) => request,
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        };
        if frozen {
            return Err(std::io::Error::other("guest_workspace_frozen"));
        }
        match request {
            GuestRequest::ControlFence {
                request_id,
                epoch,
                ttl_millis,
                terminal_channels,
            } => {
                authority
                    .lock()
                    .map_err(|_| std::io::Error::other("guest_authority_failed"))?
                    .fence(epoch, ttl_millis, terminal_channels)?;
                emit(&writer, &GuestEvent::ControlFenced { request_id, epoch })?;
            }
            GuestRequest::Bind { .. } => return Err(std::io::Error::other("guest_rebind_denied")),
            GuestRequest::Start { channel, profile } => {
                if !lease.runtime.permits_profile(profile.id()) {
                    return Err(std::io::Error::other("guest_profile_not_declared"));
                }
                if rebase_required && profile != jeryu_runner_protocol::guest::GuestProfile::Shell {
                    return Err(std::io::Error::other("guest_rebase_required"));
                }
                processes.retain(|_, process| !process.finished());
                if processes.contains_key(&channel) || processes.len() >= 2 {
                    emit(
                        &writer,
                        &GuestEvent::Error {
                            code: "guest_channel_limit".into(),
                        },
                    )?;
                } else {
                    match process::GuestProcess::start(
                        &channel,
                        profile,
                        &lease.resources,
                        process::ProcessContext {
                            writer: writer.clone(),
                            reaper: reaper.clone(),
                            activity: activity.clone(),
                            authority: authority.clone(),
                        },
                        if repo_ready {
                            std::path::Path::new("/workspace/repo")
                        } else {
                            std::path::Path::new("/workspace")
                        },
                    ) {
                        Ok(process) => {
                            processes.insert(channel, process);
                        }
                        Err(_) => {
                            emit(
                                &writer,
                                &GuestEvent::Error {
                                    code: "guest_process_start_failed".into(),
                                },
                            )?;
                        }
                    }
                }
            }
            GuestRequest::Input {
                channel,
                request_id,
                control_epoch,
                bytes,
            } => {
                let applied = processes
                    .get_mut(&channel)
                    .is_some_and(|p| p.input(request_id.clone(), control_epoch, bytes).is_ok());
                if applied {
                    *activity
                        .lock()
                        .map_err(|_| std::io::Error::other("guest_activity_failed"))? =
                        Instant::now();
                } else {
                    acknowledge(&writer, request_id, false)?;
                }
            }
            GuestRequest::Resize {
                channel,
                request_id,
                control_epoch,
                rows,
                cols,
            } => {
                let permission = authority
                    .lock()
                    .map_err(|_| std::io::Error::other("guest_authority_failed"))?;
                let applied = permission.permits(control_epoch)
                    && processes
                        .get_mut(&channel)
                        .is_some_and(|p| p.resize(rows, cols).is_ok());
                drop(permission);
                acknowledge(&writer, request_id, applied)?;
            }
            GuestRequest::Interrupt {
                channel,
                request_id,
                control_epoch,
            } => {
                let permission = authority
                    .lock()
                    .map_err(|_| std::io::Error::other("guest_authority_failed"))?;
                let applied = permission.permits(control_epoch)
                    && processes
                        .get_mut(&channel)
                        .is_some_and(|p| p.interrupt().is_ok());
                drop(permission);
                acknowledge(&writer, request_id, applied)?;
            }
            GuestRequest::Stop { request_id } => {
                processes.clear();
                acknowledge(&writer, request_id, true)?;
                emit(&writer, &GuestEvent::Stopped)?;
                break;
            }
            GuestRequest::Freeze { request_id } => {
                processes.clear();
                let workspace = freeze::workspace(&reaper, &workspace, lease.context.generation)?;
                emit(
                    &writer,
                    &GuestEvent::Frozen {
                        request_id,
                        workspace,
                    },
                )?;
                frozen = true;
            }
        }
    }
    drop(processes);
    Ok(())
}

fn acknowledge(
    writer: &Arc<Mutex<File>>,
    request_id: String,
    applied: bool,
) -> std::io::Result<()> {
    emit(
        writer,
        &GuestEvent::Ack {
            request_id,
            applied,
            reason: if applied {
                "applied"
            } else {
                "channel_unavailable"
            }
            .into(),
        },
    )
}

pub(crate) fn emit(writer: &Arc<Mutex<File>>, event: &GuestEvent) -> std::io::Result<()> {
    write_frame(
        &mut *writer
            .lock()
            .map_err(|_| std::io::Error::other("guest_transport_unavailable"))?,
        event,
    )
}
