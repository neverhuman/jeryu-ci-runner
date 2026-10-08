use super::{
    control::{CommandKind, Controller, Receipt},
    failed,
    replay::{Tail, Viewer},
};
use jeryu_runner_core::RunnerResult;
use jeryu_runner_protocol::{guest::GuestEvent, wire::v2::*};
use std::{
    collections::{BTreeMap, VecDeque},
    sync::{atomic::Ordering, mpsc::TrySendError},
};

pub use jeryu_runner_protocol::wire::v2::{
    ChannelSnapshot, RuntimePhase, SessionGrant as AccessGrant, SessionSnapshot,
};
#[derive(Clone, Debug)]
pub enum SessionEvent {
    Terminal(TerminalFrame),
    Control(ControlAck),
    Snapshot(SessionSnapshot),
}
pub(super) struct Channel {
    pub started: bool,
    pub exit: Option<Option<i32>>,
    pub guest_sequence: u64,
    pub tail: Tail,
}
pub(super) struct State {
    pub context: SessionContext,
    pub workspace: Option<WorkspaceReady>,
    pub checkpoint: Option<CheckpointReference>,
    pub phase: RuntimePhase,
    pub reason: Option<String>,
    pub grants: BTreeMap<String, AccessGrant>,
    pub channels: BTreeMap<String, Channel>,
    pub viewers: Vec<Viewer>,
    pub controller: Option<Controller>,
    pub controller_epoch: u64,
    pub frozen_request: Option<String>,
    pub receipts: BTreeMap<String, Receipt>,
    pub receipt_order: VecDeque<String>,
}

impl State {
    pub fn new(context: SessionContext) -> Self {
        Self {
            context,
            workspace: None,
            checkpoint: None,
            phase: RuntimePhase::Running,
            reason: None,
            grants: BTreeMap::new(),
            channels: ["agent", "shell"]
                .into_iter()
                .map(|id| {
                    (
                        id.into(),
                        Channel {
                            started: false,
                            exit: None,
                            guest_sequence: 0,
                            tail: Tail::new(),
                        },
                    )
                })
                .collect(),
            viewers: vec![],
            controller: None,
            controller_epoch: 0,
            frozen_request: None,
            receipts: BTreeMap::new(),
            receipt_order: VecDeque::new(),
        }
    }
    pub fn can_view(&self, actor: &str) -> bool {
        actor == self.context.owner_id || self.grants.contains_key(actor)
    }
    pub fn can_control(&self, actor: &str) -> bool {
        actor == self.context.owner_id || self.grants.get(actor) == Some(&AccessGrant::Controller)
    }
    pub fn snapshot(&self) -> SessionSnapshot {
        SessionSnapshot {
            context: self.context.clone(),
            workspace: self.workspace.clone(),
            checkpoint: self.checkpoint.clone(),
            phase: self.phase,
            reason: self.reason.clone(),
            channels: self
                .channels
                .iter()
                .map(|(id, channel)| ChannelSnapshot {
                    channel_id: id.clone(),
                    started: channel.started,
                    exited: channel.exit.is_some(),
                    exit_code: channel.exit.flatten(),
                    cursor: channel.tail.cursor,
                    earliest_cursor: channel.tail.earliest(),
                })
                .collect(),
        }
    }
    pub fn template(&self, channel: &str) -> TerminalFrame {
        TerminalFrame {
            protocol_version: PROTOCOL_VERSION.into(),
            message_type: "session-terminal".into(),
            session_id: self.context.session_id.clone(),
            generation: self.context.generation,
            run_id: self.context.run_id.clone(),
            channel_id: channel.into(),
            sequence: 1,
            gap: true,
            bytes: vec![],
        }
    }
    pub fn publish(&mut self, event: SessionEvent) {
        self.viewers.retain(|viewer| {
            if viewer.revoked.load(Ordering::Acquire) {
                return false;
            }
            if let SessionEvent::Terminal(frame) = &event
                && viewer.channel != frame.channel_id
            {
                return true;
            }
            match viewer.send.try_send(event.clone()) {
                Ok(()) => true,
                Err(TrySendError::Full(_)) => {
                    let cursor = self
                        .channels
                        .get(&viewer.channel)
                        .map_or(1, |channel| channel.tail.earliest());
                    viewer.gap.store(cursor, Ordering::Release);
                    true
                }
                Err(TrySendError::Disconnected(_)) => false,
            }
        });
    }
    pub fn finish(&mut self, phase: RuntimePhase, reason: Option<String>) {
        self.phase = phase;
        self.reason = reason;
        let pending: Vec<_> = self
            .receipts
            .iter()
            .filter(|(_, receipt)| receipt.ack.state == ControlState::Accepted)
            .map(|(id, _)| id.clone())
            .collect();
        for id in pending {
            self.acknowledge(&id, false, "session_stopped");
        }
        self.publish(SessionEvent::Snapshot(self.snapshot()));
    }
    pub fn ingest(&mut self, event: GuestEvent) -> RunnerResult<()> {
        match event {
            GuestEvent::Started { channel } => {
                if self.phase == RuntimePhase::RebaseRequired && channel != "shell" {
                    return Err(failed("guest_rebase_required"));
                }
                let channel = self
                    .channels
                    .get_mut(&channel)
                    .ok_or_else(|| failed("guest_channel_unknown"))?;
                if channel.started {
                    return Err(failed("guest_channel_already_started"));
                }
                channel.started = true;
                self.publish(SessionEvent::Snapshot(self.snapshot()));
            }
            GuestEvent::Output {
                channel,
                sequence,
                bytes,
            } => {
                let mut frame = self.template(&channel);
                frame.gap = false;
                frame.bytes = bytes;
                let state = self
                    .channels
                    .get_mut(&channel)
                    .ok_or_else(|| failed("guest_channel_unknown"))?;
                if !state.started || state.exit.is_some() || sequence != state.guest_sequence + 1 {
                    return Err(failed("guest_output_sequence_invalid"));
                }
                state.guest_sequence = sequence;
                let frame = state.tail.push(frame);
                self.publish(SessionEvent::Terminal(frame));
            }
            GuestEvent::Exited { channel, exit_code } => {
                let channel = self
                    .channels
                    .get_mut(&channel)
                    .ok_or_else(|| failed("guest_channel_unknown"))?;
                if !channel.started || channel.exit.is_some() {
                    return Err(failed("guest_exit_invalid"));
                }
                channel.exit = Some(exit_code);
                self.publish(SessionEvent::Snapshot(self.snapshot()));
            }
            GuestEvent::Ack {
                request_id,
                applied,
                reason,
            } => {
                self.acknowledge_guest(&request_id, applied, &reason, false)?;
            }
            GuestEvent::Stopped => {
                self.phase = RuntimePhase::Stopping;
                self.publish(SessionEvent::Snapshot(self.snapshot()));
            }
            GuestEvent::Frozen {
                request_id,
                workspace,
            } => {
                if self.phase != RuntimePhase::Checkpointing
                    || !self.receipts.values().any(|receipt| {
                        receipt.kind == CommandKind::Stop && receipt.guest_id == request_id
                    })
                {
                    return Err(failed("guest_freeze_ack_invalid"));
                }
                match (&self.workspace, &workspace) {
                    (Some(previous), Some(frozen))
                        if frozen.source_revision == self.context.source_revision
                            && frozen.main_revision == previous.main_revision => {}
                    (None, None) => (),
                    _ => return Err(failed("guest_freeze_workspace_invalid")),
                }
                self.workspace = workspace;
                self.frozen_request = Some(request_id);
            }
            GuestEvent::Error { .. } | GuestEvent::Ready { .. } => {
                return Err(failed("guest_session_failed"));
            }
        }
        Ok(())
    }
    pub fn acknowledge(&mut self, id: &str, applied: bool, reason: &str) {
        if let Some(receipt) = self.receipts.get_mut(id) {
            receipt.ack.state = if applied {
                ControlState::Applied
            } else {
                ControlState::Rejected
            };
            receipt.ack.reason = reason.into();
            let ack = receipt.ack.clone();
            self.publish(SessionEvent::Control(ack));
        }
        while self.receipt_order.len() > 1024 {
            let Some(id) = self.receipt_order.pop_front() else {
                break;
            };
            if self
                .receipts
                .get(&id)
                .is_some_and(|receipt| receipt.ack.state == ControlState::Accepted)
            {
                self.receipt_order.push_front(id);
                break;
            }
            self.receipts.remove(&id);
        }
    }
    pub fn acknowledge_guest(
        &mut self,
        guest_id: &str,
        applied: bool,
        reason: &str,
        trusted_stop: bool,
    ) -> RunnerResult<()> {
        let (id, receipt) = self
            .receipts
            .iter()
            .find(|(_, receipt)| receipt.guest_id == guest_id)
            .ok_or_else(|| failed("guest_ack_unknown"))?;
        if receipt.kind == CommandKind::Stop && !trusted_stop {
            return Err(failed("guest_stop_ack_denied"));
        }
        if receipt.ack.state != ControlState::Accepted {
            if (receipt.ack.state == ControlState::Applied) != applied
                || receipt.ack.reason != reason
            {
                return Err(failed("guest_ack_conflict"));
            }
            return Ok(());
        }
        let id = id.clone();
        self.acknowledge(&id, applied, reason);
        Ok(())
    }
    pub fn authorize_pending(&self, guest_id: &str) -> bool {
        let Some(receipt) = self
            .receipts
            .values()
            .find(|receipt| receipt.guest_id == guest_id)
        else {
            return false;
        };
        matches!(
            self.phase,
            RuntimePhase::Running | RuntimePhase::RebaseRequired
        ) && self.can_control(&receipt.actor)
            && receipt.ack.state == ControlState::Accepted
            && self.controller.as_ref().is_some_and(|controller| {
                controller.actor == receipt.actor
                    && controller.epoch == receipt.controller_epoch
                    && controller.expires > std::time::Instant::now()
            })
    }
}
