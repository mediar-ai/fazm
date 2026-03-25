/// Minimal Firestore REST API client.
///
/// Gets access tokens from the GCE metadata server (available in Cloud Run,
/// GCE, GKE, etc.).  Falls back to a service-account JWT bearer exchange for
/// environments where the metadata server is unavailable (e.g. local dev).
use crate::config::Config;
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

const TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
const METADATA_TOKEN_URL: &str =
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token";
const FIRESTORE_SCOPE: &str = "https://www.googleapis.com/auth/datastore";
const COLLECTION: &str = "desktop_releases";

// ─── Token exchange ───────────────────────────────────────────────────────────

#[derive(Serialize)]
struct GoogleJwtClaims {
    iss: String,
    scope: String,
    aud: String,
    iat: i64,
    exp: i64,
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
}

/// Obtain a Google API access token.
///
/// 1. Try the GCE/Cloud Run metadata server (no credentials required).
/// 2. Fall back to JWT bearer exchange using `VERTEX_SA_PRIVATE_KEY_PEM` +
///    `GCP_SERVICE_ACCOUNT` (works outside GCP for local/CI use).
pub async fn get_access_token(
    config: &Arc<Config>,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()?;

    // 1. Metadata server (preferred in Cloud Run)
    let meta_result = client
        .get(format!("{METADATA_TOKEN_URL}?scopes={FIRESTORE_SCOPE}"))
        .header("Metadata-Flavor", "Google")
        .send()
        .await;

    if let Ok(resp) = meta_result {
        if resp.status().is_success() {
            let tr: TokenResponse = resp.json().await?;
            return Ok(tr.access_token);
        }
    }

    // 2. JWT bearer fallback
    let sa_email = &config.gcp_service_account;
    if sa_email.is_empty() {
        return Err("Metadata server unavailable and GCP_SERVICE_ACCOUNT is not set".into());
    }

    let now = chrono::Utc::now().timestamp();
    let claims = GoogleJwtClaims {
        iss: sa_email.clone(),
        scope: FIRESTORE_SCOPE.to_string(),
        aud: TOKEN_URL.to_string(),
        iat: now,
        exp: now + 3600,
    };

    let key = EncodingKey::from_rsa_pem(config.vertex_sa_private_key_pem.as_bytes())?;
    let mut header = Header::new(Algorithm::RS256);
    header.typ = Some("JWT".to_string());

    let jwt = encode(&header, &claims, &key)?;

    let resp: TokenResponse = reqwest::Client::new()
        .post(TOKEN_URL)
        .form(&[
            ("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"),
            ("assertion", &jwt),
        ])
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    Ok(resp.access_token)
}

// ─── Firestore document model ─────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReleaseDoc {
    pub tag: String,
    pub version: String,
    pub build: String,
    pub channel: String, // "staging" | "beta" | "stable"
    pub is_live: bool,
}

// ─── Firestore REST helpers ───────────────────────────────────────────────────

fn firestore_base(project_id: &str) -> String {
    format!(
        "https://firestore.googleapis.com/v1/projects/{}/databases/(default)/documents/{}",
        project_id, COLLECTION
    )
}

/// Convert a ReleaseDoc to Firestore REST document fields.
fn to_firestore_fields(doc: &ReleaseDoc) -> serde_json::Value {
    serde_json::json!({
        "fields": {
            "tag":     { "stringValue": doc.tag },
            "version": { "stringValue": doc.version },
            "build":   { "stringValue": doc.build },
            "channel": { "stringValue": doc.channel },
            "is_live": { "booleanValue": doc.is_live },
        }
    })
}

/// Extract a string field from a Firestore document.
fn str_field(fields: &serde_json::Value, key: &str) -> String {
    fields[key]["stringValue"]
        .as_str()
        .unwrap_or("")
        .to_string()
}

/// Parse a Firestore REST document into a ReleaseDoc.
fn from_firestore_doc(doc: &serde_json::Value) -> Option<ReleaseDoc> {
    let fields = doc.get("fields")?;
    Some(ReleaseDoc {
        tag: str_field(fields, "tag"),
        version: str_field(fields, "version"),
        build: str_field(fields, "build"),
        channel: str_field(fields, "channel"),
        is_live: fields["is_live"]["booleanValue"]
            .as_bool()
            .unwrap_or(false),
    })
}

// ─── Public CRUD operations ───────────────────────────────────────────────────

/// Create or overwrite a release document (doc ID = tag).
pub async fn upsert_release(
    config: &Arc<Config>,
    token: &str,
    doc: &ReleaseDoc,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let url = format!(
        "{}/{}",
        firestore_base(&config.firebase_project_id),
        urlencoding::encode(&doc.tag)
    );

    let body = to_firestore_fields(doc);

    reqwest::Client::new()
        .patch(&url)
        .bearer_auth(token)
        .json(&body)
        .send()
        .await?
        .error_for_status()?;

    Ok(())
}

/// Fetch a single release document by tag.
pub async fn get_release(
    config: &Arc<Config>,
    token: &str,
    tag: &str,
) -> Result<Option<ReleaseDoc>, Box<dyn std::error::Error + Send + Sync>> {
    let url = format!(
        "{}/{}",
        firestore_base(&config.firebase_project_id),
        urlencoding::encode(tag)
    );

    let resp = reqwest::Client::new()
        .get(&url)
        .bearer_auth(token)
        .send()
        .await?;

    if resp.status() == reqwest::StatusCode::NOT_FOUND {
        return Ok(None);
    }

    let doc: serde_json::Value = resp.error_for_status()?.json().await?;
    Ok(from_firestore_doc(&doc))
}

/// Deactivate all live releases on a given channel, except for the specified tag.
/// This ensures only one release is live per channel at any time.
pub async fn deactivate_channel(
    config: &Arc<Config>,
    token: &str,
    channel: &str,
    except_tag: &str,
) -> Result<u32, Box<dyn std::error::Error + Send + Sync>> {
    let url = format!(
        "https://firestore.googleapis.com/v1/projects/{}/databases/(default)/documents:runQuery",
        config.firebase_project_id
    );

    // Query for is_live == true AND channel == <channel>
    let query = serde_json::json!({
        "structuredQuery": {
            "from": [{ "collectionId": COLLECTION }],
            "where": {
                "compositeFilter": {
                    "op": "AND",
                    "filters": [
                        {
                            "fieldFilter": {
                                "field": { "fieldPath": "is_live" },
                                "op": "EQUAL",
                                "value": { "booleanValue": true }
                            }
                        },
                        {
                            "fieldFilter": {
                                "field": { "fieldPath": "channel" },
                                "op": "EQUAL",
                                "value": { "stringValue": channel }
                            }
                        }
                    ]
                }
            },
            "limit": 100
        }
    });

    let resp: serde_json::Value = reqwest::Client::new()
        .post(&url)
        .bearer_auth(token)
        .json(&query)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    let docs: Vec<ReleaseDoc> = resp
        .as_array()
        .unwrap_or(&vec![])
        .iter()
        .filter_map(|r| r.get("document").and_then(|d| from_firestore_doc(d)))
        .collect();

    let mut deactivated = 0u32;
    for doc in docs {
        if doc.tag == except_tag {
            continue;
        }
        let mut updated = doc;
        updated.is_live = false;
        upsert_release(config, token, &updated).await?;
        deactivated += 1;
    }

    Ok(deactivated)
}

/// List ALL release documents (live and inactive), ordered by descending build number.
pub async fn list_all_releases(
    config: &Arc<Config>,
    token: &str,
) -> Result<Vec<ReleaseDoc>, Box<dyn std::error::Error + Send + Sync>> {
    let url = format!(
        "https://firestore.googleapis.com/v1/projects/{}/databases/(default)/documents:runQuery",
        config.firebase_project_id
    );

    let query = serde_json::json!({
        "structuredQuery": {
            "from": [{ "collectionId": COLLECTION }],
            "limit": 100
        }
    });

    let resp: serde_json::Value = reqwest::Client::new()
        .post(&url)
        .bearer_auth(token)
        .json(&query)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    let mut docs: Vec<ReleaseDoc> = resp
        .as_array()
        .unwrap_or(&vec![])
        .iter()
        .filter_map(|r| r.get("document").and_then(|d| from_firestore_doc(d)))
        .collect();

    docs.sort_by(|a, b| {
        let ba: u64 = a.build.parse().unwrap_or(0);
        let bb: u64 = b.build.parse().unwrap_or(0);
        bb.cmp(&ba)
    });

    Ok(docs)
}

/// List all live release documents, ordered by descending build number.
pub async fn list_live_releases(
    config: &Arc<Config>,
    token: &str,
) -> Result<Vec<ReleaseDoc>, Box<dyn std::error::Error + Send + Sync>> {
    // Firestore REST: structured query to filter is_live == true
    let url = format!(
        "https://firestore.googleapis.com/v1/projects/{}/databases/(default)/documents:runQuery",
        config.firebase_project_id
    );

    let query = serde_json::json!({
        "structuredQuery": {
            "from": [{ "collectionId": COLLECTION }],
            "where": {
                "fieldFilter": {
                    "field": { "fieldPath": "is_live" },
                    "op": "EQUAL",
                    "value": { "booleanValue": true }
                }
            },
            "limit": 100
        }
    });

    let resp: serde_json::Value = reqwest::Client::new()
        .post(&url)
        .bearer_auth(token)
        .json(&query)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    let mut docs: Vec<ReleaseDoc> = resp
        .as_array()
        .unwrap_or(&vec![])
        .iter()
        .filter_map(|r| r.get("document").and_then(|d| from_firestore_doc(d)))
        .collect();

    // Sort by build number descending
    docs.sort_by(|a, b| {
        let ba: u64 = a.build.parse().unwrap_or(0);
        let bb: u64 = b.build.parse().unwrap_or(0);
        bb.cmp(&ba)
    });

    Ok(docs)
}
