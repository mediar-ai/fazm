use axum::{Extension, Json};
use chrono::Utc;
use sha2::Sha256;
use std::sync::Arc;

use crate::auth::AuthDevice;
use crate::config::Config;

#[derive(serde::Deserialize)]
pub struct GetUploadUrlRequest {
    pub session_id: String,
    pub chunk_index: u32,
    pub start_timestamp: String,
    pub end_timestamp: String,
}

#[derive(serde::Serialize)]
pub struct GetUploadUrlResponse {
    pub upload_url: String,
    pub object_path: String,
}

/// Generate a GCS V4 signed URL for uploading a session recording chunk.
///
/// POST /api/session-recording/get-upload-url
///
/// The signed URL allows the client to PUT the chunk directly to GCS
/// without needing GCS credentials. Expires in 15 minutes.
pub async fn get_upload_url(
    Extension(config): Extension<Arc<Config>>,
    Extension(device): Extension<AuthDevice>,
    Json(body): Json<GetUploadUrlRequest>,
) -> Result<Json<GetUploadUrlResponse>, axum::http::StatusCode> {
    let bucket = &config.gcs_session_replay_bucket;
    let object_path = format!(
        "{}/{}/chunk_{:04}.mp4",
        device.device_id, body.session_id, body.chunk_index
    );

    tracing::info!(
        "Session recording upload: device={} session={} chunk={}",
        device.device_id,
        body.session_id,
        body.chunk_index
    );

    // Generate V4 signed URL using IAM signBlob API (no PEM key needed on Cloud Run)
    let signed_url = generate_v4_signed_url_iam(
        &config.gcp_service_account,
        bucket,
        &object_path,
        "PUT",
        900, // 15 minutes
    )
    .await
    .map_err(|e| {
        tracing::error!("Failed to generate signed URL: {}", e);
        axum::http::StatusCode::INTERNAL_SERVER_ERROR
    })?;

    Ok(Json(GetUploadUrlResponse {
        upload_url: signed_url,
        object_path,
    }))
}

/// Generate a GCS V4 signed URL using the IAM signBlob API.
///
/// Instead of signing locally with a PEM key, this calls the IAM API to sign
/// using Google-managed keys. This is more reliable on Cloud Run — no risk of
/// key corruption from base64 encoding in env vars.
async fn generate_v4_signed_url_iam(
    sa_email: &str,
    bucket: &str,
    object: &str,
    http_method: &str,
    expiration_secs: i64,
) -> Result<String, String> {
    let now = Utc::now();
    let datestamp = now.format("%Y%m%d").to_string();
    let datetime = now.format("%Y%m%dT%H%M%SZ").to_string();

    let credential_scope = format!("{}/auto/storage/goog4_request", datestamp);
    let credential = format!("{}/{}", sa_email, credential_scope);

    let host = "storage.googleapis.com";
    let resource = format!("/{}/{}", bucket, object);

    // Canonical query string (sorted)
    let mut query_params = vec![
        ("X-Goog-Algorithm", "GOOG4-RSA-SHA256".to_string()),
        ("X-Goog-Credential", credential.clone()),
        ("X-Goog-Date", datetime.clone()),
        ("X-Goog-Expires", expiration_secs.to_string()),
        ("X-Goog-SignedHeaders", "content-type;host".to_string()),
    ];
    query_params.sort_by(|a, b| a.0.cmp(&b.0));

    let canonical_query = query_params
        .iter()
        .map(|(k, v)| format!("{}={}", url_encode(k), url_encode(v)))
        .collect::<Vec<_>>()
        .join("&");

    // Canonical headers (sorted, lowercase)
    let canonical_headers = format!("content-type:video/mp4\nhost:{}\n", host);
    let signed_headers = "content-type;host";

    // Canonical request
    let canonical_request = format!(
        "{}\n{}\n{}\n{}\n{}\nUNSIGNED-PAYLOAD",
        http_method, resource, canonical_query, canonical_headers, signed_headers
    );

    // String to sign
    let canonical_request_hash = hex_sha256(canonical_request.as_bytes());
    let string_to_sign = format!(
        "GOOG4-RSA-SHA256\n{}\n{}\n{}",
        datetime, credential_scope, canonical_request_hash
    );

    // Sign via IAM signBlob API
    let signature_bytes = iam_sign_blob(sa_email, string_to_sign.as_bytes()).await?;
    let signature_hex = hex::encode(signature_bytes);

    Ok(format!(
        "https://{}/{}/{}?{}&X-Goog-Signature={}",
        host, bucket, object, canonical_query, signature_hex
    ))
}

/// Sign bytes using the IAM signBlob API.
///
/// On Cloud Run, the default service account has permission to call signBlob
/// on itself, so no additional credentials are needed.
async fn iam_sign_blob(sa_email: &str, data: &[u8]) -> Result<Vec<u8>, String> {
    use base64::Engine;

    // Get access token from metadata server (available on Cloud Run)
    let token = get_access_token().await?;

    let bytes_b64 = base64::engine::general_purpose::STANDARD.encode(data);
    let body = serde_json::json!({
        "bytesToSign": bytes_b64
    });

    let url = format!(
        "https://iam.googleapis.com/v1/projects/-/serviceAccounts/{}:signBlob",
        sa_email
    );

    let client = reqwest::Client::new();
    let resp = client
        .post(&url)
        .bearer_auth(&token)
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("IAM signBlob request failed: {}", e))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        return Err(format!("IAM signBlob returned {}: {}", status, text));
    }

    let resp_text = resp
        .text()
        .await
        .map_err(|e| format!("IAM signBlob response read: {}", e))?;

    tracing::debug!("IAM signBlob response: {}", &resp_text[..resp_text.len().min(500)]);

    #[derive(serde::Deserialize)]
    struct SignBlobResponse {
        #[serde(rename = "signedBytes")]
        signed_bytes: Option<String>,
        signature: Option<String>,
    }

    let sign_resp: SignBlobResponse = serde_json::from_str(&resp_text)
        .map_err(|e| format!("IAM signBlob response parse: {} body: {}", e, &resp_text[..resp_text.len().min(200)]))?;

    let sig_b64 = sign_resp.signature
        .or(sign_resp.signed_bytes)
        .ok_or_else(|| format!("IAM signBlob: no signature field in response: {}", &resp_text[..resp_text.len().min(200)]))?;

    base64::engine::general_purpose::STANDARD
        .decode(&sig_b64)
        .map_err(|e| format!("IAM signBlob base64 decode: {}", e))
}

/// Get an access token from the GCE metadata server (available on Cloud Run).
async fn get_access_token() -> Result<String, String> {
    let client = reqwest::Client::new();
    let resp = client
        .get("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token")
        .header("Metadata-Flavor", "Google")
        .send()
        .await
        .map_err(|e| format!("Metadata server token request: {}", e))?;

    if !resp.status().is_success() {
        return Err(format!("Metadata server returned {}", resp.status()));
    }

    #[derive(serde::Deserialize)]
    struct TokenResponse {
        access_token: String,
    }

    let token_resp: TokenResponse = resp
        .json()
        .await
        .map_err(|e| format!("Token response parse: {}", e))?;

    Ok(token_resp.access_token)
}

fn hex_sha256(data: &[u8]) -> String {
    use sha2::Digest;
    let hash = Sha256::digest(data);
    hex::encode(hash)
}

fn url_encode(s: &str) -> String {
    let mut result = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                result.push(b as char);
            }
            _ => {
                result.push_str(&format!("%{:02X}", b));
            }
        }
    }
    result
}
