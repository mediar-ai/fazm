use axum::{
    extract::{Extension, Path},
    http::StatusCode,
    response::{Html, IntoResponse},
    Json,
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::auth::AuthDevice;
use crate::config::Config;
use crate::firestore;

const REFERRAL_COLLECTION: &str = "referrals";
const REFERRAL_TRACKING_COLLECTION: &str = "referral_tracking";
const REQUIRED_MESSAGES: i64 = 5;

// ---------- Generate Referral Code ----------

#[derive(Serialize)]
pub struct GenerateResponse {
    pub code: String,
    pub referral_url: String,
}

/// POST /api/referral/generate
/// Generates (or returns existing) referral code for the authenticated user.
pub async fn generate(
    Extension(config): Extension<Arc<Config>>,
    Extension(auth): Extension<AuthDevice>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let firebase_uid = auth.firebase_uid.unwrap_or_default();
    if firebase_uid.is_empty() {
        return Err((StatusCode::UNAUTHORIZED, "No Firebase UID".to_string()));
    }

    let token = firestore::get_access_token(&config)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("Token error: {e}")))?;

    // Check if user already has a referral code
    if let Some(existing) = find_referral_by_uid(&config, &token, &firebase_uid).await? {
        let backend_base = &config.vertex_issuer;
        return Ok(Json(GenerateResponse {
            referral_url: format!("{backend_base}/r/{}", existing),
            code: existing,
        }));
    }

    // Generate a unique 8-char alphanumeric code
    let code = generate_code();

    // Store in Firestore: referrals/{code}
    let now = chrono::Utc::now().timestamp();
    let doc_url = format!(
        "https://firestore.googleapis.com/v1/projects/{}/databases/(default)/documents/{}/{}",
        config.firebase_project_id, REFERRAL_COLLECTION, code
    );

    let body = serde_json::json!({
        "fields": {
            "referrer_uid": { "stringValue": firebase_uid },
            "code": { "stringValue": code },
            "created_at": { "integerValue": now.to_string() },
            "completed_referrals": { "integerValue": "0" },
            "reward_months_granted": { "integerValue": "0" }
        }
    });

    let client = reqwest::Client::new();
    let resp = client
        .patch(&doc_url)
        .bearer_auth(&token)
        .json(&body)
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Firestore error: {e}")))?;

    if !resp.status().is_success() {
        let err = resp.text().await.unwrap_or_default();
        return Err((StatusCode::BAD_GATEWAY, format!("Firestore write error: {err}")));
    }

    tracing::info!(referrer = %firebase_uid, code = %code, "Referral code generated");

    let backend_base = &config.vertex_issuer;
    Ok(Json(GenerateResponse {
        referral_url: format!("{backend_base}/r/{code}"),
        code,
    }))
}

// ---------- Referral Status ----------

#[derive(Serialize)]
pub struct ReferralStatus {
    pub code: String,
    pub referral_url: String,
    pub referred_count: i64,
    pub completed_count: i64,
    pub reward_months: i64,
}

/// GET /api/referral/status
/// Returns the referral stats for the authenticated user.
pub async fn status(
    Extension(config): Extension<Arc<Config>>,
    Extension(auth): Extension<AuthDevice>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let firebase_uid = auth.firebase_uid.unwrap_or_default();
    if firebase_uid.is_empty() {
        return Err((StatusCode::UNAUTHORIZED, "No Firebase UID".to_string()));
    }

    let token = firestore::get_access_token(&config)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("Token error: {e}")))?;

    let code = match find_referral_by_uid(&config, &token, &firebase_uid).await? {
        Some(c) => c,
        None => {
            return Ok(Json(ReferralStatus {
                code: String::new(),
                referral_url: String::new(),
                referred_count: 0,
                completed_count: 0,
                reward_months: 0,
            }));
        }
    };

    // Get the referral doc
    let doc_url = format!(
        "https://firestore.googleapis.com/v1/projects/{}/databases/(default)/documents/{}/{}",
        config.firebase_project_id, REFERRAL_COLLECTION, code
    );

    let client = reqwest::Client::new();
    let resp = client
        .get(&doc_url)
        .bearer_auth(&token)
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Firestore error: {e}")))?;

    let doc: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Parse error: {e}")))?;

    let fields = &doc["fields"];
    let completed = int_field(fields, "completed_referrals");
    let reward_months = int_field(fields, "reward_months_granted");

    // Count referred users via tracking collection query
    let referred_count = count_referred_users(&config, &token, &code).await.unwrap_or(0);

    let backend_base = &config.vertex_issuer;
    Ok(Json(ReferralStatus {
        referral_url: format!("{backend_base}/r/{code}"),
        code,
        referred_count,
        completed_count: completed,
        reward_months,
    }))
}

// ---------- Track Signup ----------

#[derive(Deserialize)]
pub struct TrackSignupRequest {
    pub referral_code: String,
}

/// POST /api/referral/track-signup
/// Called when a new user signs up with a referral code.
pub async fn track_signup(
    Extension(config): Extension<Arc<Config>>,
    Extension(auth): Extension<AuthDevice>,
    Json(body): Json<TrackSignupRequest>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let firebase_uid = auth.firebase_uid.unwrap_or_default();
    if firebase_uid.is_empty() {
        return Err((StatusCode::UNAUTHORIZED, "No Firebase UID".to_string()));
    }

    let code = body.referral_code.trim().to_uppercase();
    if code.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "Empty referral code".to_string()));
    }

    let token = firestore::get_access_token(&config)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("Token error: {e}")))?;

    // Verify the referral code exists
    let doc_url = format!(
        "https://firestore.googleapis.com/v1/projects/{}/databases/(default)/documents/{}/{}",
        config.firebase_project_id, REFERRAL_COLLECTION, code
    );

    let client = reqwest::Client::new();
    let resp = client
        .get(&doc_url)
        .bearer_auth(&token)
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Firestore error: {e}")))?;

    if resp.status() == reqwest::StatusCode::NOT_FOUND {
        return Err((StatusCode::NOT_FOUND, "Invalid referral code".to_string()));
    }
    if !resp.status().is_success() {
        return Err((StatusCode::BAD_GATEWAY, "Firestore read error".to_string()));
    }

    let referral_doc: serde_json::Value = resp.json().await.unwrap_or_default();
    let referrer_uid = referral_doc["fields"]["referrer_uid"]["stringValue"]
        .as_str()
        .unwrap_or_default();

    // Don't allow self-referral
    if referrer_uid == firebase_uid {
        return Err((StatusCode::BAD_REQUEST, "Cannot refer yourself".to_string()));
    }

    // Create tracking doc: referral_tracking/{referred_uid}
    let tracking_url = format!(
        "https://firestore.googleapis.com/v1/projects/{}/databases/(default)/documents/{}/{}",
        config.firebase_project_id, REFERRAL_TRACKING_COLLECTION, firebase_uid
    );

    let now = chrono::Utc::now().timestamp();
    let tracking_body = serde_json::json!({
        "fields": {
            "referral_code": { "stringValue": code },
            "referrer_uid": { "stringValue": referrer_uid },
            "referred_uid": { "stringValue": firebase_uid },
            "signed_up_at": { "integerValue": now.to_string() },
            "floating_bar_messages": { "integerValue": "0" },
            "completed": { "booleanValue": false },
            "reward_granted": { "booleanValue": false }
        }
    });

    client
        .patch(&tracking_url)
        .bearer_auth(&token)
        .json(&tracking_body)
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Firestore write error: {e}")))?;

    tracing::info!(
        referred = %firebase_uid,
        referrer = %referrer_uid,
        code = %code,
        "Referral signup tracked"
    );

    Ok(StatusCode::OK)
}

// ---------- Validate (increment messages + grant reward) ----------

#[derive(Serialize)]
pub struct ValidateResponse {
    pub message_count: i64,
    pub completed: bool,
    pub reward_granted: bool,
}

/// POST /api/referral/validate
/// Called by the client after each floating_bar_query_sent to increment the counter.
/// When count reaches 5, marks referral complete and grants referrer a free month.
pub async fn validate(
    Extension(config): Extension<Arc<Config>>,
    Extension(auth): Extension<AuthDevice>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let firebase_uid = auth.firebase_uid.unwrap_or_default();
    if firebase_uid.is_empty() {
        return Err((StatusCode::UNAUTHORIZED, "No Firebase UID".to_string()));
    }

    let token = firestore::get_access_token(&config)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("Token error: {e}")))?;

    // Get tracking doc for this user
    let tracking_url = format!(
        "https://firestore.googleapis.com/v1/projects/{}/databases/(default)/documents/{}/{}",
        config.firebase_project_id, REFERRAL_TRACKING_COLLECTION, firebase_uid
    );

    let client = reqwest::Client::new();
    let resp = client
        .get(&tracking_url)
        .bearer_auth(&token)
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Firestore error: {e}")))?;

    if resp.status() == reqwest::StatusCode::NOT_FOUND {
        // User wasn't referred — nothing to track
        return Ok(Json(ValidateResponse {
            message_count: 0,
            completed: false,
            reward_granted: false,
        }));
    }

    let doc: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Parse error: {e}")))?;

    let fields = &doc["fields"];
    let current_count = int_field(fields, "floating_bar_messages");
    let already_completed = fields["completed"]["booleanValue"].as_bool().unwrap_or(false);
    let already_rewarded = fields["reward_granted"]["booleanValue"].as_bool().unwrap_or(false);

    if already_completed {
        return Ok(Json(ValidateResponse {
            message_count: current_count,
            completed: true,
            reward_granted: already_rewarded,
        }));
    }

    // Increment message count
    let new_count = current_count + 1;
    let completed = new_count >= REQUIRED_MESSAGES;

    let mut update_fields = serde_json::json!({
        "fields": {
            "floating_bar_messages": { "integerValue": new_count.to_string() },
            "completed": { "booleanValue": completed }
        }
    });

    let mut reward_granted = false;

    if completed {
        // Grant referrer a free month
        let referral_code = fields["referral_code"]["stringValue"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        let referrer_uid = fields["referrer_uid"]["stringValue"]
            .as_str()
            .unwrap_or_default()
            .to_string();

        if !referrer_uid.is_empty() {
            // Grant free month to referrer via Stripe coupon
            if let Err(e) = grant_free_month(&client, &config, &referrer_uid).await {
                tracing::error!(referrer = %referrer_uid, error = %e, "Failed to grant referral reward");
            } else {
                reward_granted = true;
                tracing::info!(
                    referrer = %referrer_uid,
                    referred = %firebase_uid,
                    "Referral reward granted — 1 free month"
                );
            }

            // Update referral doc: increment completed_referrals + reward_months_granted
            if !referral_code.is_empty() {
                let _ =
                    increment_referral_stats(&client, &config, &token, &referral_code, reward_granted)
                        .await;
            }
        }

        update_fields["fields"]["reward_granted"] = serde_json::json!({ "booleanValue": reward_granted });
    }

    // Update tracking doc
    client
        .patch(&tracking_url)
        .bearer_auth(&token)
        .json(&update_fields)
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Firestore update error: {e}")))?;

    Ok(Json(ValidateResponse {
        message_count: new_count,
        completed,
        reward_granted,
    }))
}

// ---------- Landing Page ----------

/// GET /r/:code
/// Public landing page for referral links. Shows email form to send download link.
pub async fn landing_page(
    Extension(config): Extension<Arc<Config>>,
    Path(code): Path<String>,
) -> impl IntoResponse {
    let code = code.trim().to_uppercase();
    let backend_base = &config.vertex_issuer;

    let html = format!(
        r#"<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Get Fazm — AI Desktop Assistant</title>
    <style>
        body {{ background: #0a0a0f; color: #E5E5E5; font-family: -apple-system, system-ui, sans-serif; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }}
        .container {{ text-align: center; max-width: 420px; padding: 40px 24px; }}
        h1 {{ color: #8B5CF6; font-size: 28px; margin-bottom: 8px; }}
        .subtitle {{ color: #94a3b8; font-size: 16px; margin-bottom: 32px; line-height: 1.5; }}
        .code {{ background: #1e1e3a; border: 1px solid #333; border-radius: 8px; padding: 12px 20px; font-family: monospace; font-size: 18px; color: #8B5CF6; letter-spacing: 2px; margin-bottom: 24px; display: inline-block; }}
        .form-group {{ margin-bottom: 16px; }}
        .email-input {{ width: 100%; padding: 14px 16px; border-radius: 12px; border: 1px solid rgba(255,255,255,0.1); background: rgba(255,255,255,0.05); color: white; font-size: 16px; outline: none; box-sizing: border-box; }}
        .email-input:focus {{ border-color: rgba(139,92,246,0.5); box-shadow: 0 0 0 2px rgba(139,92,246,0.15); }}
        .email-input::placeholder {{ color: rgba(255,255,255,0.3); }}
        .btn {{ display: block; width: 100%; padding: 14px; background: linear-gradient(135deg, #8B5CF6, #7C3AED); color: white; border: none; border-radius: 12px; font-size: 16px; font-weight: 600; cursor: pointer; }}
        .btn:hover {{ opacity: 0.9; }}
        .btn:disabled {{ opacity: 0.5; cursor: not-allowed; }}
        .success {{ display: none; text-align: center; padding: 16px 0; }}
        .success .check {{ width: 48px; height: 48px; margin: 0 auto 16px; border-radius: 50%; background: rgba(34,197,94,0.1); border: 1px solid rgba(34,197,94,0.2); display: flex; align-items: center; justify-content: center; }}
        .success .check svg {{ width: 24px; height: 24px; color: #4ade80; }}
        .success h3 {{ color: white; font-size: 20px; margin-bottom: 8px; }}
        .success p {{ color: #94a3b8; font-size: 14px; }}
        .error {{ color: #f87171; font-size: 14px; margin-top: 8px; display: none; }}
        .open-link {{ color: #64748b; font-size: 14px; margin-top: 20px; }}
        .open-link a {{ color: #8B5CF6; text-decoration: none; }}
        .open-link a:hover {{ text-decoration: underline; }}
    </style>
</head>
<body>
    <div class="container">
        <h1>You've been invited to Fazm</h1>
        <p class="subtitle">AI agent for your Mac — controls your browser, writes code, handles documents, all from your voice.</p>
        <div class="code">{code}</div>

        <div id="form-section">
            <p style="color: #94a3b8; font-size: 14px; margin-bottom: 16px;">Enter your email and we'll send you the download link.</p>
            <form id="download-form" onsubmit="handleSubmit(event)">
                <div class="form-group">
                    <input type="email" id="email" class="email-input" placeholder="you@email.com" required autofocus />
                </div>
                <button type="submit" class="btn" id="submit-btn">Get download link</button>
                <p class="error" id="error-msg">Something went wrong. Try again.</p>
            </form>
        </div>

        <div class="success" id="success-section">
            <div class="check">
                <svg fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" /></svg>
            </div>
            <h3>Check your email!</h3>
            <p>Download link sent. Check your inbox.</p>
        </div>

        <p class="open-link">Already have Fazm? <a href="fazm://referral/{code}">Open in app</a></p>
    </div>
    <script>
        async function handleSubmit(e) {{
            e.preventDefault();
            var email = document.getElementById('email').value;
            var btn = document.getElementById('submit-btn');
            var errEl = document.getElementById('error-msg');
            btn.disabled = true;
            btn.textContent = 'Sending...';
            errEl.style.display = 'none';
            try {{
                var res = await fetch('{backend_base}/api/referral/send-download', {{
                    method: 'POST',
                    headers: {{ 'Content-Type': 'application/json' }},
                    body: JSON.stringify({{ email: email, referral_code: '{code}' }})
                }});
                if (res.ok) {{
                    document.getElementById('form-section').style.display = 'none';
                    document.getElementById('success-section').style.display = 'block';
                }} else {{
                    errEl.style.display = 'block';
                    btn.disabled = false;
                    btn.textContent = 'Get download link';
                }}
            }} catch(err) {{
                errEl.style.display = 'block';
                btn.disabled = false;
                btn.textContent = 'Get download link';
            }}
        }}
    </script>
</body>
</html>"#,
        code = code,
        backend_base = backend_base
    );

    Html(html)
}

// ---------- Send Download Email ----------

#[derive(Deserialize)]
pub struct SendDownloadRequest {
    pub email: String,
    pub referral_code: String,
}

/// POST /api/referral/send-download
/// Sends a download email with the referral code to the given email address.
/// Public endpoint (no auth required — used from the referral landing page).
pub async fn send_download(
    Extension(config): Extension<Arc<Config>>,
    Json(body): Json<SendDownloadRequest>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let resend_key = &config.resend_api_key;
    if resend_key.is_empty() {
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            "Email service not configured".to_string(),
        ));
    }

    let email = body.email.trim().to_lowercase();
    if email.is_empty() || !email.contains('@') {
        return Err((StatusCode::BAD_REQUEST, "Invalid email".to_string()));
    }

    let code = body.referral_code.trim().to_uppercase();
    let download_url = format!(
        "https://fazm.ai/download?email={}&utm_source=referral&utm_campaign={}",
        urlencoding::encode(&email),
        urlencoding::encode(&code)
    );
    let backend_base = &config.vertex_issuer;
    let open_in_app_url = format!("fazm://referral/{code}");

    let email_html = format!(
        r#"<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"></head>
<body style="margin:0;padding:0;background-color:#0a0a0f;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background-color:#0a0a0f;padding:40px 20px;">
    <tr><td align="center">
      <table width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;">
        <tr><td style="padding-bottom:32px;">
          <span style="font-size:24px;font-weight:bold;color:#ffffff;">fazm</span><span style="font-size:24px;font-weight:bold;color:#8B5CF6;">.</span>
        </td></tr>
        <tr><td style="padding-bottom:16px;">
          <h1 style="margin:0;font-size:28px;font-weight:bold;color:#ffffff;line-height:1.3;">Your download is ready</h1>
        </td></tr>
        <tr><td style="padding-bottom:32px;color:#94a3b8;font-size:16px;line-height:1.6;">
          A friend invited you to try Fazm, the AI agent that controls your Mac with voice commands. Click below to download and get started.
        </td></tr>
        <tr><td style="padding-bottom:24px;">
          <a href="{download_url}" style="display:inline-block;padding:14px 28px;background:linear-gradient(135deg,#8B5CF6,#7C3AED);color:#ffffff;font-size:16px;font-weight:600;text-decoration:none;border-radius:12px;">
            Download Fazm for macOS
          </a>
        </td></tr>
        <tr><td style="padding-bottom:16px;color:#64748b;font-size:14px;line-height:1.5;">
          Your referral code: <strong style="color:#8B5CF6;">{code}</strong>
        </td></tr>
        <tr><td style="padding-bottom:40px;color:#64748b;font-size:14px;line-height:1.5;">
          After installing, <a href="{open_in_app_url}" style="color:#8B5CF6;text-decoration:none;">click here to apply your referral</a> so your friend gets 1 month of Pro free.
        </td></tr>
        <tr><td style="border-top:1px solid #1e293b;padding-top:24px;color:#475569;font-size:13px;line-height:1.5;">
          <a href="https://fazm.ai" style="color:#8B5CF6;text-decoration:none;">fazm.ai</a>, the AI computer agent for macOS.
        </td></tr>
      </table>
    </td></tr>
  </table>
</body>
</html>"#
    );

    let client = reqwest::Client::new();
    let resp = client
        .post("https://api.resend.com/emails")
        .header("Authorization", format!("Bearer {resend_key}"))
        .json(&serde_json::json!({
            "from": "Matt from Fazm <matt@fazm.ai>",
            "to": email,
            "subject": "Your Fazm download link",
            "html": email_html
        }))
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Email send error: {e}")))?;

    if !resp.status().is_success() {
        let err = resp.text().await.unwrap_or_default();
        tracing::error!(error = %err, "Resend email failed");
        return Err((StatusCode::BAD_GATEWAY, "Failed to send email".to_string()));
    }

    tracing::info!(email = %body.email, code = %code, "Referral download email sent");
    Ok(StatusCode::OK)
}

// ---------- Helpers ----------

/// Generate an 8-char uppercase alphanumeric code
fn generate_code() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();

    let chars: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no 0/O/1/I confusion
    let mut code = String::with_capacity(8);
    let mut n = seed;
    for _ in 0..8 {
        code.push(chars[(n % chars.len() as u128) as usize] as char);
        n = n.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    }
    code
}

/// Find a referral code owned by the given Firebase UID
async fn find_referral_by_uid(
    config: &Arc<Config>,
    token: &str,
    firebase_uid: &str,
) -> Result<Option<String>, (StatusCode, String)> {
    let query_url = format!(
        "https://firestore.googleapis.com/v1/projects/{}/databases/(default)/documents:runQuery",
        config.firebase_project_id
    );

    let query = serde_json::json!({
        "structuredQuery": {
            "from": [{ "collectionId": REFERRAL_COLLECTION }],
            "where": {
                "fieldFilter": {
                    "field": { "fieldPath": "referrer_uid" },
                    "op": "EQUAL",
                    "value": { "stringValue": firebase_uid }
                }
            },
            "limit": 1
        }
    });

    let client = reqwest::Client::new();
    let resp = client
        .post(&query_url)
        .bearer_auth(token)
        .json(&query)
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Firestore query error: {e}")))?;

    let results: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Parse error: {e}")))?;

    let code = results
        .as_array()
        .and_then(|arr| arr.first())
        .and_then(|r| r.get("document"))
        .and_then(|d| d["fields"]["code"]["stringValue"].as_str())
        .map(|s| s.to_string());

    Ok(code)
}

/// Count referred users for a given referral code
async fn count_referred_users(
    config: &Arc<Config>,
    token: &str,
    code: &str,
) -> Result<i64, String> {
    let query_url = format!(
        "https://firestore.googleapis.com/v1/projects/{}/databases/(default)/documents:runQuery",
        config.firebase_project_id
    );

    let query = serde_json::json!({
        "structuredQuery": {
            "from": [{ "collectionId": REFERRAL_TRACKING_COLLECTION }],
            "where": {
                "fieldFilter": {
                    "field": { "fieldPath": "referral_code" },
                    "op": "EQUAL",
                    "value": { "stringValue": code }
                }
            },
            "limit": 100
        }
    });

    let client = reqwest::Client::new();
    let resp = client
        .post(&query_url)
        .bearer_auth(token)
        .json(&query)
        .send()
        .await
        .map_err(|e| format!("Firestore query error: {e}"))?;

    let results: serde_json::Value = resp.json().await.map_err(|e| format!("Parse error: {e}"))?;

    let count = results
        .as_array()
        .map(|arr| arr.iter().filter(|r| r.get("document").is_some()).count() as i64)
        .unwrap_or(0);

    Ok(count)
}

/// Grant a free month to the referrer by adding a credit to their Stripe customer balance.
/// Uses customer balance (not coupons) because the subscription uses flexible billing mode.
/// The credit ($10) is automatically applied to the next invoice by Stripe.
async fn grant_free_month(
    client: &reqwest::Client,
    config: &Config,
    referrer_uid: &str,
) -> Result<(), String> {
    let stripe_secret = &config.stripe_secret_key;
    if stripe_secret.is_empty() {
        return Err("Stripe not configured".to_string());
    }

    // Find the referrer's Stripe customer
    let resp = client
        .get("https://api.stripe.com/v1/customers/search")
        .bearer_auth(stripe_secret)
        .query(&[(
            "query",
            &format!("metadata['firebase_uid']:'{referrer_uid}'"),
        )])
        .send()
        .await
        .map_err(|e| format!("Stripe search error: {e}"))?;

    let body: serde_json::Value = resp.json().await.map_err(|e| format!("Parse error: {e}"))?;

    let customer_id = body["data"]
        .as_array()
        .and_then(|arr| arr.first())
        .and_then(|c| c["id"].as_str())
        .ok_or_else(|| "Referrer has no Stripe customer".to_string())?;

    // Add a $10 credit to the customer balance (negative amount = credit).
    // $10 == one month at the $9.99 base plan. This MUST stay in sync with the client's
    // ReferralService.creditPerReferralUSD (Desktop), which multiplies reward_months by it
    // to show the earned credit; if they drift, the paywall/settings display lies.
    // Stripe automatically applies customer balance credits to the next invoice.
    let resp = client
        .post(format!(
            "https://api.stripe.com/v1/customers/{customer_id}/balance_transactions"
        ))
        .bearer_auth(stripe_secret)
        .form(&[
            ("amount", "-1000"), // -$10.00 (negative = credit)
            ("currency", "usd"),
            ("description", "Referral reward: 1 month free"),
        ])
        .send()
        .await
        .map_err(|e| format!("Stripe balance credit error: {e}"))?;

    if !resp.status().is_success() {
        let err = resp.text().await.unwrap_or_default();
        return Err(format!("Stripe balance credit failed: {err}"));
    }

    let txn: serde_json::Value = resp.json().await.map_err(|e| format!("Parse error: {e}"))?;
    let txn_id = txn["id"].as_str().unwrap_or("unknown");
    let ending_balance = txn["ending_balance"].as_i64().unwrap_or(0);

    tracing::info!(
        customer = %customer_id,
        transaction = %txn_id,
        ending_balance_cents = ending_balance,
        "Applied referral reward: $10 credit"
    );
    Ok(())
}

/// Increment completed_referrals (and reward_months_granted if reward was granted)
async fn increment_referral_stats(
    client: &reqwest::Client,
    config: &Config,
    token: &str,
    code: &str,
    reward_granted: bool,
) -> Result<(), String> {
    // Read current values
    let doc_url = format!(
        "https://firestore.googleapis.com/v1/projects/{}/databases/(default)/documents/{}/{}",
        config.firebase_project_id, REFERRAL_COLLECTION, code
    );

    let resp = client
        .get(&doc_url)
        .bearer_auth(token)
        .send()
        .await
        .map_err(|e| format!("Firestore read error: {e}"))?;

    let doc: serde_json::Value = resp.json().await.map_err(|e| format!("Parse error: {e}"))?;
    let fields = &doc["fields"];
    let completed = int_field(fields, "completed_referrals") + 1;
    let reward_months = int_field(fields, "reward_months_granted") + if reward_granted { 1 } else { 0 };

    let update = serde_json::json!({
        "fields": {
            "completed_referrals": { "integerValue": completed.to_string() },
            "reward_months_granted": { "integerValue": reward_months.to_string() }
        }
    });

    client
        .patch(&doc_url)
        .bearer_auth(token)
        .json(&update)
        .send()
        .await
        .map_err(|e| format!("Firestore update error: {e}"))?;

    Ok(())
}

/// Extract an integer field from Firestore document fields
fn int_field(fields: &serde_json::Value, key: &str) -> i64 {
    fields[key]["integerValue"]
        .as_str()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
}
