use super::{
    failed,
    state::{RuntimePhase, SessionEvent, State},
};
use jeryu_runner_core::RunnerResult;
use jeryu_runner_protocol::{guest::GuestRequest, wire::v2::*};
use sha2::{Digest, Sha256};
use std::time::{Duration, Instant};

pub use jeryu_runner_protocol::wire::v2::ControllerLease;
pub(super) struct Controller {
    pub actor: String,
    pub epoch: u64,
    pub expires: Instant,
    pub sequence: u64,
    pub last_id: Option<String>,
}
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum CommandKind {
    Input,
    Resize,
    Interrupt,
    Stop,
}
pub(super) struct Receipt {
    pub fingerprint: Vec<u8>,
    pub guest_id: String,
    pub actor: String,
    pub controller_epoch: u64,
    pub kind: CommandKind,
    pub ack: ControlAck,
}

impl State {
    pub fn acquire_control(
        &mut self,
        actor: &str,
        takeover: bool,
    ) -> RunnerResult<ControllerLease> {
        if !self.can_control(actor) {
            return Err(failed("session_control_forbidden"));
        }
        if !matches!(
            self.phase,
            RuntimePhase::Running | RuntimePhase::RebaseRequired
        ) {
            return Err(failed("session_not_running"));
        }
        if takeover && actor != self.context.owner_id {
            return Err(failed("session_takeover_forbidden"));
        }
        if self.controller.as_ref().is_some_and(|controller| {
            controller.expires > Instant::now() && controller.actor != actor
        }) && !takeover
        {
            return Err(failed("session_control_busy"));
        }
        if !self.controller.as_ref().is_some_and(|controller| {
            controller.actor == actor && controller.expires > Instant::now()
        }) {
            self.controller_epoch += 1;
            self.controller = Some(Controller {
                actor: actor.into(),
                epoch: self.controller_epoch,
                expires: Instant::now(),
                sequence: 0,
                last_id: None,
            });
        }
        let controller = self
            .controller
            .as_mut()
            .ok_or_else(|| failed("session_controller_missing"))?;
        controller.expires = Instant::now() + Duration::from_secs(30);
        Ok(ControllerLease {
            controller_id: actor.into(),
            epoch: controller.epoch,
            expires_in_seconds: 30,
            next_sequence: controller.sequence + 1,
        })
    }
    pub fn prepare_control(
        &mut self,
        actor: &str,
        request: &ControlRequest,
    ) -> RunnerResult<(ControlAck, Option<GuestRequest>)> {
        request
            .validate()
            .map_err(|_| failed("session_control_invalid"))?;
        if request.context != self.context {
            return Err(failed("session_control_fenced"));
        }
        if request.controller_id != actor || !self.can_control(actor) {
            return Err(failed("session_control_forbidden"));
        }
        let controller = self
            .controller
            .as_ref()
            .ok_or_else(|| failed("session_control_lease_required"))?;
        if controller.actor != actor
            || controller.epoch != request.control_lease_epoch
            || controller.expires <= Instant::now()
        {
            return Err(failed("session_control_lease_expired"));
        }
        let fingerprint = Sha256::digest(
            serde_json::to_vec(request).map_err(|_| failed("session_control_invalid"))?,
        )
        .to_vec();
        if let Some(receipt) = self.receipts.get(&request.request_id) {
            if receipt.fingerprint != fingerprint {
                return Err(failed("session_control_replay_conflict"));
            }
            return Ok((receipt.ack.clone(), None));
        }
        if request.control_sequence != controller.sequence + 1 {
            return Err(failed("session_control_replay"));
        }
        if !matches!(
            self.phase,
            RuntimePhase::Running | RuntimePhase::RebaseRequired
        ) {
            return Err(failed("session_not_running"));
        }
        if !self.channels.contains_key(&request.channel_id) {
            return Err(failed("session_channel_unknown"));
        }
        if self
            .receipts
            .values()
            .filter(|receipt| receipt.ack.state == ControlState::Accepted)
            .count()
            >= 64
        {
            return Err(failed("session_control_capacity"));
        }
        let guest_id: String = fingerprint
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        let (kind, command) = match &request.command {
            ControlCommand::Prompt { .. } => {
                return Err(failed("session_structured_prompt_unsupported"));
            }
            ControlCommand::Input { bytes } => (
                CommandKind::Input,
                GuestRequest::Input {
                    channel: request.channel_id.clone(),
                    request_id: guest_id.clone(),
                    bytes: bytes.clone(),
                },
            ),
            ControlCommand::Resize { rows, cols } => (
                CommandKind::Resize,
                GuestRequest::Resize {
                    channel: request.channel_id.clone(),
                    request_id: guest_id.clone(),
                    rows: *rows,
                    cols: *cols,
                },
            ),
            ControlCommand::Interrupt => (
                CommandKind::Interrupt,
                GuestRequest::Interrupt {
                    channel: request.channel_id.clone(),
                    request_id: guest_id.clone(),
                },
            ),
            ControlCommand::Stop => (
                CommandKind::Stop,
                GuestRequest::Stop {
                    request_id: guest_id.clone(),
                },
            ),
        };
        let ack = ControlAck {
            protocol_version: PROTOCOL_VERSION.into(),
            message_type: "session-control-ack".into(),
            context: self.context.clone(),
            request_id: request.request_id.clone(),
            channel_id: request.channel_id.clone(),
            state: ControlState::Accepted,
            reason: "accepted".into(),
        };
        let controller = self
            .controller
            .as_mut()
            .ok_or_else(|| failed("session_controller_missing"))?;
        controller.sequence = request.control_sequence;
        controller.last_id = Some(request.request_id.clone());
        self.receipt_order.push_back(request.request_id.clone());
        self.receipts.insert(
            request.request_id.clone(),
            Receipt {
                fingerprint,
                guest_id,
                actor: actor.into(),
                controller_epoch: request.control_lease_epoch,
                kind,
                ack: ack.clone(),
            },
        );
        self.publish(SessionEvent::Control(ack.clone()));
        Ok((ack, Some(command)))
    }
}
