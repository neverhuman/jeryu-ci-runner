use crate::{
    input::{self, Input},
    reaper::Reaper,
};
use jeryu_runner_protocol::{
    guest::{GuestEvent, GuestProfile},
    wire::v2::{MAX_TERMINAL_BYTES, SessionResources},
};
use jeryu_sandbox_linux::{guest::spawn_unprivileged_pty, open_pty, resize_pty};
use nix::{
    fcntl::{FcntlArg, OFlag, fcntl},
    sys::signal::{Signal, killpg},
    unistd::{Pid, tcgetpgrp},
};
use std::{
    collections::BTreeMap,
    fs::File,
    io::Read,
    os::fd::AsRawFd,
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc::SyncSender,
    },
    time::{Duration, Instant},
};

pub struct GuestProcess {
    pid: Pid,
    master: File,
    input: SyncSender<Input>,
    finished: Arc<AtomicBool>,
    profile: GuestProfile,
}

impl GuestProcess {
    pub fn start(
        channel: &str,
        profile: GuestProfile,
        resources: &SessionResources,
        writer: Arc<Mutex<File>>,
        reaper: Reaper,
        activity: Arc<Mutex<Instant>>,
        workspace: &Path,
    ) -> std::io::Result<Self> {
        let (master, slave) =
            open_pty().map_err(|_| std::io::Error::other("guest_pty_unavailable"))?;
        fcntl(&master, FcntlArg::F_SETFL(OFlag::O_NONBLOCK)).map_err(std::io::Error::from)?;
        let env = BTreeMap::from([
            ("HOME".into(), "/run/agent-home".into()),
            ("PATH".into(), "/usr/bin:/bin".into()),
            ("TERM".into(), "xterm-256color".into()),
            ("TMPDIR".into(), "/tmp".into()),
            ("LC_ALL".into(), "C.UTF-8".into()),
        ]);
        let args: &[&str] = match profile {
            GuestProfile::Fixture => &[
                "-c",
                "set -eu; test \"$(id -u)\" = 1000; test ! -e /home/ubuntu; printf 'fixture:guest\\n'; printf 'int main(void){return 0;}\\n' > main.c; cc main.c -o build; ./build; printf 'fixture:built\\n'",
            ],
            GuestProfile::Shell => &["-i"],
        };
        let pid = reaper.spawn(|| {
            spawn_unprivileged_pty("/bin/sh", args, &env, workspace, &slave, resources.pids_max)
        })?;
        drop(slave);
        let master = File::from(master);
        let finished = Arc::new(AtomicBool::new(false));
        let input = input::start(master.try_clone()?, writer.clone(), finished.clone());
        let process = Self {
            pid,
            master,
            input,
            finished: finished.clone(),
            profile,
        };
        let mut output = process.master.try_clone()?;
        let channel = channel.to_string();
        let rate = resources.output_bytes_per_second as usize;
        crate::emit(
            &writer,
            &GuestEvent::Started {
                channel: channel.clone(),
            },
        )?;
        std::thread::spawn(move || {
            let mut buffer = [0; MAX_TERMINAL_BYTES];
            let mut sequence = 0;
            let mut window = Instant::now();
            let mut window_bytes = 0;
            let mut exit = None;
            let mut exit_deadline = None;
            loop {
                if let Some(code) = reaper.result(pid) {
                    exit = Some(code);
                    if let Ok(foreground) = tcgetpgrp(&output)
                        && foreground.as_raw() > 1
                    {
                        let _ = killpg(foreground, Signal::SIGKILL);
                    }
                    let _ = killpg(pid, Signal::SIGKILL);
                    exit_deadline = Some(Instant::now() + Duration::from_millis(100));
                }
                if finished.load(Ordering::Acquire)
                    || exit_deadline.is_some_and(|deadline| Instant::now() >= deadline)
                {
                    break;
                }
                if window.elapsed() >= Duration::from_secs(1) {
                    window = Instant::now();
                    window_bytes = 0;
                }
                let size = buffer.len().min(rate.saturating_sub(window_bytes));
                if size == 0 {
                    std::thread::sleep(Duration::from_millis(5));
                    continue;
                }
                let length = match output.read(&mut buffer[..size]) {
                    Ok(0) if exit.is_some() => break,
                    Err(error)
                        if error.raw_os_error() == Some(nix::libc::EIO) && exit.is_some() =>
                    {
                        break;
                    }
                    Ok(0) => {
                        std::thread::sleep(Duration::from_millis(5));
                        continue;
                    }
                    Err(error)
                        if error.kind() == std::io::ErrorKind::WouldBlock
                            || error.raw_os_error() == Some(nix::libc::EIO) =>
                    {
                        std::thread::sleep(Duration::from_millis(5));
                        continue;
                    }
                    Err(_) => break,
                    Ok(length) => length,
                };
                if let Ok(mut activity) = activity.lock() {
                    *activity = Instant::now();
                }
                window_bytes += length;
                sequence += 1;
                if crate::emit(
                    &writer,
                    &GuestEvent::Output {
                        channel: channel.clone(),
                        sequence,
                        bytes: buffer[..length].to_vec(),
                    },
                )
                .is_err()
                {
                    break;
                }
            }
            finished.store(true, Ordering::Release);
            let _ = killpg(pid, Signal::SIGKILL);
            let _ = crate::emit(
                &writer,
                &GuestEvent::Exited {
                    channel,
                    exit_code: exit.flatten(),
                },
            );
        });
        Ok(process)
    }

    pub fn finished(&self) -> bool {
        self.finished.load(Ordering::Acquire)
    }
    pub fn active_agent(&self) -> bool {
        self.profile != GuestProfile::Shell && !self.finished()
    }
    pub fn input(&self, request_id: String, bytes: Vec<u8>) -> std::io::Result<()> {
        self.input
            .try_send(Input { request_id, bytes })
            .map_err(|_| std::io::Error::other("guest_input_queue_full"))
    }
    pub fn resize(&self, rows: u16, cols: u16) -> std::io::Result<()> {
        resize_pty(self.master.as_raw_fd(), rows, cols)
            .map_err(|_| std::io::Error::other("guest_resize_failed"))
    }
    pub fn interrupt(&self) -> std::io::Result<()> {
        let foreground = tcgetpgrp(&self.master)?;
        if foreground.as_raw() <= 1 || self.finished() {
            return Err(std::io::Error::other("guest_foreground_unavailable"));
        }
        killpg(foreground, Signal::SIGINT).map_err(std::io::Error::from)
    }
}

impl Drop for GuestProcess {
    fn drop(&mut self) {
        if self.finished.swap(true, Ordering::AcqRel) {
            return;
        }
        if let Ok(foreground) = tcgetpgrp(&self.master)
            && foreground.as_raw() > 1
        {
            let _ = killpg(foreground, Signal::SIGKILL);
        }
        let _ = killpg(self.pid, Signal::SIGKILL);
    }
}
