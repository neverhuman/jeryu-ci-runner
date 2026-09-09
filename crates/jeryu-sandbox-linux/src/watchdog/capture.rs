//! Bounded, nonblocking pipe capture. Spool descriptors belong to the caller.

use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{FileExt, MetadataExt};

pub const DEFAULT_OUTPUT_LIMIT: usize = 8 * 1024 * 1024;
pub const MAX_OUTPUT_LIMIT: usize = 64 * 1024 * 1024;

/// Output limits and optional private, initially empty spool files.
#[derive(Debug)]
pub struct CaptureOptions {
    pub max_bytes_per_stream: usize,
    pub stdout_spool: Option<File>,
    pub stderr_spool: Option<File>,
}

impl Default for CaptureOptions {
    fn default() -> Self {
        Self {
            max_bytes_per_stream: DEFAULT_OUTPUT_LIMIT,
            stdout_spool: None,
            stderr_spool: None,
        }
    }
}

impl CaptureOptions {
    /// Validate before spawning a job. No spool is created, truncated or deleted.
    pub fn validate(&self) -> io::Result<()> {
        if !(1..=MAX_OUTPUT_LIMIT).contains(&self.max_bytes_per_stream) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid output limit",
            ));
        }
        for file in [&self.stdout_spool, &self.stderr_spool]
            .into_iter()
            .flatten()
        {
            let metadata = file.metadata()?;
            if !metadata.is_file() || metadata.len() != 0 || metadata.nlink() != 1
                || metadata.mode() & 0o077 != 0
                // SAFETY: geteuid has no arguments or side effects.
                || metadata.uid() != unsafe { libc::geteuid() }
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "spool must be an empty private single-link file",
                ));
            }
            // File::try_clone shares an open-file cursor. Refuse a pre-positioned
            // descriptor, and use positional I/O after admission so later cursor
            // movement cannot introduce an unhashed sparse prefix.
            let fd = file.as_raw_fd();
            // SAFETY: these calls inspect a caller-owned, live file descriptor.
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            let position = unsafe { libc::lseek(fd, 0, libc::SEEK_CUR) };
            if flags == -1 || position == -1 {
                return Err(io::Error::last_os_error());
            }
            if flags & libc::O_ACCMODE != libc::O_RDWR
                || flags & libc::O_APPEND != 0
                || position != 0
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "spool must be read/write, non-append and positioned at zero",
                ));
            }
            // SAFETY: FD_CLOEXEC confines this owned spool to the supervisor.
            let fd_flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
            if fd_flags == -1
                || unsafe { libc::fcntl(fd, libc::F_SETFD, fd_flags | libc::FD_CLOEXEC) } == -1
            {
                return Err(io::Error::last_os_error());
            }
        }
        if let (Some(stdout), Some(stderr)) = (&self.stdout_spool, &self.stderr_spool) {
            let a = stdout.metadata()?;
            let b = stderr.metadata()?;
            if (a.dev(), a.ino()) == (b.dev(), b.ino()) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "stdout and stderr need distinct spools",
                ));
            }
        }
        Ok(())
    }
}

pub(super) struct Capture {
    pipe: Option<Box<dyn Read + Send>>,
    spool: Option<File>,
    pub bytes: Vec<u8>,
    limit: usize,
    digest: Sha256,
    pub overflow: bool,
    pub eof: bool,
}

impl Capture {
    pub fn new<R: Read + AsRawFd + Send + 'static>(
        pipe: Option<R>,
        spool: Option<File>,
        limit: usize,
    ) -> io::Result<Self> {
        if !(1..=MAX_OUTPUT_LIMIT).contains(&limit) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid capture limit",
            ));
        }
        if let Some(pipe) = &pipe {
            let fd = pipe.as_raw_fd();
            // SAFETY: fd is an owned live pipe; fcntl only adjusts its status flags.
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            if flags == -1
                || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == -1
            {
                return Err(io::Error::last_os_error());
            }
        }
        let eof = pipe.is_none();
        Ok(Self {
            pipe: pipe.map(|p| Box::new(p) as _),
            spool,
            bytes: Vec::new(),
            limit,
            digest: Sha256::new(),
            overflow: false,
            eof,
        })
    }

    /// Limit work per sweep so a noisy stream cannot starve cancellation.
    pub fn drain(&mut self) -> io::Result<()> {
        let Some(pipe) = &mut self.pipe else {
            return Ok(());
        };
        let mut buffer = [0u8; 8192];
        for _ in 0..16 {
            let count = match pipe.read(&mut buffer) {
                Ok(0) => {
                    self.eof = true;
                    return Ok(());
                }
                Ok(count) => count,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(()),
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            };
            let retained = count.min(self.limit - self.bytes.len());
            let bytes = &buffer[..retained];
            self.bytes
                .try_reserve(bytes.len())
                .map_err(io::Error::other)?;
            if let Some(spool) = &self.spool {
                spool.write_all_at(bytes, self.bytes.len() as u64)?;
            }
            self.bytes.extend_from_slice(bytes);
            self.digest.update(bytes);
            if retained != count {
                self.overflow = true;
                return Ok(());
            }
        }
        Ok(())
    }

    pub fn finish(&mut self) -> io::Result<String> {
        let digest = self.digest.clone().finalize();
        if let Some(spool) = &self.spool {
            spool.sync_all()?;
            let metadata = spool.metadata()?;
            if metadata.len() != self.bytes.len() as u64
                || metadata.nlink() != 1
                || metadata.mode() & 0o077 != 0
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "spool custody or length changed",
                ));
            }
            let mut observed = Sha256::new();
            let mut position = 0;
            let mut buffer = [0_u8; 8192];
            while position < metadata.len() {
                let remaining = (metadata.len() - position).min(buffer.len() as u64) as usize;
                let count = spool.read_at(&mut buffer[..remaining], position)?;
                if count == 0 {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "spool shortened",
                    ));
                }
                observed.update(&buffer[..count]);
                position += count as u64;
            }
            if spool.metadata()?.len() != metadata.len() || observed.finalize() != digest {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "spool bytes differ from captured output",
                ));
            }
        }
        Ok(format!("sha256:{digest:x}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Seek, SeekFrom, Write};
    use std::os::unix::net::UnixStream;

    fn capture(bytes: &[u8], limit: usize, spool: Option<File>) -> Capture {
        let (reader, mut writer) = UnixStream::pair().unwrap();
        writer.write_all(bytes).unwrap();
        drop(writer);
        let mut capture = Capture::new(Some(reader), spool, limit).unwrap();
        capture.drain().unwrap();
        capture
    }

    #[test]
    fn private_spool_must_be_empty_single_link_read_write_and_positioned_at_zero() {
        let spool = tempfile::NamedTempFile::new().unwrap();
        let mut alias = spool.as_file().try_clone().unwrap();
        let options = CaptureOptions {
            stdout_spool: Some(spool.as_file().try_clone().unwrap()),
            ..Default::default()
        };
        options.validate().unwrap();
        // SAFETY: alias holds a live descriptor.
        assert_ne!(
            unsafe { libc::fcntl(alias.as_raw_fd(), libc::F_GETFD) } & libc::FD_CLOEXEC,
            0
        );
        alias.seek(SeekFrom::Start(12)).unwrap();
        assert!(options.validate().is_err());
        alias.seek(SeekFrom::Start(0)).unwrap();
        alias.write_all(b"occupied").unwrap();
        assert!(options.validate().is_err());
    }

    #[test]
    fn read_only_append_and_same_inode_spools_are_refused() {
        let spool = tempfile::NamedTempFile::new().unwrap();
        let read_only = File::open(spool.path()).unwrap();
        assert!(
            CaptureOptions {
                stdout_spool: Some(read_only),
                ..Default::default()
            }
            .validate()
            .is_err()
        );
        let append = std::fs::OpenOptions::new()
            .read(true)
            .append(true)
            .open(spool.path())
            .unwrap();
        assert!(
            CaptureOptions {
                stdout_spool: Some(append),
                ..Default::default()
            }
            .validate()
            .is_err()
        );
        let options = CaptureOptions {
            stdout_spool: Some(spool.as_file().try_clone().unwrap()),
            stderr_spool: Some(spool.as_file().try_clone().unwrap()),
            ..Default::default()
        };
        assert!(options.validate().is_err());
    }

    #[test]
    fn positional_spool_writes_ignore_later_shared_cursor_changes() {
        let spool = tempfile::NamedTempFile::new().unwrap();
        let mut alias = spool.as_file().try_clone().unwrap();
        let options = CaptureOptions {
            stdout_spool: Some(spool.as_file().try_clone().unwrap()),
            ..Default::default()
        };
        options.validate().unwrap();
        alias.seek(SeekFrom::Start(100)).unwrap();
        let mut captured = capture(b"\xff\x00abc", 8, options.stdout_spool);
        let expected = format!("sha256:{:x}", Sha256::digest(b"\xff\x00abc"));
        assert_eq!(captured.finish().unwrap(), expected);
        assert_eq!(std::fs::read(spool.path()).unwrap(), b"\xff\x00abc");
    }

    #[test]
    fn changed_spool_bytes_never_receive_the_capture_digest() {
        let spool = tempfile::NamedTempFile::new().unwrap();
        let mut captured = capture(b"original", 32, Some(spool.as_file().try_clone().unwrap()));
        spool.as_file().write_all_at(b"replaced", 0).unwrap();
        assert!(captured.finish().is_err());
    }

    #[test]
    fn cap_and_digest_cover_only_the_retained_prefix() {
        let mut captured = capture(b"123456789", 8, None);
        assert!(captured.overflow);
        assert_eq!(captured.bytes, b"12345678");
        assert_eq!(
            captured.finish().unwrap(),
            format!("sha256:{:x}", Sha256::digest(b"12345678"))
        );
    }

    #[test]
    fn reader_errors_are_not_empty_successful_output() {
        struct Broken(File);
        impl AsRawFd for Broken {
            fn as_raw_fd(&self) -> i32 {
                self.0.as_raw_fd()
            }
        }
        impl Read for Broken {
            fn read(&mut self, _buffer: &mut [u8]) -> io::Result<usize> {
                Err(io::Error::other("injected read failure"))
            }
        }
        let mut captured =
            Capture::new(Some(Broken(tempfile::tempfile().unwrap())), None, 8).unwrap();
        assert!(
            captured
                .drain()
                .unwrap_err()
                .to_string()
                .contains("injected read failure")
        );
    }
}
