use axum::{Extension, Json};
use chrono::Utc;
use sha2::Sha256;
use std::sync::Arc;

use crate::auth::AuthDevice;
use crate::config::Config;

const POSTHOG_PROJECT_ID: &str = "331630";
const POSTHOG_FLAG_ID: &str = "606686";
const POSTHOG_API_URL: &str = "https://us.posthog.com/api";

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

// ── Session recording auto-enrollment ──

#[derive(serde::Deserialize)]
pub struct AutoEnrollRequest {
    pub update_channel: String,
}

#[derive(serde::Serialize)]
pub struct AutoEnrollResponse {
    pub enrolled: bool,
    pub reason: String,
}

/// Auto-enroll a device for session recording if:
/// 1. They are on the "beta" channel
/// 2. Fewer than N users are already enrolled
///
/// POST /api/session-recording/auto-enroll
pub async fn auto_enroll(
    Extension(config): Extension<Arc<Config>>,
    Extension(device): Extension<AuthDevice>,
    Json(body): Json<AutoEnrollRequest>,
) -> Json<AutoEnrollResponse> {
    let device_id = &device.device_id;

    // Only auto-enroll beta channel users
    if body.update_channel != "beta" {
        tracing::info!(
            "Session recording auto-enroll: skipping {} (channel={})",
            device_id, body.update_channel
        );
        return Json(AutoEnrollResponse {
            enrolled: false,
            reason: format!("channel '{}' is not eligible", body.update_channel),
        });
    }

    let api_key = &config.posthog_personal_api_key;
    if api_key.is_empty() {
        tracing::warn!("Session recording auto-enroll: POSTHOG_PERSONAL_API_KEY not set");
        return Json(AutoEnrollResponse {
            enrolled: false,
            reason: "server not configured for auto-enrollment".to_string(),
        });
    }

    let max_enroll = config.session_recording_max_auto_enroll;

    // Fetch current enrolled IDs from PostHog feature flag
    let current_ids = match get_enrolled_ids(api_key).await {
        Ok(ids) => ids,
        Err(e) => {
            tracing::error!("Failed to fetch enrolled IDs: {}", e);
            return Json(AutoEnrollResponse {
                enrolled: false,
                reason: "failed to check enrollment status".to_string(),
            });
        }
    };

    // Already enrolled?
    if current_ids.contains(&device_id.to_string()) {
        return Json(AutoEnrollResponse {
            enrolled: true,
            reason: "already enrolled".to_string(),
        });
    }

    // Cap reached?
    if current_ids.len() >= max_enroll {
        tracing::info!(
            "Session recording auto-enroll: cap reached ({}/{}), skipping {}",
            current_ids.len(), max_enroll, device_id
        );
        return Json(AutoEnrollResponse {
            enrolled: false,
            reason: format!("enrollment cap reached ({}/{})", current_ids.len(), max_enroll),
        });
    }

    // Add this device
    let mut new_ids = current_ids;
    new_ids.push(device_id.to_string());

    if let Err(e) = update_enrolled_ids(api_key, &new_ids).await {
        tracing::error!("Failed to update enrolled IDs: {}", e);
        return Json(AutoEnrollResponse {
            enrolled: false,
            reason: "failed to update enrollment".to_string(),
        });
    }

    tracing::info!(
        "Session recording auto-enroll: enrolled {} ({}/{})",
        device_id, new_ids.len(), max_enroll
    );

    Json(AutoEnrollResponse {
        enrolled: true,
        reason: format!("enrolled ({}/{})", new_ids.len(), max_enroll),
    })
}

/// Fetch the list of device IDs currently enrolled in the session-recording-enabled flag.
async fn get_enrolled_ids(api_key: &str) -> Result<Vec<String>, String> {
    let url = format!(
        "{}/projects/{}/feature_flags/{}/",
        POSTHOG_API_URL, POSTHOG_PROJECT_ID, POSTHOG_FLAG_ID
    );

    let client = reqwest::Client::new();
    let resp = client
        .get(&url)
        .header("Authorization", format!("Bearer {}", api_key))
        .send()
        .await
        .map_err(|e| format!("PostHog flag fetch: {}", e))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        return Err(format!("PostHog flag fetch returned {}: {}", status, text));
    }

    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| format!("PostHog flag parse: {}", e))?;

    let mut ids = Vec::new();
    if let Some(groups) = body["filters"]["groups"].as_array() {
        if let Some(group) = groups.first() {
            if let Some(props) = group["properties"].as_array() {
                for prop in props {
                    if prop["key"].as_str() == Some("distinct_id") {
                        if let Some(values) = prop["value"].as_array() {
                            for v in values {
                                if let Some(s) = v.as_str() {
                                    if s != "test-device-placeholder" {
                                        ids.push(s.to_string());
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Ok(ids)
}

/// Update the PostHog feature flag with a new list of enrolled device IDs.
async fn update_enrolled_ids(api_key: &str, ids: &[String]) -> Result<(), String> {
    let url = format!(
        "{}/projects/{}/feature_flags/{}/",
        POSTHOG_API_URL, POSTHOG_PROJECT_ID, POSTHOG_FLAG_ID
    );

    let ids_json: Vec<serde_json::Value> = ids.iter().map(|id| serde_json::json!(id)).collect();

    let payload = serde_json::json!({
        "filters": {
            "groups": [{
                "properties": [{
                    "key": "distinct_id",
                    "value": ids_json,
                    "operator": "exact",
                    "type": "person"
                }],
                "rollout_percentage": 100
            }]
        }
    });

    let client = reqwest::Client::new();
    let resp = client
        .patch(&url)
        .header("Authorization", format!("Bearer {}", api_key))
        .json(&payload)
        .send()
        .await
        .map_err(|e| format!("PostHog flag update: {}", e))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        return Err(format!("PostHog flag update returned {}: {}", status, text));
    }

    Ok(())
}
