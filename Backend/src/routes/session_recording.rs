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

    // Generate V4 signed URL for PUT
    let signed_url = generate_v4_signed_url(
        &config.vertex_sa_private_key_pem,
        &config.gcp_service_account,
        bucket,
        &object_path,
        "PUT",
        900, // 15 minutes
    )
    .map_err(|e| {
        tracing::error!("Failed to generate signed URL: {}", e);
        axum::http::StatusCode::INTERNAL_SERVER_ERROR
    })?;

    Ok(Json(GetUploadUrlResponse {
        upload_url: signed_url,
        object_path,
    }))
}

/// Generate a GCS V4 signed URL.
///
/// Uses the service account's RSA private key to create a self-signed URL
/// that grants temporary access to upload an object to GCS.
fn generate_v4_signed_url(
    sa_private_key_pem: &str,
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

    let host = format!("storage.googleapis.com");
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

    // Sign with RSA-SHA256
    let signature = rsa_sha256_sign(sa_private_key_pem, string_to_sign.as_bytes())?;
    let signature_hex = hex::encode(signature);

    let signed_url = format!(
        "https://{}/{}?{}&X-Goog-Signature={}",
        host,
        format!("{}/{}", bucket, object),
        canonical_query,
        signature_hex
    );

    Ok(signed_url)
}

fn hex_sha256(data: &[u8]) -> String {
    use sha2::Digest;
    let hash = Sha256::digest(data);
    hex::encode(hash)
}

fn rsa_sha256_sign(private_key_pem: &str, data: &[u8]) -> Result<Vec<u8>, String> {
    use rsa::pkcs1v15::SigningKey;
    use rsa::pkcs8::DecodePrivateKey;
    use rsa::signature::{SignatureEncoding, Signer};
    use rsa::RsaPrivateKey;

    let private_key =
        RsaPrivateKey::from_pkcs8_pem(private_key_pem).map_err(|e| format!("RSA key parse: {}", e))?;

    let signing_key = SigningKey::<Sha256>::new(private_key);
    let signature = signing_key.sign(data);

    Ok(signature.to_vec())
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
