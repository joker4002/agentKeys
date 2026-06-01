use crate::ps;
use axum::response::sse::{Event, KeepAlive, Sse};
use futures::stream::Stream;
use std::convert::Infallible;
use std::time::Duration;

pub async fn sse_handler() -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let stream = async_stream::stream! {
        let initial = ps::snapshot().await.unwrap_or_default();
        let mut last = initial.clone();
        let initial_payload = serde_json::json!({
            "type": "snapshot",
            "battles": initial,
        });
        yield Ok(Event::default().json_data(initial_payload).unwrap_or_default());

        let mut ticker = tokio::time::interval(Duration::from_secs(2));
        ticker.tick().await;
        loop {
            ticker.tick().await;
            let current = match ps::snapshot().await {
                Ok(c) => c,
                Err(_) => continue,
            };
            let added: Vec<&ps::Battle> = current
                .iter()
                .filter(|b| !last.iter().any(|p| p.pid == b.pid))
                .collect();
            let removed: Vec<&ps::Battle> = last
                .iter()
                .filter(|b| !current.iter().any(|p| p.pid == b.pid))
                .collect();
            if !added.is_empty() || !removed.is_empty() {
                let payload = serde_json::json!({
                    "type": "diff",
                    "added": added,
                    "removed": removed,
                    "current": current,
                });
                yield Ok(Event::default().json_data(payload).unwrap_or_default());
            }
            last = current;
        }
    };
    Sse::new(stream).keep_alive(KeepAlive::new().interval(Duration::from_secs(15)))
}
