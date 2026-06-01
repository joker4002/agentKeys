use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::RwLock;

#[derive(Clone)]
pub struct TimedCache<T: Clone + Send + Sync + 'static> {
    inner: Arc<RwLock<Option<(Instant, T)>>>,
    ttl: Duration,
}

impl<T: Clone + Send + Sync + 'static> TimedCache<T> {
    pub fn new(ttl: Duration) -> Self {
        Self {
            inner: Arc::new(RwLock::new(None)),
            ttl,
        }
    }

    pub async fn get_or_refresh<F, Fut, E>(&self, refresh: F) -> Result<T, E>
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = Result<T, E>>,
    {
        {
            let read = self.inner.read().await;
            if let Some((stamped_at, value)) = read.as_ref() {
                if stamped_at.elapsed() < self.ttl {
                    return Ok(value.clone());
                }
            }
        }
        let fresh = refresh().await?;
        let mut write = self.inner.write().await;
        *write = Some((Instant::now(), fresh.clone()));
        Ok(fresh)
    }
}
