use axum::{extract::Extension, http::StatusCode, Json};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::auth::AuthDevice;
use crate::config::Config;
use crate::firestore::get_access_token;

const TUNNEL_COLLECTION: &str = "tunnel_registry";

/// Firestore-backed tunnel registry. Wraps the shared Config needed for
/// Firestore REST calls. Survives Cloud Run instance restarts.
pub type TunnelRegistry = Arc<Config>;

pub fn new_tunnel_registry(config: Arc<Config>) -> TunnelRegistry {
    config
}

// ─── Firestore helpers ───────────────────────────────────────────────────────

fn tunnel_doc_url(project_id: &str, uid: &str) -> String {
    format!(
        "https://firestore.googleapis.com/v1/projects/{}/databases/(default)/documents/{}/{}",
        project_id,
        TUNNEL_COLLECTION,
        urlencoding::encode(uid)
    )
}

// --- Register ---

#[derive(Deserialize)]
pub struct RegisterRequest {
    pub tunnel_url: String,
}

#[derive(Serialize)]
pub struct RegisterResponse {
    pub ok: bool,
}

/// Desktop app registers its Cloudflare tunnel URL.
/// Called on startup and whenever the tunnel URL changes.
pub async fn register(
    Extension(auth): Extension<AuthDevice>,
    Extension(registry): Extension<TunnelRegistry>,
    Json(body): Json<RegisterRequest>,
) -> Result<Json<RegisterResponse>, StatusCode> {
    let uid = auth.firebase_uid.ok_or(StatusCode::UNAUTHORIZED)?;

    // Basic validation: must be an HTTPS URL
    if !body.tunnel_url.starts_with("https://") {
        return Err(StatusCode::BAD_REQUEST);
    }

    let token = get_access_token(&registry)
        .await
        .map_err(|e| {
            tracing::error!("Failed to get access token for tunnel register: {e}");
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    let now = chrono::Utc::now().to_rfc3339();
    let body_json = serde_json::json!({
        "fields": {
            "tunnel_url": { "stringValue": body.tunnel_url },
            "registered_at": { "timestampValue": now },
        }
    });

    let url = tunnel_doc_url(&registry.firebase_project_id, &uid);

    reqwest::Client::new()
        .patch(&url)
        .bearer_auth(&token)
        .json(&body_json)
        .send()
        .await
        .map_err(|e| {
            tracing::error!("Firestore PATCH failed for tunnel register: {e}");
            StatusCode::INTERNAL_SERVER_ERROR
        })?
        .error_for_status()
        .map_err(|e| {
            tracing::error!("Firestore PATCH error response for tunnel register: {e}");
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    tracing::info!("Tunnel registered for uid={}", uid);
    Ok(Json(RegisterResponse { ok: true }))
}

// --- Unregister ---

#[derive(Serialize)]
pub struct UnregisterResponse {
    pub ok: bool,
}

/// Desktop app unregisters when shutting down.
pub async fn unregister(
    Extension(auth): Extension<AuthDevice>,
    Extension(registry): Extension<TunnelRegistry>,
) -> Result<Json<UnregisterResponse>, StatusCode> {
    let uid = auth.firebase_uid.ok_or(StatusCode::UNAUTHORIZED)?;

    let token = get_access_token(&registry)
        .await
        .map_err(|e| {
            tracing::error!("Failed to get access token for tunnel unregister: {e}");
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    let url = tunnel_doc_url(&registry.firebase_project_id, &uid);

    let resp = reqwest::Client::new()
        .delete(&url)
        .bearer_auth(&token)
        .send()
        .await
        .map_err(|e| {
            tracing::error!("Firestore DELETE failed for tunnel unregister: {e}");
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    // 404 is fine — document already gone
    if resp.status() != reqwest::StatusCode::NOT_FOUND {
        resp.error_for_status().map_err(|e| {
            tracing::error!("Firestore DELETE error response for tunnel unregister: {e}");
            StatusCode::INTERNAL_SERVER_ERROR
        })?;
    }

    tracing::info!("Tunnel unregistered for uid={}", uid);
    Ok(Json(UnregisterResponse { ok: true }))
}

// --- Discover ---

#[derive(Serialize)]
pub struct DiscoverResponse {
    pub tunnel_url: Option<String>,
    pub online: bool,
}

/// Web/phone app discovers the tunnel URL for the authenticated user.
pub async fn discover(
    Extension(auth): Extension<AuthDevice>,
    Extension(registry): Extension<TunnelRegistry>,
) -> Result<Json<DiscoverResponse>, StatusCode> {
    let uid = auth.firebase_uid.ok_or(StatusCode::UNAUTHORIZED)?;

    let token = get_access_token(&registry)
        .await
        .map_err(|e| {
            tracing::error!("Failed to get access token for tunnel discover: {e}");
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    let url = tunnel_doc_url(&registry.firebase_project_id, &uid);

    let resp = reqwest::Client::new()
        .get(&url)
        .bearer_auth(&token)
        .send()
        .await
        .map_err(|e| {
            tracing::error!("Firestore GET failed for tunnel discover: {e}");
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    if resp.status() == reqwest::StatusCode::NOT_FOUND {
        return Ok(Json(DiscoverResponse {
            tunnel_url: None,
            online: false,
        }));
    }

    let doc: serde_json::Value = resp
        .error_for_status()
        .map_err(|e| {
            tracing::error!("Firestore GET error response for tunnel discover: {e}");
            StatusCode::INTERNAL_SERVER_ERROR
        })?
        .json()
        .await
        .map_err(|e| {
            tracing::error!("Firestore GET JSON parse error for tunnel discover: {e}");
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    let fields = match doc.get("fields") {
        Some(f) => f,
        None => {
            return Ok(Json(DiscoverResponse {
                tunnel_url: None,
                online: false,
            }));
        }
    };

    let tunnel_url = fields["tunnel_url"]["stringValue"]
        .as_str()
        .unwrap_or("")
        .to_string();

    let registered_at_str = fields["registered_at"]["timestampValue"]
        .as_str()
        .unwrap_or("");

    // Consider stale if older than 2 hours (tunnel probably died)
    let is_stale = if let Ok(ts) = chrono::DateTime::parse_from_rfc3339(registered_at_str) {
        let age = chrono::Utc::now().signed_duration_since(ts);
        age.num_seconds() > 7200
    } else {
        true // Can't parse timestamp → treat as stale
    };

    if tunnel_url.is_empty() || is_stale {
        Ok(Json(DiscoverResponse {
            tunnel_url: None,
            online: false,
        }))
    } else {
        Ok(Json(DiscoverResponse {
            tunnel_url: Some(tunnel_url),
            online: true,
        }))
    }
}
