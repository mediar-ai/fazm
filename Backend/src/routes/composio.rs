use axum::{
    body::Bytes,
    extract::{Extension, Query},
    http::{HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::Arc;

use crate::auth::AuthDevice;
use crate::config::Config;

/// Base URL for Composio's v3 API
const COMPOSIO_API_BASE: &str = "https://backend.composio.dev/api/v3";

/// Base URL for Composio's MCP servers (different host path from /api/v3)
const COMPOSIO_MCP_BASE: &str = "https://backend.composio.dev/v3/mcp";

/// Per-toolkit configuration resolved at request time
struct ToolkitConfig {
    auth_config_id: String,
    mcp_server_id: String,
}

fn resolve_toolkit(toolkit: &str, config: &Config) -> Result<ToolkitConfig, (StatusCode, String)> {
    match toolkit.to_lowercase().as_str() {
        "gmail" => {
            if config.composio_gmail_auth_config_id.is_empty()
                || config.composio_gmail_mcp_server_id.is_empty()
            {
                return Err((
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Gmail toolkit not configured on backend".to_string(),
                ));
            }
            Ok(ToolkitConfig {
                auth_config_id: config.composio_gmail_auth_config_id.clone(),
                mcp_server_id: config.composio_gmail_mcp_server_id.clone(),
            })
        }
        other => Err((
            StatusCode::BAD_REQUEST,
            format!("Unsupported toolkit: {other}"),
        )),
    }
}

/// We prefix every Composio user_id with `fazm_` so we own the namespace and
/// can't collide with anything else the Composio account is used for.
fn composio_user_id(firebase_uid: &str) -> String {
    format!("fazm_{firebase_uid}")
}

fn require_api_key(config: &Config) -> Result<&str, (StatusCode, String)> {
    if config.composio_api_key.is_empty() {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            "Composio not configured on backend".to_string(),
        ));
    }
    Ok(&config.composio_api_key)
}

// ============================================================================
// POST /api/composio/connect
//
// Starts the OAuth flow for a toolkit. Returns a `redirect_url` the desktop
// app opens in the user's default browser; Composio hosts the OAuth handshake
// and lands the user back at our `callback_url` when done.
// ============================================================================

#[derive(Deserialize)]
pub struct ConnectRequest {
    pub toolkit: String,
    /// Where Composio should redirect after the user completes OAuth. The
    /// desktop app uses a `fazm://` deep link; falls back to backend `/api/composio/redirect`.
    pub callback_url: Option<String>,
}

#[derive(Serialize)]
pub struct ConnectResponse {
    pub redirect_url: String,
    pub connected_account_id: String,
    pub status: String,
}

pub async fn connect(
    Extension(config): Extension<Arc<Config>>,
    Extension(auth): Extension<AuthDevice>,
    Json(body): Json<ConnectRequest>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let api_key = require_api_key(&config)?;
    let toolkit_cfg = resolve_toolkit(&body.toolkit, &config)?;
    let firebase_uid = auth
        .firebase_uid
        .as_deref()
        .ok_or((StatusCode::UNAUTHORIZED, "Missing firebase uid".to_string()))?;
    let user_id = composio_user_id(firebase_uid);

    let callback_url = body
        .callback_url
        .unwrap_or_else(|| "fazm://integrations/composio/done".to_string());

    let payload = serde_json::json!({
        "auth_config_id": toolkit_cfg.auth_config_id,
        "user_id": user_id,
        "callback_url": callback_url,
    });

    let client = reqwest::Client::new();
    let resp = client
        .post(format!("{COMPOSIO_API_BASE}/connected_accounts/link"))
        .header("x-api-key", api_key)
        .header("content-type", "application/json")
        .json(&payload)
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Composio error: {e}")))?;

    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();
    if !status.is_success() {
        tracing::warn!(
            uid = %firebase_uid,
            toolkit = %body.toolkit,
            status = %status,
            body = %text,
            "Composio connect failed"
        );
        return Err((
            StatusCode::BAD_GATEWAY,
            format!("Composio connect failed: {status}"),
        ));
    }

    let parsed: Value = serde_json::from_str(&text)
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Composio invalid JSON: {e}")))?;

    // Composio returns the redirect URL in slightly different fields depending
    // on auth scheme. Try the common ones in order.
    let redirect_url = parsed
        .get("redirect_url")
        .and_then(|v| v.as_str())
        .or_else(|| parsed.get("redirect_uri").and_then(|v| v.as_str()))
        .or_else(|| {
            parsed
                .get("connectionStatus")
                .and_then(|s| s.get("redirectUrl"))
                .and_then(|v| v.as_str())
        })
        .unwrap_or("")
        .to_string();

    let connected_account_id = parsed
        .get("connected_account_id")
        .and_then(|v| v.as_str())
        .or_else(|| parsed.get("id").and_then(|v| v.as_str()))
        .unwrap_or("")
        .to_string();

    let conn_status = parsed
        .get("status")
        .and_then(|v| v.as_str())
        .unwrap_or("INITIATED")
        .to_string();

    if redirect_url.is_empty() {
        tracing::warn!(uid=%firebase_uid, body=%text, "Composio connect returned no redirect_url");
        return Err((
            StatusCode::BAD_GATEWAY,
            "Composio connect response missing redirect_url".to_string(),
        ));
    }

    Ok(Json(ConnectResponse {
        redirect_url,
        connected_account_id,
        status: conn_status,
    }))
}

// ============================================================================
// GET /api/composio/status?toolkit=gmail
//
// Lists connected accounts for the calling user. Used by the desktop app to
// show "Gmail (connected)" vs "Connect Gmail" in Settings.
// ============================================================================

#[derive(Deserialize)]
pub struct StatusQuery {
    pub toolkit: Option<String>,
}

#[derive(Serialize)]
pub struct StatusResponse {
    pub connected: bool,
    pub accounts: Vec<Value>,
}

pub async fn status(
    Extension(config): Extension<Arc<Config>>,
    Extension(auth): Extension<AuthDevice>,
    Query(query): Query<StatusQuery>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let api_key = require_api_key(&config)?;
    let firebase_uid = auth
        .firebase_uid
        .as_deref()
        .ok_or((StatusCode::UNAUTHORIZED, "Missing firebase uid".to_string()))?;
    let user_id = composio_user_id(firebase_uid);

    let mut url = format!("{COMPOSIO_API_BASE}/connected_accounts?user_ids={user_id}");
    if let Some(toolkit) = query.toolkit.as_deref() {
        url.push_str(&format!("&toolkit_slugs={}", toolkit));
    }

    let client = reqwest::Client::new();
    let resp = client
        .get(&url)
        .header("x-api-key", api_key)
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Composio error: {e}")))?;

    let status_code = resp.status();
    let text = resp.text().await.unwrap_or_default();
    if !status_code.is_success() {
        return Err((
            StatusCode::BAD_GATEWAY,
            format!("Composio status failed: {status_code}"),
        ));
    }

    let parsed: Value = serde_json::from_str(&text)
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Composio invalid JSON: {e}")))?;

    let accounts: Vec<Value> = parsed
        .get("items")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    // "connected" means at least one account exists in ACTIVE status. Composio
    // also uses INITIATED for half-finished OAuth flows; those don't count.
    let connected = accounts.iter().any(|a| {
        a.get("status")
            .and_then(|s| s.as_str())
            .map(|s| s.eq_ignore_ascii_case("ACTIVE"))
            .unwrap_or(false)
    });

    Ok(Json(StatusResponse {
        connected,
        accounts,
    }))
}

// ============================================================================
// POST /api/composio/disconnect
//
// Deletes the user's connected account for a toolkit.
// ============================================================================

#[derive(Deserialize)]
pub struct DisconnectRequest {
    pub connected_account_id: String,
}

pub async fn disconnect(
    Extension(config): Extension<Arc<Config>>,
    Extension(_auth): Extension<AuthDevice>,
    Json(body): Json<DisconnectRequest>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let api_key = require_api_key(&config)?;

    let client = reqwest::Client::new();
    let resp = client
        .delete(format!(
            "{COMPOSIO_API_BASE}/connected_accounts/{}",
            body.connected_account_id
        ))
        .header("x-api-key", api_key)
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Composio error: {e}")))?;

    let status_code = resp.status();
    if !status_code.is_success() {
        let text = resp.text().await.unwrap_or_default();
        return Err((
            StatusCode::BAD_GATEWAY,
            format!("Composio disconnect failed: {status_code} {text}"),
        ));
    }

    Ok(StatusCode::NO_CONTENT)
}

// ============================================================================
// POST /api/composio/mcp/:toolkit
//
// MCP proxy. The desktop ACP bridge registers this URL as an HTTP MCP server.
// We pass the request straight through to Composio with our API key + the
// caller's user_id, preserving the JSON-RPC / SSE response.
//
// This is the critical seam: it lets us keep the Composio API key on the
// backend while the agent still gets normal MCP semantics.
// ============================================================================

pub async fn mcp_proxy(
    Extension(config): Extension<Arc<Config>>,
    Extension(auth): Extension<AuthDevice>,
    axum::extract::Path(toolkit): axum::extract::Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Response, (StatusCode, String)> {
    let api_key = require_api_key(&config)?;
    let toolkit_cfg = resolve_toolkit(&toolkit, &config)?;
    let firebase_uid = auth
        .firebase_uid
        .as_deref()
        .ok_or((StatusCode::UNAUTHORIZED, "Missing firebase uid".to_string()))?;
    let user_id = composio_user_id(firebase_uid);

    // Composio MCP endpoint expects the user_id as a query param. The /mcp
    // suffix is added by Composio's 307 redirect on the bare server URL, but
    // we go straight to the redirected URL to skip the round-trip.
    let url = format!(
        "{COMPOSIO_MCP_BASE}/{}/mcp?user_id={}",
        toolkit_cfg.mcp_server_id, user_id
    );

    // Pass through accept header if present (text/event-stream vs application/json)
    let accept = headers
        .get("accept")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("application/json, text/event-stream")
        .to_string();

    // Pass through mcp-session-id header if present (MCP transport state)
    let session_id = headers
        .get("mcp-session-id")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());

    let client = reqwest::Client::new();
    let mut req = client
        .post(&url)
        .header("x-api-key", api_key)
        .header("content-type", "application/json")
        .header("accept", &accept)
        .body(body.to_vec());
    if let Some(sid) = session_id {
        req = req.header("mcp-session-id", sid);
    }

    let upstream = req
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Composio MCP error: {e}")))?;

    let status_code = upstream.status();
    let upstream_headers = upstream.headers().clone();
    let bytes = upstream
        .bytes()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Composio MCP read: {e}")))?;

    // Build axum response preserving content-type and mcp-session-id
    let mut response = Response::builder().status(
        axum::http::StatusCode::from_u16(status_code.as_u16())
            .unwrap_or(StatusCode::INTERNAL_SERVER_ERROR),
    );
    if let Some(ct) = upstream_headers.get("content-type") {
        if let Ok(v) = HeaderValue::from_bytes(ct.as_bytes()) {
            response = response.header("content-type", v);
        }
    }
    if let Some(sid) = upstream_headers.get("mcp-session-id") {
        if let Ok(v) = HeaderValue::from_bytes(sid.as_bytes()) {
            response = response.header("mcp-session-id", v);
        }
    }

    response
        .body(axum::body::Body::from(bytes))
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("Response build: {e}")))
}
