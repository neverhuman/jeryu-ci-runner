//! Reserve under a short lock; never hold it during boot or disk preparation.
use super::*;
use std::collections::{BTreeMap, VecDeque};
type Key = (String, u64);
#[derive(Default)]
pub(super) struct Registry {
    pub sessions: BTreeMap<Key, Arc<SessionHandle>>,
    pending: BTreeMap<Key, String>,
    order: VecDeque<Key>,
}
pub(super) struct Reservation {
    registry: Arc<Mutex<Registry>>,
    key: Key,
}
impl Reservation {
    pub fn acquire(
        registry: &Arc<Mutex<Registry>>,
        context: &jeryu_runner_protocol::wire::v2::SessionContext,
        owner_limit: usize,
    ) -> RunnerResult<Self> {
        let key = (context.session_id.clone(), context.generation);
        let mut store = registry
            .lock()
            .map_err(|_| failed("session_registry_failed"))?;
        let mut completed = vec![];
        let mut owner_count = 0;
        for (existing, handle) in &store.sessions {
            let state = handle
                .state
                .lock()
                .map_err(|_| failed("session_state_failed"))?;
            if live(state.phase) {
                if existing.0 == key.0 {
                    return Err(failed("session_generation_already_running"));
                }
                owner_count += usize::from(
                    state.phase != RuntimePhase::Stopping
                        && state.context.owner_id == context.owner_id,
                );
            } else {
                completed.push(existing.clone());
            }
        }
        if store.sessions.contains_key(&key)
            || store.pending.keys().any(|existing| existing.0 == key.0)
        {
            return Err(failed("session_generation_already_running"));
        }
        owner_count += store
            .pending
            .values()
            .filter(|owner| *owner == &context.owner_id)
            .count();
        if owner_count >= owner_limit || store.pending.len() >= 64 {
            return Err(failed("session_owner_capacity"));
        }
        // Keep bounded terminal/status history for recent completed runs. A new
        // boot does not evict every stopped snapshot before an API can fetch it.
        let evict = completed.len().saturating_sub(7);
        let victims: Vec<_> = store
            .order
            .iter()
            .filter(|key| completed.contains(key))
            .take(evict)
            .cloned()
            .collect();
        for victim in &victims {
            store.sessions.remove(victim);
        }
        store.order.retain(|key| !victims.contains(key));
        store.pending.insert(key.clone(), context.owner_id.clone());
        Ok(Self {
            registry: registry.clone(),
            key,
        })
    }
    pub fn complete(&self, handle: Arc<SessionHandle>) -> RunnerResult<()> {
        let mut store = self
            .registry
            .lock()
            .map_err(|_| failed("session_registry_failed"))?;
        if !store.pending.contains_key(&self.key) {
            return Err(failed("session_reservation_fenced"));
        }
        store.pending.remove(&self.key);
        store.order.push_back(self.key.clone());
        store.sessions.insert(self.key.clone(), handle);
        Ok(())
    }
}
impl Drop for Reservation {
    fn drop(&mut self) {
        if let Ok(mut store) = self.registry.lock() {
            store.pending.remove(&self.key);
        }
    }
}
pub(super) fn live(phase: RuntimePhase) -> bool {
    matches!(
        phase,
        RuntimePhase::Running
            | RuntimePhase::RebaseRequired
            | RuntimePhase::Stopping
            | RuntimePhase::Checkpointing
    )
}

#[cfg(test)]
mod tests;
