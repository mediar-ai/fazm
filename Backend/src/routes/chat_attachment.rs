use axum::{Extension, Json};
use std::sync::Arc;

use crate::auth::AuthDevice;
use crate::config::Config;
use crate::routes::session_recording::generate_v4_signed_url_iam;

#[derive(serde::Deserialize)]
pub struct GetAttachmentUploadUrlRequest {
    pub message_id: String,
    pub filename: String,
    pub content_type: String,
}

#[derive(serde::Serialize)]
pub struct GetAttachmentUploadUrlResponse {
    /// Signed PUT URL — client uploads bytes here with the matching Content-Type.
    pub upload_url: String,
    /// Signed GET URL (7-day expiry) — stored on the message so the in-app
    /// bubble and the founder-chat agent can fetch the file without GCS creds.
    pub download_url: String,
    pub object_path: String,
    pub bucket: String,
}

/// Generate signed upload + download URLs for a founder-chat attachment.
///
/// POST /api/founder-chat/get-attachment-upload-url
///
/// Reuses the session-recording GCS bucket + the IAM-signBlob signing path
/// (no Firebase Storage needed). The object is scoped to the authenticated
/// user's Firebase UID, so one user can't write to another's path.
pub async fn get_attachment_upload_url(
    Extension(config): Extension<Arc<Config>>,
    Extension(device): Extension<AuthDevice>,
    Json(body): Json<GetAttachmentUploadUrlRequest>,
) -> Result<Json<GetAttachmentUploadUrlResponse>, axum::http::StatusCode> {
    let uid = device
        .firebase_uid
        .clone()
        .ok_or(axum::http::StatusCode::UNAUTHORIZED)?;

    let bucket = config.gcs_session_replay_bucket.clone();
    if bucket.is_empty() {
        tracing::error!("chat-attachment upload: GCS bucket not configured");
        return Err(axum::http::StatusCode::INTERNAL_SERVER_ERROR);
    }

    let safe_name = sanitize_filename(&body.filename);
    let safe_msg = sanitize_filename(&body.message_id);
    let object_path = format!("founder-chat-attachments/{}/{}/{}", uid, safe_msg, safe_name);

    tracing::info!(
        "chat-attachment upload: uid={} object={} type={}",
        uid,
        object_path,
        body.content_type
    );

    // Signed PUT (15 min) — client must send this exact Content-Type.
    let upload_url = generate_v4_signed_url_iam(
        &config.gcp_service_account,
        &bucket,
        &object_path,
        "PUT",
        900,
        Some(&body.content_type),
    )
    .await
    .map_err(|e| {
        tracing::error!("chat-attachment signed PUT url failed: {}", e);
        axum::http::StatusCode::INTERNAL_SERVER_ERROR
    })?;

    // Signed GET (7 days = V4 max) — stored on the message for later reads.
    let download_url = generate_v4_signed_url_iam(
        &config.gcp_service_account,
        &bucket,
        &object_path,
        "GET",
        604_800,
        None,
    )
    .await
    .map_err(|e| {
        tracing::error!("chat-attachment signed GET url failed: {}", e);
        axum::http::StatusCode::INTERNAL_SERVER_ERROR
    })?;

    Ok(Json(GetAttachmentUploadUrlResponse {
        upload_url,
        download_url,
        object_path,
        bucket,
    }))
}

/// Strip any path components and keep only safe filename characters so a
/// crafted filename/message_id can't escape the user's prefix.
fn sanitize_filename(name: &str) -> String {
    let base = name
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(name);
    let cleaned: String = base
        .chars()
        .map(|c| if c.is_alphanumeric() || matches!(c, '.' | '-' | '_') { c } else { '_' })
        .collect();
    if cleaned.is_empty() {
        "file".to_string()
    } else {
        cleaned
    }
}
