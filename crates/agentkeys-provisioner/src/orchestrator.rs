use std::sync::{Arc, Mutex};
use std::time::Instant;

use crate::error::{ProvisionError, ProvisionResult};

#[derive(Debug, Clone)]
pub struct ActiveProvision {
    pub service: String,
    pub started_at: Instant,
}

#[derive(Debug, Clone)]
pub struct Provisioner {
    active: Arc<Mutex<Option<ActiveProvision>>>,
}

impl Default for Provisioner {
    fn default() -> Self {
        Self::new()
    }
}

impl Provisioner {
    pub fn new() -> Self {
        Self {
            active: Arc::new(Mutex::new(None)),
        }
    }

    pub fn try_claim(&self, service: &str) -> ProvisionResult<ProvisionGuard> {
        let mut guard = self.active_lock();
        if let Some(existing) = guard.as_ref() {
            return Err(ProvisionError::InProgress {
                active_service: existing.service.clone(),
            });
        }
        *guard = Some(ActiveProvision {
            service: service.to_string(),
            started_at: Instant::now(),
        });
        Ok(ProvisionGuard {
            active: Arc::clone(&self.active),
        })
    }

    pub fn is_active(&self) -> bool {
        self.active_lock().is_some()
    }

    pub fn active_service(&self) -> Option<String> {
        self.active_lock().as_ref().map(|a| a.service.clone())
    }

    fn active_lock(&self) -> std::sync::MutexGuard<'_, Option<ActiveProvision>> {
        match self.active.lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                tracing::warn!("provisioner mutex poisoned; resetting");
                let mut guard = poisoned.into_inner();
                *guard = None;
                guard
            }
        }
    }
}

#[derive(Debug)]
pub struct ProvisionGuard {
    active: Arc<Mutex<Option<ActiveProvision>>>,
}

impl Drop for ProvisionGuard {
    fn drop(&mut self) {
        if let Ok(mut guard) = self.active.lock() {
            *guard = None;
        } else if let Ok(mut guard) = self.active.clear_poison_and_lock() {
            *guard = None;
        }
    }
}

trait MutexExt<T> {
    fn clear_poison_and_lock(&self) -> std::sync::LockResult<std::sync::MutexGuard<'_, T>>;
}

impl<T> MutexExt<T> for Mutex<T> {
    fn clear_poison_and_lock(&self) -> std::sync::LockResult<std::sync::MutexGuard<'_, T>> {
        self.clear_poison();
        self.lock()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    #[test]
    fn concurrent_provision_rejected() {
        let p = Provisioner::new();
        let _guard = p.try_claim("openrouter").unwrap();
        let err = p.try_claim("brave").unwrap_err();
        match err {
            ProvisionError::InProgress { active_service } => {
                assert_eq!(active_service, "openrouter");
            }
            _ => panic!("expected InProgress, got {:?}", err),
        }
    }

    #[test]
    fn guard_releases_on_drop() {
        let p = Provisioner::new();
        {
            let _guard = p.try_claim("openrouter").unwrap();
            assert!(p.is_active());
        }
        assert!(!p.is_active());
        let _guard = p.try_claim("brave").unwrap();
        assert_eq!(p.active_service(), Some("brave".into()));
    }

    #[test]
    fn mutex_recovery_after_panic() {
        let p = Provisioner::new();
        let p_clone = p.clone();
        let handle = thread::spawn(move || {
            let _guard = p_clone.try_claim("openrouter").unwrap();
            panic!("simulated panic inside provision");
        });
        let _ = handle.join();
        assert!(
            !p.is_active(),
            "after panic + guard drop the mutex should be unclaimed"
        );
        let guard2 = p.try_claim("brave");
        assert!(guard2.is_ok(), "third call must proceed after panic recovery");
    }
}
