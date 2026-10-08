//! Serialize controller handoffs; never expose an unacknowledged guest lease.
use super::*;
use jeryu_runner_protocol::wire::v2::TerminalScreen;
use std::time::Instant;

impl SessionHandle {
    pub fn acquire_control(
        &self,
        actor: &str,
        client_id: &str,
        terminal_channels: &[String],
        takeover: bool,
    ) -> RunnerResult<ControllerLease> {
        self.ensure_lease()?;
        let _handoff = self
            .handoff
            .lock()
            .map_err(|_| failed("session_state_failed"))?;
        let lease = self
            .state
            .lock()
            .map_err(|_| failed("session_state_failed"))?
            .acquire_control(actor, client_id, terminal_channels, takeover)?;
        self.fence(lease.epoch, 30000, terminal_channels.to_vec())?;
        Ok(lease)
    }

    pub(super) fn fence(
        &self,
        epoch: u64,
        ttl_millis: u32,
        terminal_channels: Vec<String>,
    ) -> RunnerResult<()> {
        let request_id = format!(
            "fence-{epoch}-{}",
            self.fence_id.fetch_add(1, Ordering::AcqRel)
        );
        {
            let mut state = self
                .state
                .lock()
                .map_err(|_| failed("session_state_failed"))?;
            state.control_ready = false;
            state.pending_fence = Some((request_id.clone(), epoch));
        }
        let request = GuestRequest::ControlFence {
            request_id,
            epoch,
            ttl_millis,
            terminal_channels,
        };
        if self.fences.try_send(request).is_err() {
            return self.fence_failed();
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            let state = self
                .state
                .lock()
                .map_err(|_| failed("session_state_failed"))?;
            if state.pending_fence.is_none() {
                if state.phase == RuntimePhase::Failed {
                    return Err(failed("session_control_fence_failed"));
                }
                return Ok(());
            }
            drop(state);
            std::thread::sleep(Duration::from_millis(5));
        }
        self.fence_failed()
    }

    fn fence_failed<T>(&self) -> RunnerResult<T> {
        self.stop.store(true, Ordering::Release);
        if let Ok(mut state) = self.state.lock() {
            state.control_ready = false;
            state.finish(
                RuntimePhase::Failed,
                Some("session_control_fence_failed".into()),
            );
        }
        Err(failed("session_control_fence_failed"))
    }

    pub fn screen(&self, actor: &str, channel: &str) -> RunnerResult<TerminalScreen> {
        let state = self
            .state
            .lock()
            .map_err(|_| failed("session_state_failed"))?;
        if !state.can_view(actor) {
            return Err(failed("session_access_forbidden"));
        }
        let screen = state
            .channels
            .get(channel)
            .ok_or_else(|| failed("session_channel_unknown"))?
            .screen
            .clone()
            .ok_or_else(|| failed("session_screen_unavailable"))?;
        Ok(TerminalScreen {
            protocol_version: jeryu_runner_protocol::wire::v2::PROTOCOL_VERSION.into(),
            message_type: "terminal-screen".into(),
            context: state.context.clone(),
            channel_id: channel.into(),
            screen,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use jeryu_runner_protocol::guest::GuestEvent;

    #[test]
    fn acquisition_waits_for_the_actual_matching_fence_and_blocks_input() {
        let context = super::super::super::tests::context();
        let (mut handle, state, _) = test_handle(context.clone());
        let (send, receive) = mpsc::sync_channel(4);
        handle.fences = send;
        let handle = Arc::new(handle);
        let acquiring = handle.clone();
        let worker = std::thread::spawn(move || {
            acquiring.acquire_control("user/alice", "client", &[], false)
        });
        let GuestRequest::ControlFence {
            request_id, epoch, ..
        } = receive.recv_timeout(Duration::from_secs(1)).unwrap()
        else {
            panic!("wrong request")
        };
        assert!(!worker.is_finished());
        assert!(!state.lock().unwrap().control_ready);
        assert!(
            state
                .lock()
                .unwrap()
                .ingest(GuestEvent::ControlFenced {
                    request_id: "foreign-fence".into(),
                    epoch
                })
                .is_err()
        );
        assert!(!state.lock().unwrap().control_ready);
        // A delayed ACK cannot leave the stored lease on its pre-wait clock.
        state.lock().unwrap().controller.as_mut().unwrap().expires =
            Instant::now() - Duration::from_secs(1);
        state
            .lock()
            .unwrap()
            .ingest(GuestEvent::ControlFenced { request_id, epoch })
            .unwrap();
        assert_eq!(worker.join().unwrap().unwrap().controller_id, "client");
        assert!(state.lock().unwrap().control_ready);
        assert!(
            state.lock().unwrap().controller.as_ref().unwrap().expires
                > Instant::now() + Duration::from_secs(29)
        );
        drop(receive);
        assert_eq!(
            handle
                .acquire_control("user/alice", "client", &[], false)
                .unwrap_err()
                .code(),
            "session_control_fence_failed"
        );
        assert!(handle.stop.load(Ordering::Acquire));
        assert_eq!(state.lock().unwrap().phase, RuntimePhase::Failed);
    }
}
