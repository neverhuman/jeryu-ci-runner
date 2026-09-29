//! End-to-end proof of the model-egress contract an agent session runs under:
//! traffic to the configured model API host is reached THROUGH the proxy, and
//! every other host is refused before a single upstream packet is sent.
//!
//! A stand-in "model API" listens on an ephemeral loopback port and the proxy's
//! allow-list is configured to exactly that host, so the test needs no real DNS
//! and no outbound network — the same code path an agent container takes when
//! its `HTTPS_PROXY` points at the host proxy.

use jeryu_egress::{Budget, ModelEgressConfig, Proxy};
use std::net::SocketAddr;
use std::path::Path;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// Body the stand-in model API answers with, so a passing test proves the bytes
/// came from upstream and not from the proxy itself.
const MODEL_BODY: &str = "{\"model\":\"ok\"}";

/// Bind a stand-in model API on loopback that answers one request per
/// connection, and return its address.
async fn spawn_model_api() -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                return;
            };
            tokio::spawn(async move {
                let mut buf = [0u8; 1024];
                let _ = socket.read(&mut buf).await;
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{MODEL_BODY}",
                    MODEL_BODY.len()
                );
                let _ = socket.write_all(response.as_bytes()).await;
                let _ = socket.flush().await;
            });
        }
    });
    addr
}

/// Serve `proxy` on an ephemeral loopback port, returning its bound address.
async fn spawn_proxy(proxy: Proxy) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = proxy.serve_listener(listener).await;
    });
    addr
}

/// Send one request prelude to the proxy and read the whole response.
async fn through_proxy(proxy_addr: SocketAddr, request: &[u8]) -> String {
    let mut client = TcpStream::connect(proxy_addr).await.unwrap();
    client.write_all(request).await.unwrap();
    client.flush().await.unwrap();
    let mut buf = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), client.read_to_end(&mut buf))
        .await
        .expect("proxy should respond promptly")
        .unwrap();
    String::from_utf8_lossy(&buf).into_owned()
}

/// A config whose allow-list holds exactly the stand-in model API host.
fn config_allowing(host: &str) -> ModelEgressConfig {
    ModelEgressConfig::from_toml_str(
        Path::new("model-egress.toml"),
        &format!("[model_egress]\nallow_hosts = [\"{host}\"]\n"),
    )
    .unwrap_or_else(|err| panic!("{err}"))
}

#[tokio::test]
async fn the_configured_model_host_is_reached_through_the_proxy() {
    let model = spawn_model_api().await;
    let proxy = Proxy::new(config_allowing("127.0.0.1").allowlist(), Budget::new());
    let proxy_addr = spawn_proxy(proxy).await;

    let response = through_proxy(
        proxy_addr,
        format!(
            "GET http://127.0.0.1:{port}/v1/messages HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n",
            port = model.port()
        )
        .as_bytes(),
    )
    .await;

    assert!(
        response.starts_with("HTTP/1.1 200"),
        "allowed model host must be reached, got: {response:?}"
    );
    assert!(
        response.contains(MODEL_BODY),
        "the model API's own body must come back through the proxy: {response:?}"
    );
}

#[tokio::test]
async fn a_connect_tunnel_to_the_model_host_carries_upstream_bytes() {
    // The real agent speaks HTTPS, so its request is a CONNECT tunnel. Prove the
    // tunnel opens and bytes flow both ways for the allowed host.
    let model = spawn_model_api().await;
    let proxy = Proxy::new(config_allowing("127.0.0.1").allowlist(), Budget::new());
    let proxy_addr = spawn_proxy(proxy).await;

    let mut client = TcpStream::connect(proxy_addr).await.unwrap();
    client
        .write_all(format!("CONNECT 127.0.0.1:{} HTTP/1.1\r\n\r\n", model.port()).as_bytes())
        .await
        .unwrap();
    client.flush().await.unwrap();

    let mut ack = [0u8; 39];
    tokio::time::timeout(Duration::from_secs(5), client.read_exact(&mut ack))
        .await
        .expect("tunnel ack should arrive promptly")
        .unwrap();
    let ack = String::from_utf8_lossy(&ack).into_owned();
    assert!(
        ack.starts_with("HTTP/1.1 200"),
        "tunnel must be established, got: {ack:?}"
    );

    client
        .write_all(b"GET /v1/messages HTTP/1.1\r\nHost: model\r\nConnection: close\r\n\r\n")
        .await
        .unwrap();
    client.flush().await.unwrap();
    let mut buf = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), client.read_to_end(&mut buf))
        .await
        .expect("tunnelled response should arrive promptly")
        .unwrap();
    let tunnelled = String::from_utf8_lossy(&buf);
    assert!(
        tunnelled.contains(MODEL_BODY),
        "tunnelled bytes must come from the model API: {tunnelled:?}"
    );
}

#[tokio::test]
async fn a_host_outside_the_allow_list_is_refused() {
    // Same proxy, same session: a second listener stands in for "everything
    // else" the agent might try. It is NOT on the allow-list, so the proxy must
    // answer 403 and never open a connection to it.
    let elsewhere = spawn_model_api().await;
    let proxy = Proxy::new(
        config_allowing("api.anthropic.com").allowlist(),
        Budget::new(),
    );
    let proxy_addr = spawn_proxy(proxy).await;

    let response = through_proxy(
        proxy_addr,
        format!(
            "GET http://127.0.0.1:{port}/v1/messages HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n",
            port = elsewhere.port()
        )
        .as_bytes(),
    )
    .await;
    assert!(
        response.starts_with("HTTP/1.1 403"),
        "a host outside the allow-list must be refused, got: {response:?}"
    );
    assert!(
        !response.contains(MODEL_BODY),
        "a refused host must not be contacted: {response:?}"
    );

    // And the CONNECT form of the same attempt is refused too.
    let tunnel = through_proxy(
        proxy_addr,
        format!("CONNECT 127.0.0.1:{} HTTP/1.1\r\n\r\n", elsewhere.port()).as_bytes(),
    )
    .await;
    assert!(
        tunnel.starts_with("HTTP/1.1 403"),
        "a refused host must not get a tunnel either, got: {tunnel:?}"
    );
}

#[tokio::test]
async fn the_default_config_allows_the_anthropic_host_and_nothing_else() {
    // The shipped default: the Anthropic API host only. A different host is
    // refused with no config change at all.
    let proxy = Proxy::new(ModelEgressConfig::default().allowlist(), Budget::new());
    let proxy_addr = spawn_proxy(proxy).await;
    for host in ["api.openai.com", "github.com", "evil.example.com"] {
        let response = through_proxy(
            proxy_addr,
            format!("CONNECT {host}:443 HTTP/1.1\r\n\r\n").as_bytes(),
        )
        .await;
        assert!(
            response.starts_with("HTTP/1.1 403"),
            "{host} must be refused by the default allow-list, got: {response:?}"
        );
    }
    assert!(
        ModelEgressConfig::default()
            .allowlist()
            .permits("api.anthropic.com")
    );
}
