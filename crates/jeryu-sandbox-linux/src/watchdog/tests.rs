use super::*;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};

fn command(program: &str) -> Command {
    let mut cmd = Command::new(program);
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    // SAFETY: setpgid only changes the forked child's process group.
    unsafe {
        cmd.pre_exec(|| {
            if libc::setpgid(0, 0) != 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    cmd
}

#[test]
fn fast_command_completes_without_timeout() {
    let child = command("/bin/echo").arg("hello").spawn().unwrap();
    let out = run_with_watchdog(child, Duration::from_secs(5)).unwrap();
    assert!(!out.timed_out);
    assert!(!out.output_limit_exceeded);
    assert_eq!(out.exit_code, Some(0));
    assert_eq!(out.stdout, b"hello\n");
    assert_eq!(out.termination_scope, TerminationScope::ProcessGroup);
}

#[test]
fn slow_command_is_killed_on_timeout() {
    let child = command("/bin/sleep").arg("30").spawn().unwrap();
    let out = run_with_watchdog(child, Duration::from_millis(100)).unwrap();
    assert!(out.timed_out);
    assert!(out.elapsed < Duration::from_secs(5));
}

#[test]
fn fork_subtree_is_stopped_via_group_kill() {
    let child = command("/bin/sh")
        .args(["-c", "sleep 30 & sleep 30"])
        .spawn()
        .unwrap();
    let out = run_with_watchdog(child, Duration::from_millis(100)).unwrap();
    assert!(out.timed_out);
    assert!(out.elapsed < Duration::from_secs(5));
}

#[test]
fn leader_exit_does_not_leave_a_pipe_reader_waiting_for_descendants() {
    let child = command("/bin/sh")
        .args(["-c", "sleep 30 & echo child-started; exit 0"])
        .spawn()
        .unwrap();
    let out = run_with_watchdog(child, Duration::from_secs(10)).unwrap();
    assert_eq!(out.exit_code, Some(0));
    assert_eq!(out.stdout, b"child-started\n");
    assert!(out.elapsed < Duration::from_secs(5));
}

#[test]
fn nonzero_exit_is_preserved() {
    let child = command("/bin/sh")
        .args(["-c", "echo failure >&2; exit 7"])
        .spawn()
        .unwrap();
    let out = run_with_watchdog(child, Duration::from_secs(5)).unwrap();
    assert_eq!(out.exit_code, Some(7));
    assert_eq!(out.stderr, b"failure\n");
}

#[test]
fn both_noisy_streams_are_bounded_and_fail_on_overflow() {
    let child = command("/bin/sh")
        .args([
            "-c",
            "while :; do printf 1234567890; printf abcdefghij >&2; done",
        ])
        .spawn()
        .unwrap();
    let options = WatchdogOptions {
        capture: CaptureOptions {
            max_bytes_per_stream: 4096,
            ..Default::default()
        },
        ..Default::default()
    };
    let out = run_with_watchdog_options(child, Duration::from_secs(5), options).unwrap();
    assert!(out.output_limit_exceeded);
    assert!(!out.stdout.is_empty() && out.stdout.len() <= 4096);
    assert!(!out.stderr.is_empty() && out.stderr.len() <= 4096);
    assert!(out.elapsed < Duration::from_secs(5));
}

#[test]
fn exact_limit_is_not_overflow() {
    let child = command("/bin/printf").arg("12345678").spawn().unwrap();
    let options = WatchdogOptions {
        capture: CaptureOptions {
            max_bytes_per_stream: 8,
            ..Default::default()
        },
        ..Default::default()
    };
    let out = run_with_watchdog_options(child, Duration::from_secs(5), options).unwrap();
    assert_eq!(out.stdout, b"12345678");
    assert!(!out.output_limit_exceeded);
    assert_eq!(out.exit_code, Some(0));
}

#[test]
fn cancellation_terminates_and_reaps_the_child() {
    let child = command("/bin/sh")
        .args(["-c", "sleep 30 & sleep 30"])
        .spawn()
        .unwrap();
    let options = WatchdogOptions::default();
    let token = options.cancellation.clone();
    let cancellation = thread::spawn(move || {
        thread::sleep(Duration::from_millis(50));
        token.cancel();
    });
    let out = run_with_watchdog_options(child, Duration::from_secs(30), options).unwrap();
    cancellation.join().unwrap();
    assert!(out.cancelled);
    assert!(!out.timed_out);
    assert!(out.elapsed < Duration::from_secs(5));
}

#[test]
fn invalid_options_after_spawn_still_reap() {
    let child = command("/bin/sleep").arg("30").spawn().unwrap();
    let pid = child.id() as i32;
    let options = WatchdogOptions {
        capture: CaptureOptions {
            max_bytes_per_stream: 0,
            ..Default::default()
        },
        ..Default::default()
    };
    let error = run_with_watchdog_options(child, Duration::from_secs(5), options).unwrap_err();
    assert!(error.to_string().contains("invalid output limit"));
    assert_eq!(
        process::exited(pid).unwrap_err().raw_os_error(),
        Some(libc::ECHILD)
    );
}

#[test]
fn a_reaped_child_is_not_permission_to_signal_its_numeric_group() {
    let mut child = command("/bin/true").spawn().unwrap();
    child.wait().unwrap();
    let start = Instant::now();
    let error = run_with_watchdog(child, Duration::from_secs(5)).unwrap_err();
    assert!(error.to_string().contains("cleanup unresolved"));
    assert!(start.elapsed() < Duration::from_secs(5));
}

#[test]
fn denied_signal_never_becomes_a_successful_cleanup_receipt() {
    let child = command("/bin/sleep").arg("0.05").spawn().unwrap();
    let pid = child.id() as i32;
    let mut custody = Custody {
        child,
        cgroup: None,
        pid,
        group: true,
    };
    let error = custody
        .finish_with_signal(&mut None, |_, _| {
            Err(io::Error::from_raw_os_error(libc::EPERM))
        })
        .unwrap_err();
    assert!(error.to_string().contains("process kill failed"));
    assert_eq!(
        process::exited(pid).unwrap_err().raw_os_error(),
        Some(libc::ECHILD)
    );
}
