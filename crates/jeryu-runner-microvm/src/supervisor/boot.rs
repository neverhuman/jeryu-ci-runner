//! Firecracker configuration and authenticated guest handshake.
use super::*;
impl MicroVmSession {
    pub(super) fn boot(&mut self, runtime: &VerifiedRuntime) -> RunnerResult<()> {
        let root = self.root()?;
        std::fs::create_dir_all(&root)?;
        trusted_directory(&root)?;
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))?;
        for name in ["logs", "metrics"] {
            self.diagnostics
                .push(DiagnosticDrain::open(&root.join(name), self.record.uid)?);
        }
        std::fs::create_dir(root.join("dev"))?;
        nix::sys::stat::mknod(
            &root.join("dev/null"),
            nix::sys::stat::SFlag::S_IFCHR,
            nix::sys::stat::Mode::from_bits_truncate(0o666),
            nix::sys::stat::makedev(1, 3),
        )
        .map_err(|_| failed("microvm_resource_custody_failed"))?;
        for (source, target) in [(runtime.kernel(), "kernel"), (runtime.rootfs(), "rootfs")] {
            std::fs::copy(source, root.join(target))?;
            std::fs::set_permissions(root.join(target), std::fs::Permissions::from_mode(0o444))?;
        }
        let source_bundle = runtime.workspace_bundle(&self.lease.workspace)?;
        if let Some(source) = &source_bundle {
            std::fs::copy(source, root.join("source-bundle"))?;
            std::fs::set_permissions(
                root.join("source-bundle"),
                std::fs::Permissions::from_mode(0o444),
            )?;
        }
        let mut workspace = OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(root.join("workspace"))?;
        // Admission charges the full logical maximum, not allocated blocks.
        // A sparse disk never grants extra capacity to another session.
        workspace
            .set_len(u64::from(self.lease.resources.workspace_gib) * 1024 * 1024 * 1024)
            .map_err(|_| failed("microvm_disk_capacity_unavailable"))?;
        if let Some(checkpoint) = &self.lease.checkpoint {
            self.node
                .checkpoints
                .restore(checkpoint, &self.lease, &mut workspace)?;
        }
        chown(
            &root.join("workspace"),
            Some(Uid::from_raw(self.record.uid)),
            Some(Gid::from_raw(self.record.uid)),
        )
        .map_err(|_| failed("microvm_resource_custody_failed"))?;
        let memory_limit = (u64::from(self.lease.resources.memory_mib) + 256) * 1024 * 1024;
        let args = vec![
            "--id".into(),
            self.record.resource_id.clone(),
            "--exec-file".into(),
            runtime.firecracker().display().to_string(),
            "--uid".into(),
            self.record.uid.to_string(),
            "--gid".into(),
            self.record.uid.to_string(),
            "--chroot-base-dir".into(),
            self.node.config.state_dir.join("j").display().to_string(),
            "--new-pid-ns".into(),
            "--cgroup-version".into(),
            "2".into(),
            "--parent-cgroup".into(),
            "jeryu-microvm".into(),
            "--cgroup".into(),
            format!("memory.max={memory_limit}"),
            "--cgroup".into(),
            "memory.swap.max=0".into(),
            "--cgroup".into(),
            format!(
                "cpu.max={} 100000",
                u32::from(self.lease.resources.vcpus) * 100000
            ),
            "--cgroup".into(),
            "pids.max=128".into(),
            "--resource-limit".into(),
            "no-file=1024".into(),
            "--resource-limit".into(),
            format!(
                "fsize={}",
                u64::from(self.lease.resources.workspace_gib) * 1024 * 1024 * 1024
            ),
            "--".into(),
            "--api-sock".into(),
            "/a.sock".into(),
        ];
        self.child = Some(jeryu_sandbox_linux::microvm::spawn_jailer(
            runtime.jailer(),
            &args,
        )?);
        let socket = root.join("a.sock");
        let deadline = Instant::now() + Duration::from_secs(60);
        while !socket.exists() {
            self.ensure_live()?;
            if Instant::now() >= deadline {
                return Err(failed("microvm_boot_timeout"));
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        api::put(
            &socket,
            "/machine-config",
            json!({"vcpu_count":self.lease.resources.vcpus,
            "mem_size_mib":self.lease.resources.memory_mib,"smt":false,"track_dirty_pages":false}),
        )?;
        api::put(
            &socket,
            "/boot-source",
            json!({"kernel_image_path":"/kernel",
            "boot_args":"reboot=k panic=1 pci=off root=/dev/vda ro init=/jeryu-guestd 8250.nr_uarts=0"}),
        )?;
        for (id, path, is_root, readonly) in [
            ("rootfs", "/rootfs", true, true),
            ("workspace", "/workspace", false, false),
        ] {
            api::put(
                &socket,
                &format!("/drives/{id}"),
                json!({"drive_id":id,"path_on_host":path,
                "is_root_device":is_root,"is_read_only":readonly}),
            )?;
        }
        if source_bundle.is_some() {
            api::put(
                &socket,
                "/drives/source",
                json!({"drive_id":"source",
                "path_on_host":"/source-bundle","is_root_device":false,"is_read_only":true}),
            )?;
        }
        // No NIC. There are no host listeners for guest-initiated vsock requests.
        api::put(
            &socket,
            "/vsock",
            json!({"guest_cid":3,"uds_path":"/v.sock"}),
        )?;
        api::put(
            &socket,
            "/logger",
            json!({"log_path":"/logs","level":"Error","show_level":false,"show_log_origin":false}),
        )?;
        api::put(&socket, "/metrics", json!({"metrics_path":"/metrics"}))?;
        api::put(&socket, "/actions", json!({"action_type":"InstanceStart"}))?;
        let mut channel = loop {
            self.ensure_live()?;
            match api::guest_channel(&root.join("v.sock"), Duration::from_millis(500)) {
                Ok(channel) => break channel,
                Err(_) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(20))
                }
                Err(_) => return Err(failed("microvm_guest_handshake_timeout")),
            }
        };
        let challenge = format!(
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        );
        channel.set_read_timeout(Some(
            deadline
                .saturating_duration_since(Instant::now())
                .max(Duration::from_millis(1)),
        ))?;
        write_frame(
            &mut channel,
            &GuestRequest::Bind {
                lease: Box::new(self.lease.clone()),
                challenge: challenge.clone(),
                remaining_lease_millis: u32::try_from(
                    self.lease
                        .expires_at_unix_millis
                        .saturating_sub(
                            u64::try_from(jeryu_runner_core::receipt::now_ms())
                                .map_err(|_| failed("microvm_clock_invalid"))?,
                        )
                        .checked_sub(1000)
                        .filter(|remaining| *remaining > 0)
                        .ok_or_else(|| failed("microvm_lease_expired"))?,
                )
                .map_err(|_| failed("microvm_lease_invalid"))?,
            },
        )?;
        match read_frame::<GuestEvent>(&mut channel)? {
            GuestEvent::Ready {
                challenge: received,
                session_id,
                generation,
                run_id,
                workspace,
                ..
            } if received == challenge
                && session_id == self.lease.context.session_id
                && generation == self.lease.context.generation
                && run_id == self.lease.context.run_id =>
            {
                match (&self.lease.workspace, &workspace) {
                    (jeryu_runner_protocol::wire::v2::WorkspaceSource::EmptyFixture, None) => (),
                    (
                        jeryu_runner_protocol::wire::v2::WorkspaceSource::GitBundle {
                            main_revision,
                            ..
                        },
                        Some(ready),
                    ) if ready.main_revision == *main_revision
                        && ready.source_revision == self.lease.context.source_revision => {}
                    _ => return Err(failed("microvm_main_sync_receipt_invalid")),
                }
                self.workspace_ready = workspace;
            }
            GuestEvent::Error { code } => {
                return Err(RunnerError::new("microvm_guest_bootstrap_failed", code));
            }
            _ => return Err(failed("microvm_guest_handshake_invalid")),
        }
        self.reader = Some(crate::transport::GuestReader::new(
            channel.try_clone()?,
            self.lease.expires_at_unix_millis,
            self.started + self.maximum_runtime,
        ));
        self.channel = Some(channel);
        let vmm = crate::vmm::VmmGuard::recover(&self.record, &root)?
            .ok_or_else(|| failed("microvm_process_missing"))?;
        self.record.vmm = Some(vmm.identity.clone());
        self.vmm = Some(Arc::new(vmm));
        self.record.state = ResourceState::Running;
        self.record.retain_workspace = true;
        self.record.workspace = self.workspace_ready.clone();
        self.node.journal.write(&self.record)?;
        Ok(())
    }
}
