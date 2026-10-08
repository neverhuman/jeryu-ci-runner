//! Private self-reexec guardian. It fences processes without node threads,
//! guest transport, journal locks or checkpoint I/O. No public command route.
mod deadline;
pub(crate) mod fence;
mod process;
use crate::{
    artifacts::{sha256_reader, trusted_directory, trusted_file},
    journal::ResourceRecord,
    vmm::VmmGuard,
};
pub use deadline::Deadline;
use jeryu_runner_core::{RunnerError, RunnerResult};
use jeryu_runner_protocol::wire::v2::SessionLease;
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::{Read, Write},
    os::{
        fd::OwnedFd,
        unix::{
            fs::{MetadataExt, OpenOptionsExt},
            net::UnixStream,
        },
    },
    path::{Path, PathBuf},
    process::Child,
    sync::{
        Arc, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Launch {
    record: ResourceRecord,
    lease: SessionLease,
    lease_key: [u8; 32],
    jail_root: PathBuf,
    jailer: PathBuf,
    arguments: Vec<String>,
}

pub(crate) struct Guardian {
    channel: UnixStream,
    child: Child,
    pub identity: crate::vmm::VmmIdentity,
}
impl Guardian {
    pub(crate) fn launch(
        record: &ResourceRecord,
        lease: &SessionLease,
        key: [u8; 32],
        root: &Path,
        jailer: &Path,
        arguments: Vec<String>,
        fence: fs::File,
    ) -> RunnerResult<Self> {
        let executable = std::env::current_exe()?;
        trusted_file(&executable, true)?;
        let (mut channel, child_channel) = UnixStream::pair()?;
        channel.set_read_timeout(Some(Duration::from_secs(60)))?;
        channel.set_write_timeout(Some(Duration::from_secs(1)))?;
        let mut child = jeryu_sandbox_linux::microvm::spawn_guardian(
            &executable,
            OwnedFd::from(child_channel),
            fs::File::from(
                rustix::io::fcntl_dupfd_cloexec(&fence, 3)
                    .map_err(|_| failed("microvm_guardian_descriptor_invalid"))?,
            ),
        )?;
        let request = Launch {
            record: record.clone(),
            lease: lease.clone(),
            lease_key: key,
            jail_root: root.into(),
            jailer: jailer.into(),
            arguments,
        };
        // Any failure drops the private socket; the guardian never cancels its
        // hard bound on EOF. A child owns launch before this RPC returns.
        let result = (|| {
            write_message(&mut channel, &request)?;
            let ready: crate::vmm::VmmIdentity = read_message(&mut channel)?;
            Ok(ready)
        })();
        match result {
            Ok(identity) => Ok(Self {
                channel,
                child,
                identity,
            }),
            Err(error) => {
                drop(channel);
                let _ = child.try_wait();
                Err(error)
            }
        }
    }
    pub(crate) fn finish(&mut self) -> RunnerResult<()> {
        self.channel.shutdown(std::net::Shutdown::Both)?;
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(status) = self.child.try_wait()? {
                return if status.success() {
                    Ok(())
                } else {
                    Err(failed("microvm_guardian_failed"))
                };
            }
            if Instant::now() >= deadline {
                return Err(failed("microvm_guardian_exit_timeout"));
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

/// Call before ordinary argument parsing in a root-immutable node executable.
/// Returns true only for the private guardian entrypoint, after fencing ends.
pub fn run_if_requested() -> RunnerResult<bool> {
    let args: Vec<_> = std::env::args_os().collect();
    if args.get(1).is_none_or(|arg| arg != "--vm-guardian") {
        return Ok(false);
    }
    if args.len() != 2 || !nix::unistd::Uid::effective().is_root() {
        return Err(failed("microvm_guardian_custody_denied"));
    }
    jeryu_sandbox_linux::microvm::disable_core_dumps()?;
    let descriptor = rustix::io::fcntl_dupfd_cloexec(std::io::stdin(), 3)
        .map_err(|_| failed("microvm_guardian_descriptor_invalid"))?;
    let fence = rustix::io::fcntl_dupfd_cloexec(std::io::stdout(), 3)
        .map_err(|_| failed("microvm_guardian_descriptor_invalid"))?;
    // Only CLOEXEC duplicates survive in this process. Jailer/VMM inherit none.
    let null = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/null")?;
    rustix::stdio::dup2_stdin(&null).map_err(|_| failed("microvm_guardian_descriptor_invalid"))?;
    rustix::stdio::dup2_stdout(&null).map_err(|_| failed("microvm_guardian_descriptor_invalid"))?;
    let mut channel = UnixStream::from(descriptor);
    channel.set_read_timeout(Some(Duration::from_secs(1)))?;
    channel.set_write_timeout(Some(Duration::from_secs(1)))?;
    let launch: Launch = read_message(&mut channel)?;
    let fence = fs::File::from(fence);
    verify(&launch, &fence)?;
    process::run(launch, channel)?;
    drop(fence);
    Ok(true)
}
fn verify(launch: &Launch, fence: &fs::File) -> RunnerResult<()> {
    crate::lease_authority::verify(&launch.lease, &launch.lease_key)?;
    if launch.record.context != launch.lease.context
        || launch.record.expires_at_unix_millis != launch.lease.expires_at_unix_millis
        || launch
            .record
            .deadline
            .as_ref()
            .is_none_or(|deadline| !deadline.matches(launch.lease.expires_at_unix_millis))
        || launch.record.resource_id.len() != 32
        || !launch
            .record
            .resource_id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(failed("microvm_guardian_binding_invalid"));
    }
    trusted_directory(&launch.jail_root)?;
    let expected = launch
        .jail_root
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .and_then(Path::parent)
        .ok_or_else(|| failed("microvm_guardian_binding_invalid"))?
        .join("records")
        .join(format!("{}.json", launch.record.resource_id));
    let state = expected
        .parent()
        .and_then(Path::parent)
        .ok_or_else(|| failed("microvm_guardian_binding_invalid"))?;
    fence::bind(state, &launch.record.resource_id, fence)?;
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(nix::libc::O_NOFOLLOW)
        .open(expected)?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.uid() != 0
        || metadata.nlink() != 1
        || metadata.mode() & 0o077 != 0
        || metadata.len() > 16 * 1024
    {
        return Err(failed("microvm_guardian_custody_denied"));
    }
    let persisted: ResourceRecord =
        serde_json::from_reader(file).map_err(|_| failed("microvm_guardian_record_invalid"))?;
    if persisted.context != launch.record.context
        || persisted.deadline != launch.record.deadline
        || persisted.uid != launch.record.uid
        || persisted.resource_id != launch.record.resource_id
        || persisted.expires_at_unix_millis != launch.record.expires_at_unix_millis
        || persisted.firecracker_digest != launch.record.firecracker_digest
        || !matches!(persisted.state, crate::journal::ResourceState::Provisioning)
        || persisted.vmm.is_some()
    {
        return Err(failed("microvm_guardian_binding_invalid"));
    }
    let digest = sha256_reader(&mut trusted_file(&launch.jailer, true)?)?;
    if digest != launch.lease.runtime.jailer.digest {
        return Err(failed("microvm_guardian_custody_denied"));
    }
    if launch
        .record
        .deadline
        .as_ref()
        .ok_or_else(|| failed("microvm_guardian_binding_invalid"))?
        .expired()?
    {
        return Err(failed("microvm_lease_expired"));
    }
    Ok(())
}
fn write_message(stream: &mut UnixStream, value: &impl Serialize) -> RunnerResult<()> {
    let bytes = serde_json::to_vec(value).map_err(|_| failed("microvm_guardian_frame_invalid"))?;
    if bytes.len() > 65536 {
        return Err(failed("microvm_guardian_frame_limit"));
    }
    stream.write_all(&(bytes.len() as u32).to_be_bytes())?;
    stream.write_all(&bytes)?;
    Ok(())
}
fn read_message<T: serde::de::DeserializeOwned>(stream: &mut UnixStream) -> RunnerResult<T> {
    let mut size = [0; 4];
    stream.read_exact(&mut size)?;
    let size = u32::from_be_bytes(size) as usize;
    if size > 65536 {
        return Err(failed("microvm_guardian_frame_limit"));
    }
    let mut bytes = vec![0; size];
    stream.read_exact(&mut bytes)?;
    serde_json::from_slice(&bytes).map_err(|_| failed("microvm_guardian_frame_invalid"))
}
fn failed(code: &'static str) -> RunnerError {
    RunnerError::new(code, "independent VM fencing failed")
}
