# Model egress for agent containers

Agent containers are network-denied: `OciSpec::from_agent_job` refuses any
requested or effective network policy other than `deny`, and the emitted argv
carries no route off the container. That leaves one question — how does the
agent reach a model API? Through a per-host forward proxy that allows only the
model API hosts named in one config file.

## The shape

- `jeryu-egress` runs on the host and binds on a dedicated, internal container
  bridge. It forwards `CONNECT` tunnels and plain HTTP **only** to hosts on its
  allow-list; everything else gets `403` and no upstream socket is ever opened.
- The agent container joins that bridge and nothing else, and the runner sets
  `HTTPS_PROXY` / `HTTP_PROXY` inside it to the proxy endpoint. The bridge is
  internal, so the proxy is the only thing on it the container can reach.
- Warm pool cells carry the same route at start (`WarmContainerSpec::with_route`),
  because a session execs into an already-running cell and an exec inherits the
  cell's network and environment.
- With no route configured, all of this collapses back to `--network none`:
  `OciSpec::network` stays `none`, no proxy environment is emitted, and the
  warm cell idles with no network at all.

## Configuring the allow-list

Copy `configs/model-egress.toml`, edit it, and point every host process that
launches agent cells at it:

    export JERYU_MODEL_EGRESS_CONFIG=/etc/jeryu/model-egress.toml

```toml
[model_egress]
bind = "10.88.0.1:8889"
network = "jeryu-model-egress"
proxy_endpoint = "http://10.88.0.1:8889"
allow_hosts = ["api.anthropic.com"]
allow_suffixes = []
```

- `allow_hosts` **replaces** the default list, it does not extend it. The
  default, used when no config file is set, is `api.anthropic.com` alone.
- `allow_suffixes` entries match on a dot boundary: `models.example.test`
  allows `models.example.test` and `eu.models.example.test`, never
  `notmodels.example.test` or `models.example.test.attacker.com`.
- `network` and `proxy_endpoint` must BOTH be set for a container to be routed.
  Setting only one yields no route at all, so a bridge is never attached
  without a proxy on it to use.
- An unknown key, unparseable TOML, or a configured file that cannot be read is
  a hard failure (`invalid_model_egress_config`): a host that cannot read its
  own egress policy refuses to launch rather than guess at one.

## Bringing it up on a host

```sh
# One internal bridge with no route to the outside world.
podman network create --internal jeryu-model-egress

# The proxy, bound on the host's address on that bridge.
JERYU_MODEL_EGRESS_CONFIG=/etc/jeryu/model-egress.toml jeryu-egress
```

`JERYU_EGRESS_BIND` overrides `bind` if an operator needs to move the listener
without editing the policy file.

## What is covered by tests

- `crates/jeryu-egress/tests/model_egress.rs` runs the real proxy against a
  stand-in model API: the configured host is reached through the proxy (both
  plain HTTP and a `CONNECT` tunnel, with the upstream body coming back), and a
  host outside the allow-list is refused with `403` and never contacted.
- `crates/jeryu-egress/src/config.rs` unit-tests the allow-list resolution,
  including the deny-by-default and half-configured-route cases.
- `crates/jeryu-runner-oci/src/tests.rs` pins the container side: with a route,
  exactly one `--network` naming the egress bridge plus the proxy environment,
  with the hardening and single workspace mount unchanged; without a route,
  `--network none` and no proxy environment; and the requested/effective
  network-deny matrix is still enforced with a route configured.
