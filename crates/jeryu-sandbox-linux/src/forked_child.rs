//! The one termination path for post-fork children in this crate.

/// End a forked child immediately with `code`.
///
/// Post-fork children must not unwind, run destructors, flush stdio buffers
/// shared with the parent, or run atexit handlers, so the process is ended with
/// the async-signal-safe `_exit` rather than `std::process::exit`.
pub(crate) fn terminate(code: i32) -> ! {
    // SAFETY: `_exit` is async-signal-safe, touches no Rust state and never returns.
    unsafe { libc::_exit(code) }
}
