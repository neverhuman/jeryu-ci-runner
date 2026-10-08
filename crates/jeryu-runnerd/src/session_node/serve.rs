use super::{RpcRequest, SessionNodeConfig};
use crate::sessions::SessionService;
use http_body_util::{BodyExt, Full, Limited};
use hyper::{
    Method, Request, Response, StatusCode,
    body::{Bytes, Incoming},
    server::conn::http1,
    service::service_fn,
};
use hyper_util::rt::TokioIo;
use jeryu_runner_core::RunnerResult;
use jeryu_runner_protocol::wire::v2::{PROTOCOL_VERSION, SessionRpcError, SessionRpcResponse};
use sha2::{Digest, Sha256};
use std::{convert::Infallible, sync::Arc, time::Duration};
use tokio::{net::TcpListener, sync::Semaphore, time::timeout};
use tokio_rustls::TlsAcceptor;
pub(super) type HttpBody = http_body_util::combinators::UnsyncBoxBody<Bytes, Infallible>;

pub async fn serve(config: SessionNodeConfig) -> RunnerResult<()> {
    // Root service has no unbounded client queues. TLS authenticates before HTTP
    // or JSON parsing, and only a pinned control-plane peer may assert actors.
    let acceptor = TlsAcceptor::from(config.tls()?);
    let runtime = Arc::new(config.runtime()?);
    let node = config.node()?.open()?;
    let service =
        Arc::new(SessionService::new(node, runtime).with_owner_limit(config.owner_limit)?);
    let listener = TcpListener::bind(config.listen).await?;
    let slots = Arc::new(Semaphore::new(32));
    let streams = Arc::new(Semaphore::new(16));
    loop {
        let (socket, _) = listener.accept().await?;
        let Ok(slot) = slots.clone().try_acquire_owned() else {
            continue;
        };
        let acceptor = acceptor.clone();
        let service = service.clone();
        let streams = streams.clone();
        let approved_peer = config.control_plane_certificate_sha256.clone();
        tokio::spawn(async move {
            let _slot = slot;
            let Ok(Ok(tls)) = timeout(Duration::from_secs(5), acceptor.accept(socket)).await else {
                return;
            };
            let Some(peer) = tls
                .get_ref()
                .1
                .peer_certificates()
                .and_then(|certificates| certificates.first())
            else {
                return;
            };
            let digest: String = Sha256::digest(peer.as_ref())
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect();
            if digest != approved_peer {
                return;
            }
            let http = service_fn(move |request| handle(request, service.clone(), streams.clone()));
            // One request per connection. The outer bound also covers a slow
            // request/response peer; guest execution has independent supervision.
            let _ = timeout(
                Duration::from_secs(75),
                http1::Builder::new()
                    .keep_alive(false)
                    .max_buf_size(16 * 1024)
                    .serve_connection(TokioIo::new(tls), http),
            )
            .await;
        });
    }
}
async fn handle(
    request: Request<Incoming>,
    service: Arc<SessionService>,
    streams: Arc<Semaphore>,
) -> Result<Response<HttpBody>, Infallible> {
    let subscribe = request.uri().path() == "/jeryu.runner.v2/subscribe";
    if request.method() != Method::POST
        || (!subscribe && request.uri().path() != "/jeryu.runner.v2/session")
        || request.uri().query().is_some()
        || request.headers().contains_key("cookie")
        || request.headers().contains_key("authorization")
        || request.headers().contains_key("content-encoding")
    {
        return Ok(error(StatusCode::BAD_REQUEST, "session_rpc_route_invalid"));
    }
    if request
        .headers()
        .get("content-type")
        .and_then(|header| header.to_str().ok())
        != Some("application/json")
    {
        return Ok(error(
            StatusCode::BAD_REQUEST,
            "session_rpc_content_type_invalid",
        ));
    }
    let body = match timeout(
        Duration::from_secs(5),
        Limited::new(request.into_body(), 256 * 1024).collect(),
    )
    .await
    {
        Ok(Ok(body)) => body.to_bytes(),
        _ => {
            return Ok(error(
                StatusCode::PAYLOAD_TOO_LARGE,
                "session_rpc_body_invalid",
            ));
        }
    };
    if subscribe {
        return Ok(super::streaming::response(&body, &service, &streams));
    }
    let request = match RpcRequest::from_json(&body) {
        Ok(request) => request,
        Err(_) => {
            return Ok(error(
                StatusCode::UNPROCESSABLE_ENTITY,
                "session_rpc_invalid",
            ));
        }
    };
    let request_id = request.request_id.clone();
    let result = tokio::task::spawn_blocking(move || super::rpc::apply(request, &service)).await;
    let response = match result {
        Ok(Ok(value)) => reply(StatusCode::OK, value),
        Ok(Err(error_value)) => {
            error_for(StatusCode::CONFLICT, error_value.code(), Some(request_id))
        }
        Err(_) => error_for(
            StatusCode::INTERNAL_SERVER_ERROR,
            "session_rpc_failed",
            Some(request_id),
        ),
    };
    Ok(response)
}
pub(super) fn error(status: StatusCode, code: &str) -> Response<HttpBody> {
    error_for(status, code, None)
}
pub(super) fn error_for(
    status: StatusCode,
    code: &str,
    request_id: Option<String>,
) -> Response<HttpBody> {
    reply(
        status,
        SessionRpcResponse {
            protocol_version: PROTOCOL_VERSION.into(),
            message_type: "session-rpc-response".into(),
            request_id,
            ok: false,
            result: None,
            error: Some(SessionRpcError { code: code.into() }),
        },
    )
}
fn reply(status: StatusCode, value: SessionRpcResponse) -> Response<HttpBody> {
    let (status, bytes) = match value.to_json() {
        Ok(bytes) => (status, bytes),
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            b"{\"protocol_version\":\"jeryu.runner.v2.1\",\"message_type\":\"session-rpc-response\",\"request_id\":null,\"ok\":false,\"error\":{\"code\":\"session_rpc_encode_failed\"}}".to_vec(),
        ),
    };
    let mut response = Response::new(Full::new(Bytes::from(bytes)).boxed_unsync());
    *response.status_mut() = status;
    response.headers_mut().insert(
        "content-type",
        hyper::header::HeaderValue::from_static("application/json"),
    );
    response.headers_mut().insert(
        "cache-control",
        hyper::header::HeaderValue::from_static("no-store"),
    );
    response
}
