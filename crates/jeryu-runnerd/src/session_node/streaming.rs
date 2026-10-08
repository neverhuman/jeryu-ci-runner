//! K2: bounded replay and live frames, independent of execution backpressure.
use super::serve::{HttpBody, error, error_for};
use crate::sessions::{
    RuntimePhase, SessionEvent, SessionHandle, SessionService, SessionSnapshot, Subscription,
};
use http_body_util::{BodyExt, StreamBody};
use hyper::{
    Response, StatusCode,
    body::{Bytes, Frame},
};
use jeryu_runner_core::{RunnerError, RunnerResult};
use jeryu_runner_protocol::wire::v2::{
    PROTOCOL_VERSION, SessionStreamEvent, SessionStreamFrame, SessionSubscribe,
};
use std::{
    convert::Infallible,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::{Semaphore, mpsc};

pub(super) fn response(
    bytes: &[u8],
    service: &SessionService,
    slots: &Arc<Semaphore>,
) -> Response<HttpBody> {
    let request = match SessionSubscribe::from_json(bytes) {
        Ok(request) => request,
        Err(_) => {
            return error(
                StatusCode::UNPROCESSABLE_ENTITY,
                "session_subscribe_invalid",
            );
        }
    };
    let slot = match slots.clone().try_acquire_owned() {
        Ok(slot) => slot,
        Err(_) => {
            return error_for(
                StatusCode::SERVICE_UNAVAILABLE,
                "session_stream_capacity",
                Some(request.request_id),
            );
        }
    };
    let handle = match service.get(&request.actor, &request.session_id, request.generation) {
        Ok(handle) => handle,
        Err(e) => return error_for(StatusCode::CONFLICT, e.code(), Some(request.request_id)),
    };
    let (snapshot, subscription) =
        match handle.subscribe_from(&request.actor, &request.channel_id, request.after_sequence) {
            Ok(value) => value,
            Err(e) => return error_for(StatusCode::CONFLICT, e.code(), Some(request.request_id)),
        };
    let (send, receive) = mpsc::channel::<Bytes>(2);
    let producer = handle.clone();
    let delivery_actor = request.actor.clone();
    tokio::task::spawn_blocking(move || {
        let _slot = slot;
        let _ = produce(&request, &producer, snapshot, subscription, &send);
    });
    let stream = futures_util::stream::unfold(
        (receive, handle, delivery_actor),
        |(mut receive, handle, actor)| async move {
            let bytes = receive.recv().await?;
            // Recheck at HTTP-body delivery, including bytes queued before revocation.
            handle.snapshot(&actor).ok()?;
            Some((
                Ok::<_, Infallible>(Frame::data(bytes)),
                (receive, handle, actor),
            ))
        },
    );
    let mut response = Response::new(StreamBody::new(stream).boxed_unsync());
    response.headers_mut().insert(
        "content-type",
        hyper::header::HeaderValue::from_static("application/x-ndjson"),
    );
    response.headers_mut().insert(
        "cache-control",
        hyper::header::HeaderValue::from_static("no-store"),
    );
    response
}

fn produce(
    request: &SessionSubscribe,
    handle: &SessionHandle,
    snapshot: SessionSnapshot,
    subscription: Subscription,
    send: &mpsc::Sender<Bytes>,
) -> RunnerResult<()> {
    let boundary = channel(&snapshot, &request.channel_id)?.cursor;
    let mut cursor = request.after_sequence;
    emit(
        request,
        handle,
        send,
        SessionStreamEvent::Snapshot {
            snapshot: snapshot.clone(),
        },
    )?;
    while cursor < boundary {
        let frames = handle.replay(&request.actor, &request.channel_id, cursor, 4)?;
        if frames.is_empty() {
            return Err(failed("session_replay_discontinuity"));
        }
        for frame in frames {
            if frame.gap {
                emit(
                    request,
                    handle,
                    send,
                    SessionStreamEvent::Terminal { frame },
                )?;
                return Ok(());
            }
            if frame.sequence > boundary {
                break;
            }
            cursor = frame.sequence;
            emit(
                request,
                handle,
                send,
                SessionStreamEvent::Terminal { frame },
            )?;
        }
    }
    if ended(&snapshot, &request.channel_id)? {
        return emit(
            request,
            handle,
            send,
            SessionStreamEvent::End {
                reason: "channel_ended".into(),
            },
        );
    }
    let mut heartbeat = Instant::now();
    loop {
        if send.is_closed() {
            return Ok(());
        }
        handle.snapshot(&request.actor)?;
        match subscription.next(Duration::from_millis(100))? {
            Some(SessionEvent::Terminal(frame)) => {
                if !frame.gap && frame.sequence <= cursor {
                    continue;
                }
                let gap = frame.gap;
                cursor = frame.sequence;
                emit(
                    request,
                    handle,
                    send,
                    SessionStreamEvent::Terminal { frame },
                )?;
                if gap {
                    return Ok(());
                }
            }
            Some(SessionEvent::Control(acknowledgement))
                if acknowledgement.channel_id == request.channel_id =>
            {
                emit(
                    request,
                    handle,
                    send,
                    SessionStreamEvent::Control { acknowledgement },
                )?;
            }
            Some(SessionEvent::Snapshot(snapshot)) => {
                let finished = ended(&snapshot, &request.channel_id)?;
                emit(
                    request,
                    handle,
                    send,
                    SessionStreamEvent::Snapshot { snapshot },
                )?;
                if finished {
                    return emit(
                        request,
                        handle,
                        send,
                        SessionStreamEvent::End {
                            reason: "channel_ended".into(),
                        },
                    );
                }
            }
            Some(SessionEvent::Control(_)) | None => (),
        }
        if heartbeat.elapsed() >= Duration::from_secs(10) {
            emit(request, handle, send, SessionStreamEvent::Heartbeat)?;
            heartbeat = Instant::now();
        }
    }
}
fn channel<'a>(
    snapshot: &'a SessionSnapshot,
    id: &str,
) -> RunnerResult<&'a crate::sessions::ChannelSnapshot> {
    snapshot
        .channels
        .iter()
        .find(|c| c.channel_id == id)
        .ok_or_else(|| failed("session_channel_unknown"))
}
fn ended(snapshot: &SessionSnapshot, id: &str) -> RunnerResult<bool> {
    Ok(channel(snapshot, id)?.exited
        || matches!(snapshot.phase, RuntimePhase::Stopped | RuntimePhase::Failed))
}
fn emit(
    request: &SessionSubscribe,
    handle: &SessionHandle,
    send: &mpsc::Sender<Bytes>,
    payload: SessionStreamEvent,
) -> RunnerResult<()> {
    let frame = SessionStreamFrame {
        protocol_version: PROTOCOL_VERSION.into(),
        message_type: "session-stream".into(),
        request_id: request.request_id.clone(),
        session_id: request.session_id.clone(),
        generation: request.generation,
        channel_id: request.channel_id.clone(),
        payload,
    };
    let mut bytes = frame
        .to_json()
        .map_err(|_| failed("session_stream_encode_failed"))?;
    if bytes.len() >= 256 * 1024 {
        return Err(failed("session_stream_frame_limit"));
    }
    bytes.push(b'\n');
    let mut bytes = Bytes::from(bytes);
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        handle.snapshot(&request.actor)?;
        match send.try_send(bytes) {
            Ok(()) => return Ok(()),
            Err(mpsc::error::TrySendError::Closed(_)) => {
                return Err(failed("session_stream_closed"));
            }
            Err(mpsc::error::TrySendError::Full(value)) => bytes = value,
        }
        if Instant::now() >= deadline {
            return Err(failed("session_stream_backpressure"));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}
fn failed(code: &'static str) -> RunnerError {
    RunnerError::new(code, "session stream stopped")
}

#[cfg(test)]
mod tests;
