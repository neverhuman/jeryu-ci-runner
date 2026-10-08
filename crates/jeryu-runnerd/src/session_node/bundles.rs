//! Streaming K4 ingestion after exact pinned mTLS peer authentication. No body
//! collection, filename or privileged role is exposed to the caller.
use super::serve::{HttpBody, error_for, json_reply};
use http_body_util::BodyExt;
use hyper::{
    Request, Response, StatusCode,
    body::{Bytes, Incoming},
};
use jeryu_runner_microvm::source_registry::SourceBundleRegistry;
use jeryu_runner_protocol::wire::v2::BundleUpload;
use std::{sync::Arc, time::Duration};
use tokio::time::timeout;
mod metadata;

pub(super) async fn response(
    request: Request<Incoming>,
    registry: Arc<SourceBundleRegistry>,
) -> Response<HttpBody> {
    let total = match metadata::content_length(request.headers()) {
        Ok(total) => total,
        Err(code) => return error_for(StatusCode::BAD_REQUEST, code, None),
    };
    let mut input = Input {
        body: request.into_body(),
        pending: Bytes::new(),
        read: 0,
    };
    let prefix = match input.exact(4).await {
        Ok(prefix) => prefix,
        Err(code) => return error_for(StatusCode::BAD_REQUEST, code, None),
    };
    let metadata_length = u32::from_be_bytes([prefix[0], prefix[1], prefix[2], prefix[3]]) as usize;
    if !(1..=16384).contains(&metadata_length) {
        return error_for(StatusCode::BAD_REQUEST, "bundle_metadata_limit", None);
    }
    let bytes = match input.exact(metadata_length).await {
        Ok(bytes) => bytes,
        Err(code) => return error_for(StatusCode::BAD_REQUEST, code, None),
    };
    let upload = match metadata::decode(&bytes, total) {
        Ok(upload) => upload,
        Err((code, id)) => return error_for(StatusCode::UNPROCESSABLE_ENTITY, code, id),
    };
    let id = Some(upload.request_id.clone());
    let begin = tokio::task::spawn_blocking(move || registry.begin(upload)).await;
    let mut stage = match begin {
        Ok(Ok(stage)) => stage,
        Ok(Err(error)) => return error_for(StatusCode::CONFLICT, error.code(), id),
        Err(_) => {
            return error_for(
                StatusCode::INTERNAL_SERVER_ERROR,
                "bundle_upload_failed",
                id,
            );
        }
    };
    loop {
        let bytes = match input.next().await {
            Ok(Some(bytes)) => bytes,
            Ok(None) => break,
            Err(code) => return error_for(StatusCode::BAD_REQUEST, code, id),
        };
        // Disk I/O is off the async runtime. Cancellation eventually drops the
        // exclusively owned stage; there is no unbounded upload task queue.
        let written =
            tokio::task::spawn_blocking(move || stage.write_chunk(&bytes).map(|()| stage)).await;
        stage = match written {
            Ok(Ok(stage)) => stage,
            Ok(Err(error)) => return error_for(StatusCode::UNPROCESSABLE_ENTITY, error.code(), id),
            Err(_) => {
                return error_for(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "bundle_upload_failed",
                    id,
                );
            }
        };
    }
    if input.read != total {
        return error_for(StatusCode::BAD_REQUEST, "bundle_length_invalid", id);
    }
    match tokio::task::spawn_blocking(move || stage.finish()).await {
        Ok(Ok(receipt)) => match receipt.to_json() {
            Ok(bytes) => json_reply(StatusCode::OK, bytes),
            Err(_) => error_for(
                StatusCode::INTERNAL_SERVER_ERROR,
                "bundle_receipt_invalid",
                id,
            ),
        },
        Ok(Err(error)) => error_for(StatusCode::UNPROCESSABLE_ENTITY, error.code(), id),
        Err(_) => error_for(
            StatusCode::INTERNAL_SERVER_ERROR,
            "bundle_upload_failed",
            id,
        ),
    }
}

struct Input {
    body: Incoming,
    pending: Bytes,
    read: u64,
}
impl Input {
    async fn next(&mut self) -> Result<Option<Bytes>, &'static str> {
        if !self.pending.is_empty() {
            return Ok(Some(std::mem::take(&mut self.pending)));
        }
        loop {
            match timeout(Duration::from_secs(5), self.body.frame()).await {
                Ok(Some(Ok(frame))) => {
                    let bytes = frame.into_data().map_err(|_| "bundle_http_frame_invalid")?;
                    if bytes.len() > 65536 {
                        return Err("bundle_http_frame_limit");
                    }
                    self.read += bytes.len() as u64;
                    if !bytes.is_empty() {
                        return Ok(Some(bytes));
                    }
                }
                Ok(None) => return Ok(None),
                _ => return Err("bundle_body_unavailable"),
            }
        }
    }
    async fn exact(&mut self, size: usize) -> Result<Vec<u8>, &'static str> {
        let mut bytes = Vec::with_capacity(size);
        while bytes.len() < size {
            let mut chunk = self.next().await?.ok_or("bundle_length_invalid")?;
            let amount = (size - bytes.len()).min(chunk.len());
            bytes.extend_from_slice(&chunk.split_to(amount));
            self.pending = chunk;
        }
        Ok(bytes)
    }
}
