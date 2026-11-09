use axum::{
    extract::Extension,
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use serde::Serialize;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::auth::AuthDevice;
use crate::config::Config;

#[derive(Serialize)]
pub struct KeysResponse {
    pub anthropic_api_key: String,
    pub deepgram_api_key: String,
    pub gemini_api_key: String,
    pub elevenlabs_api_key: String,
}

/// POST /v1/keys
/// Returns API keys to authenticated clients.
///
/// We no longer ship a bundled Anthropic/Claude key. `anthropic_api_key` is
/// always empty, which the desktop client already treats as its normal default:
/// run the bundled Gemini key (the default model is Gemini Flash) and, if the
/// user picks a Claude model, prompt them to connect their own Claude account
/// (personal OAuth). The Deepgram/Gemini/ElevenLabs keys are still served to
/// every authenticated client.
///
/// History: until 2026-06 this endpoint served a bundled Anthropic key to users
/// with an active/trialing Stripe subscription, capped at $10 lifetime spend
/// (enforced client-side). That bundled-Claude program was discontinued to stop
/// carrying Anthropic compute cost; the cost-cap machinery on the client is now
/// inert (it only ever incremented on bundled-key Claude queries, which can no
/// longer happen).
///
/// Abuse controls (added 2026-11-09 after the Gemini key was pulled from this
/// endpoint by a curl client and used for ~128k requests in an hour): every
/// fetch is logged with uid/ip/user-agent so a caller can be attributed, and
/// fetches are rate limited per UID and per IP. The limiter is in-memory, so
/// it is per Cloud Run instance; that is enough to stop a script from polling
/// for a freshly rotated key, which is what it is for.
pub async fn get_keys(
    Extension(config): Extension<Arc<Config>>,
    Extension(auth): Extension<AuthDevice>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, StatusCode> {
    let uid = auth.firebase_uid.as_deref().unwrap_or("unknown");
    let user_agent = headers
        .get("user-agent")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");

    let uid_ok = allow(&format!("uid:{}", uid), config.keys_rate_limit_per_uid);
    let ip_ok = allow(
        &format!("ip:{}", auth.client_ip),
        config.keys_rate_limit_per_ip,
    );
    if !uid_ok || !ip_ok {
        tracing::warn!(
            "Keys fetch RATE LIMITED uid={} ip={} device={} ua={:?}",
            uid,
            auth.client_ip,
            auth.device_id,
            user_agent
        );
        return Err(StatusCode::TOO_MANY_REQUESTS);
    }

    tracing::info!(
        "Keys served uid={} ip={} device={} ua={:?}",
        uid,
        auth.client_ip,
        auth.device_id,
        user_agent
    );

    Ok(Json(KeysResponse {
        // Bundled Claude key discontinued — always empty. See doc comment above.
        anthropic_api_key: String::new(),
        deepgram_api_key: config.deepgram_api_key.clone(),
        gemini_api_key: config.gemini_api_key.clone(),
        elevenlabs_api_key: config.elevenlabs_api_key.clone(),
    }))
}

const RATE_WINDOW: Duration = Duration::from_secs(3600);

/// Fixed-window counter: at most `limit` hits per `RATE_WINDOW` for `key`.
fn allow(key: &str, limit: u32) -> bool {
    static HITS: OnceLock<Mutex<HashMap<String, (Instant, u32)>>> = OnceLock::new();
    let mut hits = HITS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let now = Instant::now();
    // Keep the map from growing without bound.
    if hits.len() > 10_000 {
        hits.retain(|_, (start, _)| now.duration_since(*start) < RATE_WINDOW);
    }
    let entry = hits.entry(key.to_string()).or_insert((now, 0));
    if now.duration_since(entry.0) >= RATE_WINDOW {
        *entry = (now, 0);
    }
    entry.1 += 1;
    entry.1 <= limit
}

#[cfg(test)]
mod tests {
    use super::allow;

    #[test]
    fn allows_up_to_limit_then_blocks() {
        for _ in 0..3 {
            assert!(allow("test:limit", 3));
        }
        assert!(!allow("test:limit", 3));
        // Other keys are unaffected.
        assert!(allow("test:other", 3));
    }
}
