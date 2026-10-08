//! Bounded Firecracker API over the VM-owned Unix socket.
use jeryu_runner_core::{RunnerError, RunnerResult};
use serde_json::Value;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

pub(crate) fn put(socket: &Path, path: &str, body: Value) -> RunnerResult<()> {
    let body = serde_json::to_vec(&body).map_err(|_| failed())?;
    let mut stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    write!(
        stream,
        "PUT {path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )?;
    stream.write_all(&body)?;
    // Firecracker may retain the HTTP connection. Consume a complete bounded
    // message instead of waiting for EOF after a successful response.
    let mut response = Vec::new();
    while !response.ends_with(b"\r\n\r\n") {
        if response.len() >= 16 * 1024 {
            return Err(failed());
        }
        let mut byte = [0];
        stream.read_exact(&mut byte)?;
        response.push(byte[0]);
    }
    let line = response
        .split(|byte| *byte == b'\n')
        .next()
        .unwrap_or_default();
    if !line.starts_with(b"HTTP/1.1 204 ") {
        let status = std::str::from_utf8(line)
            .ok()
            .and_then(|line| line.split_whitespace().nth(1))
            .filter(|status| status.len() == 3 && status.bytes().all(|v| v.is_ascii_digit()))
            .unwrap_or("invalid");
        return Err(RunnerError::new(
            "microvm_api_failed",
            format!("VM API rejected {path} with HTTP status {status}"),
        ));
    }
    let headers = std::str::from_utf8(&response).map_err(|_| failed())?;
    let mut content_length = None;
    for header in headers.split("\r\n").skip(1).filter(|v| !v.is_empty()) {
        let (name, value) = header.split_once(':').ok_or_else(failed)?;
        if name.eq_ignore_ascii_case("transfer-encoding") {
            return Err(failed());
        }
        if name.eq_ignore_ascii_case("content-length") {
            if content_length.is_some() {
                return Err(failed());
            }
            content_length = Some(value.trim().parse::<usize>().map_err(|_| failed())?);
        }
    }
    // A 204 cannot have a payload. Missing length is valid for this status.
    if content_length.is_some_and(|length| length != 0) {
        return Err(failed());
    }
    Ok(())
}

pub(crate) fn guest_channel(socket: &Path, timeout: Duration) -> RunnerResult<UnixStream> {
    let mut stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(timeout))?;
    writeln!(
        stream,
        "CONNECT {}",
        jeryu_runner_protocol::guest::EXECUTION_PORT
    )?;
    let mut response = Vec::new();
    for _ in 0..32 {
        let mut byte = [0];
        stream.read_exact(&mut byte)?;
        response.push(byte[0]);
        if byte[0] == b'\n' {
            break;
        }
    }
    let response = std::str::from_utf8(&response).map_err(|_| failed())?;
    let port = response
        .strip_prefix("OK ")
        .and_then(|v| v.strip_suffix('\n'))
        .and_then(|v| v.parse::<u32>().ok());
    if port.is_none_or(|v| v == 0) {
        return Err(failed());
    }
    Ok(stream)
}

fn failed() -> RunnerError {
    RunnerError::new(
        "microvm_api_failed",
        "VM API or guest channel rejected configuration",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;
    use std::sync::mpsc;

    fn response(result: &[u8]) -> RunnerResult<()> {
        let temporary = tempfile::tempdir()?;
        let socket = temporary.path().join("api.sock");
        let listener = UnixListener::bind(&socket)?;
        let response = result.to_vec();
        let (release, wait) = mpsc::channel();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = vec![];
            while !request.ends_with(b"\r\n\r\n") {
                let mut byte = [0];
                stream.read_exact(&mut byte).unwrap();
                request.push(byte[0]);
            }
            // Test request is the two-byte empty JSON object.
            stream.read_exact(&mut [0; 2]).unwrap();
            stream.write_all(&response).unwrap();
            let _ = wait.recv_timeout(Duration::from_secs(3));
        });
        let result = put(&socket, "/actions", serde_json::json!({}));
        let _ = release.send(());
        server.join().unwrap();
        result
    }

    #[test]
    fn successful_api_response_does_not_require_connection_close() {
        let started = std::time::Instant::now();
        response(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n").unwrap();
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn ambiguous_or_unsuccessful_api_responses_fail() {
        for bytes in [
            b"HTTP/1.1 204 No Content\r\nContent-Length: 1\r\n\r\n".as_slice(),
            b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n",
            b"HTTP/1.1 204 No Content\r\nTransfer-Encoding: chunked\r\n\r\n",
            b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n",
        ] {
            assert!(response(bytes).is_err());
        }
    }
}
