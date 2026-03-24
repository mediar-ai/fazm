use axum::{extract::Extension, http::StatusCode, Json};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::auth::AuthDevice;

/// In-memory store of active tunnel URLs, keyed by Firebase UID.
pub type TunnelRegistry = Arc<RwLock<HashMap<String, TunnelEntry>>>;

#[derive(Clone, Debug)]
pub struct TunnelEntry {
    pub tunnel_url: String,
    pub registered_at: std::time::Instant,
}

pub fn new_tunnel_registry() -> TunnelRegistry {
    Arc::new(RwLock::new(HashMap::new()))
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

    let mut reg = registry.write().await;
    reg.insert(
        uid.clone(),
        TunnelEntry {
            tunnel_url: body.tunnel_url,
            registered_at: std::time::Instant::now(),
        },
    );

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

    let mut reg = registry.write().await;
    reg.remove(&uid);

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

    let reg = registry.read().await;
    match reg.get(&uid) {
        Some(entry) => {
            // Consider stale if older than 2 hours (tunnel probably died)
            if entry.registered_at.elapsed().as_secs() > 7200 {
                Ok(Json(DiscoverResponse {
                    tunnel_url: None,
                    online: false,
                }))
            } else {
                Ok(Json(DiscoverResponse {
                    tunnel_url: Some(entry.tunnel_url.clone()),
                    online: true,
                }))
            }
        }
        None => Ok(Json(DiscoverResponse {
            tunnel_url: None,
            online: false,
        })),
    }
}
