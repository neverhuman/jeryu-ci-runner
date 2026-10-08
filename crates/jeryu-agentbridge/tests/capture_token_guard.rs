//! A configured token value reaching a captured agent log fails the capture.
//!
//! The driver withholds a token-bearing line from its event sink while the run
//! streams (unit-tested on the real drain path in `driver/token_guard.rs`) and
//! applies `guard_capture` to the finished stdout/stderr as a backstop. That
//! backstop is exercised here directly rather than behind a kernel sandbox that
//! this host may not provide.

use jeryu_agentbridge::driver::{AgentDriver, DriverError};

const TOKEN: &str = "jrt-invented-value-9f3b";

fn driver() -> AgentDriver {
    AgentDriver::default().with_forbidden_token_values(vec![TOKEN.to_string()])
}

#[test]
fn a_token_value_on_stdout_or_stderr_fails_the_capture() {
    for (stdout, stderr) in [
        (
            format!("writing file, token={TOKEN}\n").into_bytes(),
            Vec::new(),
        ),
        (
            Vec::new(),
            format!("auth failed for {TOKEN}\n").into_bytes(),
        ),
        // Not valid UTF-8, and the token still has to be found.
        (vec![0xff, b' '], format!("{TOKEN} tail").into_bytes()),
    ] {
        let err = driver()
            .guard_capture(&stdout, &stderr)
            .expect_err("a token value in the captured log must fail the capture");
        let DriverError::CapturedTokenValue(detail) = err else {
            panic!("expected a captured-token denial, got {err}");
        };
        assert!(
            !detail.contains(TOKEN),
            "the denial must not echo the token value: {detail}"
        );
    }
}

#[test]
fn an_ordinary_capture_is_kept() {
    driver()
        .guard_capture(b"wrote src/lib.rs\n", b"warning: unused import\n")
        .unwrap_or_else(|err| panic!("{err}"));

    // With no configured token values nothing is forbidden.
    AgentDriver::default()
        .guard_capture(format!("token={TOKEN}").as_bytes(), b"")
        .unwrap_or_else(|err| panic!("{err}"));
}
