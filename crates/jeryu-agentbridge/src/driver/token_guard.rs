//! Keep configured token values out of the live event stream.
//!
//! The driver forwards every captured line to its [`AgentEventSink`] while the
//! child is still running, so a check on the finished capture would run after
//! the value had already reached whatever consumes the sink. [`TokenGuardSink`]
//! sits between the drain loop and the caller's sink: a stdout/stderr line that
//! carries a configured value is withheld (a fixed marker is forwarded in its
//! place) and the hit is remembered so the run fails once supervision ends.

use super::{AgentEvent, AgentEventSink};
use std::sync::atomic::{AtomicBool, Ordering};

/// Forwarded in place of a withheld line. Names no value and no length.
pub(super) const WITHHELD_LINE: &str =
    "[jeryu: line withheld, it carried a configured token value]";

/// An [`AgentEventSink`] wrapper that withholds lines carrying a token value.
pub(super) struct TokenGuardSink<'a, S: AgentEventSink> {
    inner: &'a S,
    token_values: &'a [String],
    withheld: AtomicBool,
}

impl<'a, S: AgentEventSink> TokenGuardSink<'a, S> {
    pub(super) fn new(inner: &'a S, token_values: &'a [String]) -> Self {
        Self {
            inner,
            token_values,
            withheld: AtomicBool::new(false),
        }
    }

    /// True once any line was withheld; the run must then fail.
    pub(super) fn withheld_any(&self) -> bool {
        self.withheld.load(Ordering::SeqCst)
    }

    fn carries_token(&self, text: &str) -> bool {
        self.token_values
            .iter()
            .any(|token| !token.is_empty() && text.contains(token.as_str()))
    }
}

impl<S: AgentEventSink> AgentEventSink for TokenGuardSink<'_, S> {
    fn emit(&self, ev: AgentEvent) {
        let ev = match ev {
            AgentEvent::Stdout(text) if self.carries_token(&text) => {
                self.withheld.store(true, Ordering::SeqCst);
                AgentEvent::Stdout(WITHHELD_LINE.to_string())
            }
            AgentEvent::Stderr(text) if self.carries_token(&text) => {
                self.withheld.store(true, Ordering::SeqCst);
                AgentEvent::Stderr(WITHHELD_LINE.to_string())
            }
            other => other,
        };
        self.inner.emit(ev);
    }
}

#[cfg(test)]
mod tests {
    use super::super::{CollectingSink, drain_to_eof, spawn_line_reader};
    use super::*;
    use std::time::Duration;

    const TOKEN: &str = "jrt-invented-value-9f3b";

    /// Drives the real streaming path (line reader -> drain -> sink): the token
    /// line must never reach the caller's sink, not even before the run ends.
    #[test]
    fn a_streamed_token_line_never_reaches_the_inner_sink() {
        let inner = CollectingSink::new();
        let tokens = vec![TOKEN.to_string()];
        let guard = TokenGuardSink::new(&inner, &tokens);
        let rx = spawn_line_reader(std::io::Cursor::new(
            format!("before\nauth header {TOKEN}\nafter\n").into_bytes(),
        ));
        let mut buf = Vec::new();
        let mut used = 0;
        drain_to_eof(
            Some(&rx),
            &mut buf,
            &mut used,
            true,
            4096,
            Duration::from_secs(1),
            &guard,
        )
        .expect("drain to EOF");

        assert!(guard.withheld_any(), "the hit must fail the run");
        let lines: Vec<String> = inner
            .events()
            .into_iter()
            .filter_map(|event| match event {
                AgentEvent::Stdout(text) | AgentEvent::Stderr(text) => Some(text),
                _ => None,
            })
            .collect();
        assert_eq!(lines, vec!["before", WITHHELD_LINE, "after"]);
        assert!(lines.iter().all(|line| !line.contains(TOKEN)));
    }

    #[test]
    fn ordinary_lines_and_an_empty_denylist_pass_through() {
        let inner = CollectingSink::new();
        let none: Vec<String> = vec![String::new()];
        let guard = TokenGuardSink::new(&inner, &none);
        guard.emit(AgentEvent::Stderr(format!("token={TOKEN}")));
        assert!(!guard.withheld_any());
        assert_eq!(
            inner.events(),
            vec![AgentEvent::Stderr(format!("token={TOKEN}"))]
        );
    }
}
