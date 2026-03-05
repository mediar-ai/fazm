use axum::{
    extract::Extension,
    http::{header, StatusCode},
    response::{IntoResponse, Json, Response},
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use rsa::pkcs8::DecodePrivateKey;
use rsa::traits::PublicKeyParts;
use rsa::RsaPrivateKey;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::sync::Arc;

use crate::auth::AuthDevice;
use crate::config::Config;

// ─── Subject Token ───────────────────────────────────────────────────────────

#[derive(Serialize, Deserialize)]
struct SubjectTokenClaims {
    sub: String,
    iss: String,
    aud: String,
    iat: i64,
    exp: i64,
}

/// POST /v1/vertex/subject-token
/// Signs a JWT for Workload Identity Federation (authed via shared secret)
pub async fn subject_token(
    Extension(config): Extension<Arc<Config>>,
    Extension(device): Extension<AuthDevice>,
) -> Result<Response, StatusCode> {
    let now = chrono::Utc::now().timestamp();
    let kid = generate_key_id(&config.vertex_sa_private_key_pem);

    let claims = SubjectTokenClaims {
        sub: device.device_id,
        iss: config.vertex_issuer.clone(),
        aud: "fazm-desktop-vertex".to_string(),
        iat: now,
        exp: now + 3600,
    };

    let mut header = Header::new(Algorithm::RS256);
    header.kid = Some(kid);
    header.typ = Some("JWT".to_string());

    let key = EncodingKey::from_rsa_pem(config.vertex_sa_private_key_pem.as_bytes())
        .map_err(|e| {
            tracing::error!("Failed to parse RSA key: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    let token = encode(&header, &claims, &key).map_err(|e| {
        tracing::error!("Failed to sign JWT: {}", e);
        StatusCode::INTERNAL_SERVER_ERROR
    })?;

    tracing::info!("Subject token generated for device={}", claims.sub);

    Ok((
        StatusCode::OK,
        [(header::CONTENT_TYPE, "text/plain")],
        token,
    )
        .into_response())
}

// ─── JWKS ────────────────────────────────────────────────────────────────────

#[derive(Serialize)]
struct JwksResponse {
    keys: Vec<JwkKey>,
}

#[derive(Serialize)]
struct JwkKey {
    kty: String,
    n: String,
    e: String,
    alg: String,
    #[serde(rename = "use")]
    use_: String,
    kid: String,
}

/// GET /v1/vertex/jwks
/// Returns the public key as JWKS for Google STS to verify our JWTs
pub async fn jwks(
    Extension(config): Extension<Arc<Config>>,
) -> Result<Response, StatusCode> {
    let private_key = RsaPrivateKey::from_pkcs8_pem(&config.vertex_sa_private_key_pem)
        .map_err(|e| {
            tracing::error!("Failed to parse RSA private key: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    let public_key = private_key.to_public_key();
    let n_bytes = public_key.n().to_bytes_be();
    let e_bytes = public_key.e().to_bytes_be();

    let kid = generate_key_id(&config.vertex_sa_private_key_pem);

    let jwks = JwksResponse {
        keys: vec![JwkKey {
            kty: "RSA".to_string(),
            n: URL_SAFE_NO_PAD.encode(&n_bytes),
            e: URL_SAFE_NO_PAD.encode(&e_bytes),
            alg: "RS256".to_string(),
            use_: "sig".to_string(),
            kid,
        }],
    };

    Ok((
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "application/json"),
            (header::CACHE_CONTROL, "public, max-age=3600"),
        ],
        Json(jwks),
    )
        .into_response())
}

// ─── OIDC Discovery ──────────────────────────────────────────────────────────

#[derive(Serialize)]
struct OidcConfig {
    issuer: String,
    jwks_uri: String,
    subject_types_supported: Vec<String>,
    id_token_signing_alg_values_supported: Vec<String>,
    response_types_supported: Vec<String>,
    claims_supported: Vec<String>,
}

/// GET /.well-known/openid-configuration
/// OIDC discovery for Google STS
pub async fn openid_configuration(
    Extension(config): Extension<Arc<Config>>,
) -> Response {
    let issuer = config.vertex_issuer.clone();
    let oidc = OidcConfig {
        jwks_uri: format!("{}/v1/vertex/jwks", issuer),
        issuer,
        subject_types_supported: vec!["public".to_string()],
        id_token_signing_alg_values_supported: vec!["RS256".to_string()],
        response_types_supported: vec!["id_token".to_string()],
        claims_supported: vec![
            "sub".to_string(),
            "aud".to_string(),
            "iss".to_string(),
            "iat".to_string(),
            "exp".to_string(),
        ],
    };

    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "application/json"),
            (header::CACHE_CONTROL, "public, max-age=3600"),
        ],
        Json(oidc),
    )
        .into_response()
}

// ─── Health ──────────────────────────────────────────────────────────────────

pub async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({"status": "ok"}))
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Generate a stable key ID from the private key (SHA256 of PEM, first 16 hex chars)
fn generate_key_id(private_key_pem: &str) -> String {
    let hash = Sha256::digest(private_key_pem.as_bytes());
    hex::encode(&hash[..8])
}
