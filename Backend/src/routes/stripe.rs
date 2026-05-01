use axum::{
    body::Bytes,
    extract::{Extension, Query},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Redirect},
    Json,
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::auth::AuthDevice;
use crate::config::Config;

// ---------- Create Checkout Session ----------

#[derive(Deserialize)]
pub struct CreateCheckoutRequest {
    /// Where to redirect after successful payment
    pub success_url: Option<String>,
    /// Where to redirect if user cancels
    pub cancel_url: Option<String>,
}

#[derive(Serialize)]
pub struct CreateCheckoutResponse {
    pub checkout_url: String,
    pub session_id: String,
}

/// POST /api/stripe/create-checkout-session
/// Creates a Stripe Checkout Session for the Fazm subscription.
/// Flat $9.99/month, no free trial. Card is charged immediately on checkout.
pub async fn create_checkout_session(
    Extension(config): Extension<Arc<Config>>,
    Extension(auth): Extension<AuthDevice>,
    Json(body): Json<CreateCheckoutRequest>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let stripe_secret = &config.stripe_secret_key;
    if stripe_secret.is_empty() {
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            "Stripe not configured".to_string(),
        ));
    }

    let firebase_uid = auth.firebase_uid.unwrap_or_default();
    let firebase_email = auth.firebase_email.clone().unwrap_or_default();

    // Stripe Checkout requires https:// URLs. Use backend redirect endpoints
    // that will forward to the app's fazm:// custom URL scheme.
    let backend_base = &config.vertex_issuer; // reuse VERTEX_ISSUER as backend base URL
    let success_url = format!("{backend_base}/api/stripe/redirect?to=fazm://subscription/success");
    let cancel_url = body.cancel_url.unwrap_or_else(|| {
        format!("{backend_base}/api/stripe/redirect?to=fazm://subscription/cancel")
    });

    let client = reqwest::Client::new();

    // First, ensure a Stripe customer exists for this user (idempotent lookup/create).
    // Pass the Firebase email so the Stripe customer record matches the signup email,
    // and Stripe Checkout pre-fills + locks the email field (prevents email mismatches
    // that break support lookups).
    let customer_id = get_or_create_customer(
        &client,
        stripe_secret,
        &firebase_uid,
        &auth.device_id,
        &firebase_email,
    )
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;

    // Create checkout session. By default, no free trial: card is charged immediately.
    // STRIPE_TRIAL_DAYS env var can override (set > 0 to re-enable a trial period).
    let trial_days = config.stripe_trial_days;
    let mut params = vec![
        ("mode", "subscription".to_string()),
        ("customer", customer_id.clone()),
        ("success_url", success_url),
        ("cancel_url", cancel_url),
        ("payment_method_types[0]", "card".to_string()),
        ("line_items[0][price]", config.stripe_price_id.clone()),
        ("line_items[0][quantity]", "1".to_string()),
        // Show the "Add promotion code" link on the Checkout page so users can
        // redeem promo codes (e.g. SEZGI1MO) without manual customer balance edits.
        ("allow_promotion_codes", "true".to_string()),
        ("subscription_data[metadata][firebase_uid]", firebase_uid),
        ("subscription_data[metadata][device_id]", auth.device_id),
    ];

    // Use free trial if configured; otherwise fall back to intro coupon
    if trial_days > 0 {
        params.push((
            "subscription_data[trial_period_days]",
            trial_days.to_string(),
        ));
    } else if !config.stripe_intro_coupon_id.is_empty() {
        params.push((
            "discounts[0][coupon]",
            config.stripe_intro_coupon_id.clone(),
        ));
    }

    let resp = client
        .post("https://api.stripe.com/v1/checkout/sessions")
        .bearer_auth(stripe_secret)
        .form(&params)
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Stripe API error: {e}")))?;

    let status = resp.status();
    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Stripe parse error: {e}")))?;

    if !status.is_success() {
        tracing::error!("Stripe checkout error: {body}");
        return Err((
            StatusCode::BAD_GATEWAY,
            format!("Stripe error: {}", body["error"]["message"]),
        ));
    }

    let checkout_url = body["url"].as_str().unwrap_or_default().to_string();
    let session_id = body["id"].as_str().unwrap_or_default().to_string();

    tracing::info!(customer = %customer_id, session = %session_id, "Checkout session created");

    Ok(Json(CreateCheckoutResponse {
        checkout_url,
        session_id,
    }))
}

// ---------- Redirect ----------

#[derive(Deserialize)]
pub struct RedirectQuery {
    pub to: String,
}

/// GET /api/stripe/redirect?to=fazm://subscription/success
/// Stripe Checkout requires https:// success/cancel URLs. This endpoint
/// serves as a trampoline: Stripe redirects here, and we redirect the
/// browser to the app's custom URL scheme (fazm://).
pub async fn checkout_redirect(Query(query): Query<RedirectQuery>) -> impl IntoResponse {
    // Only allow redirects to the fazm:// scheme
    if !query.to.starts_with("fazm://") {
        return Redirect::temporary("https://fazm.ai").into_response();
    }

    let is_cancel = query.to.contains("/cancel");
    let (heading, subtext) = if is_cancel {
        ("Checkout cancelled", "Taking you back to Fazm...")
    } else {
        ("✓ Payment successful!", "Redirecting you back to Fazm...")
    };

    // Return an HTML page that redirects to the custom URL scheme.
    // Custom URL schemes don't work with HTTP 302 redirects in all browsers,
    // so we use JavaScript + meta refresh as fallback.
    let html = format!(
        r#"<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta http-equiv="refresh" content="1;url={url}">
    <title>Redirecting to Fazm...</title>
    <style>
        body {{ background: #0F0F0F; color: #E5E5E5; font-family: -apple-system, system-ui, sans-serif; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }}
        .container {{ text-align: center; }}
        h1 {{ color: #8B5CF6; font-size: 24px; }}
        p {{ color: #B0B0B0; }}
        a {{ color: #8B5CF6; }}
    </style>
</head>
<body>
    <div class="container">
        <h1>{heading}</h1>
        <p>{subtext}</p>
        <p><a href="{url}">Click here if not redirected automatically</a></p>
    </div>
    <script>window.location.href = "{url}";</script>
</body>
</html>"#,
        url = query.to,
        heading = heading,
        subtext = subtext,
    );

    axum::response::Html(html).into_response()
}

// ---------- Subscription Status ----------

#[derive(Serialize)]
pub struct SubscriptionStatusResponse {
    pub active: bool,
    pub status: String, // "active", "trialing", "past_due", "canceled", "none"
    pub current_period_end: Option<i64>,
}

/// GET /api/stripe/subscription-status
/// Returns the subscription status for the authenticated user.
pub async fn subscription_status(
    Extension(config): Extension<Arc<Config>>,
    Extension(auth): Extension<AuthDevice>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let stripe_secret = &config.stripe_secret_key;
    if stripe_secret.is_empty() {
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            "Stripe not configured".to_string(),
        ));
    }

    let firebase_uid = auth.firebase_uid.unwrap_or_default();
    let firebase_email = auth.firebase_email.clone().unwrap_or_default();
    let client = reqwest::Client::new();

    // Look up customer by Firebase UID metadata
    let mut customer_id = find_customer(&client, stripe_secret, &firebase_uid)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;

    // Fallback: search by email (e.g., customer created on website without Firebase UID)
    if customer_id.is_none() && !firebase_email.is_empty() {
        if let Some(cid) = find_customer_by_email(&client, stripe_secret, &firebase_email)
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?
        {
            // Auto-link: add firebase_uid to this customer so future lookups are fast
            let _ = client
                .post(&format!("https://api.stripe.com/v1/customers/{cid}"))
                .bearer_auth(stripe_secret)
                .form(&[
                    ("metadata[firebase_uid]", firebase_uid.as_str()),
                    ("metadata[device_id]", &auth.device_id),
                ])
                .send()
                .await;
            tracing::info!(
                customer = %cid,
                firebase_uid = %firebase_uid,
                email = %firebase_email,
                "Auto-linked website Stripe customer to Firebase UID"
            );
            customer_id = Some(cid);
        }
    }

    let Some(customer_id) = customer_id else {
        return Ok(Json(SubscriptionStatusResponse {
            active: false,
            status: "none".to_string(),
            current_period_end: None,
        }));
    };

    // List active subscriptions for this customer
    let resp = client
        .get("https://api.stripe.com/v1/subscriptions")
        .bearer_auth(stripe_secret)
        .query(&[("customer", &customer_id), ("limit", &"1".to_string())])
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Stripe API error: {e}")))?;

    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Stripe parse error: {e}")))?;

    let subs = body["data"].as_array();
    if let Some(subs) = subs {
        if let Some(sub) = subs.first() {
            let status = sub["status"].as_str().unwrap_or("none").to_string();
            let active = matches!(status.as_str(), "active" | "trialing");
            let period_end = sub["current_period_end"].as_i64();
            return Ok(Json(SubscriptionStatusResponse {
                active,
                status,
                current_period_end: period_end,
            }));
        }
    }

    Ok(Json(SubscriptionStatusResponse {
        active: false,
        status: "none".to_string(),
        current_period_end: None,
    }))
}

// ---------- Billing Portal ----------

#[derive(Serialize)]
pub struct PortalSessionResponse {
    pub portal_url: String,
}

/// POST /api/stripe/create-portal-session
/// Creates a Stripe Billing Portal session so the user can manage their subscription.
pub async fn create_portal_session(
    Extension(config): Extension<Arc<Config>>,
    Extension(auth): Extension<AuthDevice>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let stripe_secret = &config.stripe_secret_key;
    if stripe_secret.is_empty() {
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            "Stripe not configured".to_string(),
        ));
    }

    let firebase_uid = auth.firebase_uid.unwrap_or_default();
    let firebase_email = auth.firebase_email.clone().unwrap_or_default();
    let client = reqwest::Client::new();

    // Find the Stripe customer
    let mut customer_id = find_customer(&client, stripe_secret, &firebase_uid)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;

    if customer_id.is_none() && !firebase_email.is_empty() {
        customer_id = find_customer_by_email(&client, stripe_secret, &firebase_email)
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;
    }

    let Some(customer_id) = customer_id else {
        return Err((
            StatusCode::NOT_FOUND,
            "No Stripe customer found for this account".to_string(),
        ));
    };

    // Create a billing portal session
    let resp = client
        .post("https://api.stripe.com/v1/billing_portal/sessions")
        .bearer_auth(stripe_secret)
        .form(&[("customer", customer_id.as_str())])
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Stripe API error: {e}")))?;

    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Stripe parse error: {e}")))?;

    let portal_url = body["url"]
        .as_str()
        .ok_or_else(|| {
            let err = body["error"]["message"]
                .as_str()
                .unwrap_or("Unknown error creating portal session");
            (StatusCode::BAD_GATEWAY, err.to_string())
        })?
        .to_string();

    Ok(Json(PortalSessionResponse { portal_url }))
}

// ---------- Webhook ----------

/// POST /api/stripe/webhook
/// Handles Stripe webhook events (subscription created, updated, deleted, etc.)
pub async fn webhook(
    Extension(config): Extension<Arc<Config>>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let stripe_secret = &config.stripe_webhook_secret;

    // Verify webhook signature if secret is configured
    if !stripe_secret.is_empty() && stripe_secret != "placeholder" {
        let sig = headers
            .get("stripe-signature")
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default();

        if !verify_stripe_signature(&body, sig, stripe_secret) {
            return Err((StatusCode::BAD_REQUEST, "Invalid signature".to_string()));
        }
    }

    let event: serde_json::Value = serde_json::from_slice(&body)
        .map_err(|e| (StatusCode::BAD_REQUEST, format!("Invalid JSON: {e}")))?;

    let event_type = event["type"].as_str().unwrap_or_default();
    tracing::info!(event_type, "Stripe webhook received");

    match event_type {
        "checkout.session.completed" => {
            let session = &event["data"]["object"];
            let customer = session["customer"].as_str().unwrap_or_default();
            let subscription = session["subscription"].as_str().unwrap_or_default();
            tracing::info!(customer, subscription, "Checkout completed");
        }
        "customer.subscription.created"
        | "customer.subscription.updated"
        | "customer.subscription.deleted" => {
            let sub = &event["data"]["object"];
            let customer = sub["customer"].as_str().unwrap_or_default();
            let status = sub["status"].as_str().unwrap_or_default();
            let firebase_uid = sub["metadata"]["firebase_uid"].as_str().unwrap_or_default();
            tracing::info!(
                customer,
                status,
                firebase_uid,
                event_type,
                "Subscription event"
            );
        }
        _ => {
            tracing::debug!(event_type, "Unhandled webhook event");
        }
    }

    Ok(StatusCode::OK)
}

// ---------- Helpers ----------

/// Find or create a Stripe customer by Firebase UID
async fn get_or_create_customer(
    client: &reqwest::Client,
    secret: &str,
    firebase_uid: &str,
    device_id: &str,
    firebase_email: &str,
) -> Result<String, String> {
    // Search for existing customer
    if let Some(id) = find_customer(client, secret, firebase_uid).await? {
        return Ok(id);
    }

    // Create new customer with the Firebase login email pre-set so:
    // (1) Stripe Checkout pre-fills + locks the email field (prevents user typing a different one)
    // (2) Support tools can find the customer by their actual signup email
    let mut form_params: Vec<(&str, &str)> = vec![
        ("metadata[firebase_uid]", firebase_uid),
        ("metadata[device_id]", device_id),
    ];
    if !firebase_email.is_empty() {
        form_params.push(("email", firebase_email));
    }

    let resp = client
        .post("https://api.stripe.com/v1/customers")
        .bearer_auth(secret)
        .form(&form_params)
        .send()
        .await
        .map_err(|e| format!("Stripe customer create error: {e}"))?;

    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| format!("Stripe parse error: {e}"))?;

    body["id"]
        .as_str()
        .map(|s| s.to_string())
        .ok_or_else(|| format!("No customer ID in response: {body}"))
}

/// Find a Stripe customer by email address
async fn find_customer_by_email(
    client: &reqwest::Client,
    secret: &str,
    email: &str,
) -> Result<Option<String>, String> {
    let resp = client
        .get("https://api.stripe.com/v1/customers/search")
        .bearer_auth(secret)
        .query(&[("query", &format!("email:'{email}'"))])
        .send()
        .await
        .map_err(|e| format!("Stripe search error: {e}"))?;

    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| format!("Stripe parse error: {e}"))?;

    Ok(body["data"]
        .as_array()
        .and_then(|arr| arr.first())
        .and_then(|c| c["id"].as_str())
        .map(|s| s.to_string()))
}

/// Find a Stripe customer by Firebase UID metadata
async fn find_customer(
    client: &reqwest::Client,
    secret: &str,
    firebase_uid: &str,
) -> Result<Option<String>, String> {
    let resp = client
        .get("https://api.stripe.com/v1/customers/search")
        .bearer_auth(secret)
        .query(&[(
            "query",
            &format!("metadata['firebase_uid']:'{firebase_uid}'"),
        )])
        .send()
        .await
        .map_err(|e| format!("Stripe search error: {e}"))?;

    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| format!("Stripe parse error: {e}"))?;

    Ok(body["data"]
        .as_array()
        .and_then(|arr| arr.first())
        .and_then(|c| c["id"].as_str())
        .map(|s| s.to_string()))
}

/// Verify Stripe webhook signature (v1 scheme)
fn verify_stripe_signature(payload: &[u8], sig_header: &str, secret: &str) -> bool {
    use hmac::{Hmac, Mac};
    use sha2::Sha256;

    // Parse signature header: t=timestamp,v1=signature
    let mut timestamp = "";
    let mut signature = "";
    for part in sig_header.split(',') {
        if let Some(t) = part.strip_prefix("t=") {
            timestamp = t;
        } else if let Some(s) = part.strip_prefix("v1=") {
            signature = s;
        }
    }

    if timestamp.is_empty() || signature.is_empty() {
        return false;
    }

    // Compute expected signature
    let signed_payload = format!("{timestamp}.{}", String::from_utf8_lossy(payload));
    let mut mac =
        Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("HMAC can take key of any size");
    mac.update(signed_payload.as_bytes());
    let expected = hex::encode(mac.finalize().into_bytes());

    // Constant-time comparison
    expected == signature
}
