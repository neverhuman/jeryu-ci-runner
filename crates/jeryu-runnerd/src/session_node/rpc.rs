//! The mTLS control-plane peer asserts an authenticated user, not an arbitrary
//! public client. Existing session grants are rechecked for every operation.
use crate::{dispatch::DispatchEngine, sessions::SessionService};
use jeryu_runner_core::{RunnerError, RunnerResult};
use jeryu_runner_protocol::wire::v2::{
    GrantApplied, PROTOCOL_VERSION, SessionRpcResponse, SessionRpcResult,
};
pub use jeryu_runner_protocol::wire::v2::{
    SessionRpcOperation as RpcOperation, SessionRpcRequest as RpcRequest,
};

pub(super) fn apply(
    request: RpcRequest,
    service: &SessionService,
) -> RunnerResult<SessionRpcResponse> {
    request
        .validate()
        .map_err(|_| failed("session_rpc_invalid"))?;
    let expected_context = match &request.operation {
        RpcOperation::Start { lease } => lease.context.clone(),
        RpcOperation::Control { actor, request } => {
            service
                .get(
                    actor,
                    &request.context.session_id,
                    request.context.generation,
                )?
                .snapshot(actor)?
                .context
        }
        RpcOperation::Snapshot {
            actor,
            session_id,
            generation,
        }
        | RpcOperation::Screen {
            actor,
            session_id,
            generation,
            ..
        }
        | RpcOperation::AcquireControl {
            actor,
            session_id,
            generation,
            ..
        }
        | RpcOperation::Acknowledgement {
            actor,
            session_id,
            generation,
            ..
        }
        | RpcOperation::Replay {
            actor,
            session_id,
            generation,
            ..
        }
        | RpcOperation::Grant {
            actor,
            session_id,
            generation,
            ..
        } => {
            service
                .get(actor, session_id, *generation)?
                .snapshot(actor)?
                .context
        }
    };
    let value = match request.operation.clone() {
        RpcOperation::Start { lease } => {
            let owner = lease.context.owner_id.clone();
            SessionRpcResult::Snapshot(
                DispatchEngine::new()
                    .dispatch_managed_session(service, *lease)?
                    .snapshot(&owner)?,
            )
        }
        RpcOperation::Snapshot {
            actor,
            session_id,
            generation,
        } => SessionRpcResult::Snapshot(
            service
                .get(&actor, &session_id, generation)?
                .snapshot(&actor)?,
        ),
        RpcOperation::AcquireControl {
            actor,
            session_id,
            generation,
            takeover,
            controller_id,
            terminal_channels,
        } => SessionRpcResult::Controller(
            service
                .get(&actor, &session_id, generation)?
                .acquire_control(&actor, &controller_id, &terminal_channels, takeover)?,
        ),
        RpcOperation::Screen {
            actor,
            session_id,
            generation,
            channel_id,
        } => SessionRpcResult::Screen(
            service
                .get(&actor, &session_id, generation)?
                .screen(&actor, &channel_id)?,
        ),
        RpcOperation::Control { actor, request } => {
            let handle = service.get(
                &actor,
                &request.context.session_id,
                request.context.generation,
            )?;
            SessionRpcResult::Control(handle.control(&actor, *request)?)
        }
        RpcOperation::Acknowledgement {
            actor,
            session_id,
            generation,
            control_request_id,
        } => SessionRpcResult::Control(
            service
                .get(&actor, &session_id, generation)?
                .acknowledgement(&actor, &control_request_id)?,
        ),
        RpcOperation::Replay {
            actor,
            session_id,
            generation,
            channel_id,
            cursor,
            limit,
        } => {
            // Worst-case decimal byte encoding is still bounded below 1 MiB.
            if !(1..=4).contains(&limit) {
                return Err(failed("session_rpc_replay_limit_invalid"));
            }
            SessionRpcResult::Replay(service.get(&actor, &session_id, generation)?.replay(
                &actor,
                &channel_id,
                cursor,
                limit,
            )?)
        }
        RpcOperation::Grant {
            actor,
            session_id,
            generation,
            subject,
            grant,
        } => {
            service
                .get(&actor, &session_id, generation)?
                .grant(&actor, &subject, grant)?;
            SessionRpcResult::Grant(GrantApplied { applied: true })
        }
    };
    let response = SessionRpcResponse {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-rpc-response".into(),
        request_id: Some(request.request_id.clone()),
        ok: true,
        result: Some(value),
        error: None,
    };
    response
        .validate_for(&request, &expected_context)
        .map_err(|_| failed("session_rpc_encode_failed"))?;
    Ok(response)
}
fn failed(code: &'static str) -> RunnerError {
    RunnerError::new(code, "session RPC rejected")
}
