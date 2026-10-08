use super::*;
impl SessionHandle {
    pub fn snapshot(&self, actor: &str) -> RunnerResult<SessionSnapshot> {
        let state = self
            .state
            .lock()
            .map_err(|_| failed("session_state_failed"))?;
        if !state.can_view(actor) {
            return Err(failed("session_access_forbidden"));
        }
        Ok(state.snapshot())
    }
    pub fn grant(
        &self,
        actor: &str,
        subject: &str,
        grant: Option<AccessGrant>,
    ) -> RunnerResult<()> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| failed("session_state_failed"))?;
        if actor != state.context.owner_id || subject.is_empty() || subject.len() > 128 {
            return Err(failed("session_grant_forbidden"));
        }
        if subject == state.context.owner_id {
            return Err(failed("session_owner_grant_fixed"));
        }
        if let Some(grant) = grant {
            if state.grants.len() >= 64 && !state.grants.contains_key(subject) {
                return Err(failed("session_grant_capacity"));
            }
            state.grants.insert(subject.into(), grant);
        } else {
            state.grants.remove(subject);
        }
        if !state.can_control(subject)
            && state
                .controller
                .as_ref()
                .is_some_and(|controller| controller.actor == subject)
        {
            state.controller = None;
        }
        if !state.can_view(subject) {
            state.viewers.retain(|viewer| {
                if viewer.actor == subject {
                    viewer.revoked.store(true, Ordering::Release);
                    false
                } else {
                    true
                }
            });
        }
        Ok(())
    }
    pub fn acquire_control(&self, actor: &str, takeover: bool) -> RunnerResult<ControllerLease> {
        self.ensure_lease()?;
        self.state
            .lock()
            .map_err(|_| failed("session_state_failed"))?
            .acquire_control(actor, takeover)
    }
    pub fn control(&self, actor: &str, request: ControlRequest) -> RunnerResult<ControlAck> {
        self.ensure_lease()?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| failed("session_state_failed"))?;
        let (ack, command) = state.prepare_control(actor, &request)?;
        if let Some(command) = command
            && self.commands.try_send(command).is_err()
        {
            state.acknowledge(&request.request_id, false, "command_queue_full");
            return Ok(state
                .receipts
                .get(&request.request_id)
                .ok_or_else(|| failed("session_receipt_missing"))?
                .ack
                .clone());
        }
        Ok(ack)
    }
    pub fn acknowledgement(&self, actor: &str, request_id: &str) -> RunnerResult<ControlAck> {
        let state = self
            .state
            .lock()
            .map_err(|_| failed("session_state_failed"))?;
        if !state.can_view(actor) {
            return Err(failed("session_access_forbidden"));
        }
        state
            .receipts
            .get(request_id)
            .map(|receipt| receipt.ack.clone())
            .ok_or_else(|| failed("session_receipt_not_found"))
    }
    pub fn subscribe(&self, actor: &str, channel: &str) -> RunnerResult<Subscription> {
        self.subscribe_from(actor, channel, 0)
            .map(|(_, subscription)| subscription)
    }
    /// Capture the replay boundary and register live delivery under one lock.
    /// Producers cannot slip bytes between the retained cursor and registration.
    pub fn subscribe_from(
        &self,
        actor: &str,
        channel: &str,
        cursor: u64,
    ) -> RunnerResult<(SessionSnapshot, Subscription)> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| failed("session_state_failed"))?;
        if !state.can_view(actor) {
            return Err(failed("session_access_forbidden"));
        }
        if !state.channels.contains_key(channel) {
            return Err(failed("session_channel_unknown"));
        }
        if cursor > state.channels[channel].tail.cursor {
            return Err(failed("session_cursor_invalid"));
        }
        state
            .viewers
            .retain(|viewer| !viewer.revoked.load(Ordering::Acquire));
        if state.viewers.len() >= 32 {
            return Err(failed("session_viewer_capacity"));
        }
        let (send, receive) = mpsc::sync_channel(16);
        let revoked = Arc::new(AtomicBool::new(false));
        let gap = Arc::new(AtomicU64::new(0));
        let template = state.template(channel);
        state.viewers.push(Viewer {
            actor: actor.into(),
            channel: channel.into(),
            send,
            revoked: revoked.clone(),
            gap: gap.clone(),
        });
        let snapshot = state.snapshot();
        Ok((
            snapshot,
            Subscription {
                receive,
                revoked,
                gap,
                template,
            },
        ))
    }
    pub fn replay(
        &self,
        actor: &str,
        channel: &str,
        cursor: u64,
        limit: usize,
    ) -> RunnerResult<Vec<TerminalFrame>> {
        let state = self
            .state
            .lock()
            .map_err(|_| failed("session_state_failed"))?;
        if !state.can_view(actor) {
            return Err(failed("session_access_forbidden"));
        }
        if !(1..=128).contains(&limit) {
            return Err(failed("session_replay_limit_invalid"));
        }
        let channel_state = state
            .channels
            .get(channel)
            .ok_or_else(|| failed("session_channel_unknown"))?;
        if cursor > channel_state.tail.cursor {
            return Err(failed("session_cursor_invalid"));
        }
        let mut frames = vec![];
        if cursor.saturating_add(1) < channel_state.tail.earliest() {
            let mut gap = state.template(channel);
            gap.sequence = channel_state.tail.earliest();
            frames.push(gap);
        }
        frames.extend(channel_state.tail.after(cursor, limit));
        Ok(frames)
    }
    /// Request termination; the final snapshot reports actual cleanup success.
    pub fn stop(&self, actor: &str) -> RunnerResult<()> {
        let state = self
            .state
            .lock()
            .map_err(|_| failed("session_state_failed"))?;
        if !state.can_control(actor)
            || (actor != state.context.owner_id
                && !state.controller.as_ref().is_some_and(|controller| {
                    controller.actor == actor && controller.expires > std::time::Instant::now()
                }))
        {
            return Err(failed("session_control_forbidden"));
        }
        self.stop.store(true, Ordering::Release);
        Ok(())
    }
    fn ensure_lease(&self) -> RunnerResult<()> {
        if now_ms() >= u128::from(self.expires_at_unix_millis) {
            return Err(failed("session_lease_expired"));
        }
        Ok(())
    }
}
