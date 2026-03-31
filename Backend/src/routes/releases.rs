use axum::{
    extract::Extension,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Json},
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::config::Config;
use crate::firestore::{self, ReleaseDoc};

/// Validate the shared release secret from the Authorization header.
fn validate_release_secret(headers: &HeaderMap, config: &Config) -> Result<(), StatusCode> {
    if config.release_secret.is_empty() {
        tracing::error!("RELEASE_SECRET not configured on backend");
        return Err(StatusCode::INTERNAL_SERVER_ERROR);
    }

    let auth_header = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .ok_or(StatusCode::UNAUTHORIZED)?;

    if !auth_header.starts_with("Bearer ") {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let token = &auth_header[7..];
    if token != config.release_secret {
        return Err(StatusCode::UNAUTHORIZED);
    }

    Ok(())
}

// ─── Channel progression ──────────────────────────────────────────────────────

/// Returns the next channel in the promotion ladder.
fn next_channel(current: &str) -> Option<&'static str> {
    match current {
        "staging" => Some("beta"),
        "beta" => Some("stable"),
        _ => None, // already stable or unknown
    }
}

// ─── List ─────────────────────────────────────────────────────────────────────

/// GET /api/releases
/// Returns all releases with their channel and is_live status.
pub async fn list(Extension(config): Extension<Arc<Config>>) -> impl IntoResponse {
    let token = match firestore::get_access_token(&config).await {
        Ok(t) => t,
        Err(e) => {
            tracing::error!("Firestore auth failed: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": format!("auth failed: {}", e)})),
            )
                .into_response();
        }
    };

    match firestore::list_all_releases(&config, &token).await {
        Ok(releases) => {
            let items: Vec<serde_json::Value> = releases
                .iter()
                .map(|r| {
                    serde_json::json!({
                        "tag": r.tag,
                        "version": r.version,
                        "build": r.build,
                        "channel": r.channel,
                        "is_live": r.is_live,
                    })
                })
                .collect();
            (
                StatusCode::OK,
                Json(serde_json::json!({ "releases": items })),
            )
                .into_response()
        }
        Err(e) => {
            tracing::error!("Firestore query failed: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": format!("query failed: {}", e)})),
            )
                .into_response()
        }
    }
}

// ─── Register ─────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct RegisterRequest {
    pub tag: String,
    pub version: String,
    pub build: String,
}

#[derive(Serialize)]
pub struct RegisterResponse {
    pub success: bool,
    pub tag: String,
    pub channel: String,
}

/// POST /api/releases/register
/// Called by Codemagic after a successful build to register the release in Firestore.
/// New releases always start on the "staging" channel.
pub async fn register(
    headers: HeaderMap,
    Extension(config): Extension<Arc<Config>>,
    Json(req): Json<RegisterRequest>,
) -> impl IntoResponse {
    if let Err(status) = validate_release_secret(&headers, &config) {
        return (status, Json(serde_json::json!({"error": "unauthorized"}))).into_response();
    }
    let token = match firestore::get_access_token(&config).await {
        Ok(t) => t,
        Err(e) => {
            tracing::error!("Firestore auth failed: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": format!("auth failed: {}", e)})),
            )
                .into_response();
        }
    };

    let doc = ReleaseDoc {
        tag: req.tag.clone(),
        version: req.version.clone(),
        build: req.build.clone(),
        channel: "staging".to_string(),
        is_live: true,
    };

    if let Err(e) = firestore::upsert_release(&config, &token, &doc).await {
        tracing::error!("Firestore upsert failed: {}", e);
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": format!("write failed: {}", e)})),
        )
            .into_response();
    }

    // Deactivate previous live releases on the staging channel
    match firestore::deactivate_channel(&config, &token, "staging", &req.tag).await {
        Ok(n) if n > 0 => tracing::info!("Deactivated {} previous staging release(s)", n),
        Err(e) => tracing::warn!("Failed to deactivate old staging releases: {}", e),
        _ => {}
    }

    tracing::info!("Registered release {} as staging", req.tag);

    (
        StatusCode::OK,
        Json(RegisterResponse {
            success: true,
            tag: req.tag,
            channel: "staging".to_string(),
        }),
    )
        .into_response()
}

// ─── Promote ──────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct PromoteRequest {
    pub tag: String,
}

#[derive(Serialize)]
pub struct PromoteResponse {
    pub success: bool,
    pub tag: String,
    pub old_channel: String,
    pub new_channel: String,
}

/// PATCH /api/releases/promote
/// Advances the release one step up the channel ladder: staging → beta → stable.
pub async fn promote(
    headers: HeaderMap,
    Extension(config): Extension<Arc<Config>>,
    Json(req): Json<PromoteRequest>,
) -> impl IntoResponse {
    if let Err(status) = validate_release_secret(&headers, &config) {
        return (status, Json(serde_json::json!({"error": "unauthorized"}))).into_response();
    }
    let token = match firestore::get_access_token(&config).await {
        Ok(t) => t,
        Err(e) => {
            tracing::error!("Firestore auth failed: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": format!("auth failed: {}", e)})),
            )
                .into_response();
        }
    };

    let existing = match firestore::get_release(&config, &token, &req.tag).await {
        Ok(Some(doc)) => doc,
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                Json(serde_json::json!({"error": format!("release not found: {}", req.tag)})),
            )
                .into_response();
        }
        Err(e) => {
            tracing::error!("Firestore read failed: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": format!("read failed: {}", e)})),
            )
                .into_response();
        }
    };

    let old_channel = existing.channel.clone();
    let new_channel = match next_channel(&old_channel) {
        Some(c) => c,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": format!("already at terminal channel: {}", old_channel)})),
            )
                .into_response();
        }
    };

    let updated = ReleaseDoc {
        channel: new_channel.to_string(),
        ..existing
    };

    if let Err(e) = firestore::upsert_release(&config, &token, &updated).await {
        tracing::error!("Firestore upsert failed: {}", e);
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": format!("write failed: {}", e)})),
        )
            .into_response();
    }

    // Deactivate previous live releases on the target channel
    match firestore::deactivate_channel(&config, &token, new_channel, &req.tag).await {
        Ok(n) if n > 0 => tracing::info!("Deactivated {} previous {} release(s)", n, new_channel),
        Err(e) => tracing::warn!("Failed to deactivate old {} releases: {}", new_channel, e),
        _ => {}
    }

    tracing::info!(
        "Promoted {} from {} to {}",
        req.tag,
        old_channel,
        new_channel
    );

    (
        StatusCode::OK,
        Json(PromoteResponse {
            success: true,
            tag: req.tag,
            old_channel,
            new_channel: new_channel.to_string(),
        }),
    )
        .into_response()
}
