use axum::{extract::Extension, http::StatusCode, response::IntoResponse, Json};
use serde::Serialize;
use std::sync::Arc;

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
pub async fn get_keys(
    Extension(config): Extension<Arc<Config>>,
    Extension(_auth): Extension<AuthDevice>,
) -> Result<impl IntoResponse, StatusCode> {
    Ok(Json(KeysResponse {
        // Bundled Claude key discontinued — always empty. See doc comment above.
        anthropic_api_key: String::new(),
        deepgram_api_key: config.deepgram_api_key.clone(),
        gemini_api_key: config.gemini_api_key.clone(),
        elevenlabs_api_key: config.elevenlabs_api_key.clone(),
    }))
}
