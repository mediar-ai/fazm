//! Gemini API proxy: `ANY /v1/gemini/*path`.
//!
//! Why: until 2026-11 the desktop app got the raw Gemini API key from
//! `/v1/keys` and called Google directly. Any signed-in account could take the
//! key, and it was stolen twice in one week (2026-11-09 and 2026-11-14), each
//! time costing hundreds of dollars before anyone noticed. Rotation does not
//! help while the key is handed out, so the key now stays here.
//!
//! How: `/v1/keys` mints a per-user proxy token (HMAC over uid + expiry). The
//! client uses that token exactly where it used the API key, against this
//! proxy instead of `generativelanguage.googleapis.com` (gemini-cli via
//! `GOOGLE_GEMINI_BASE_URL`, the Swift analysis service via its base URL).
//! The proxy checks the token, the blocklists, a per-user rate limit and a
//! model allowlist, swaps in the real key, and streams both directions.
//!
//! A leaked proxy token is worth far less than a leaked key: it is tied to one
//! uid, it expires, it is rate limited, it cannot reach models outside the
//! allowlist, and blocking the uid kills it without touching anyone else.

use axum::{
    body::Body,
    extract::{Extension, Path, Request},
    http::{HeaderMap, HeaderName, HeaderValue, Method, StatusCode},
    response::{IntoResponse, Response},
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::auth::client_ip;
use crate::config::Config;

type HmacSha256 = Hmac<Sha256>;

const UPSTREAM: &str = "https://generativelanguage.googleapis.com";
const TOKEN_PREFIX: &str = "fzg1";
/// Proxy tokens live this long. The desktop app fetches a fresh one on every
/// launch, so this only bounds how long a copied token stays usable.
pub const TOKEN_TTL_SECS: i64 = 30 * 24 * 3600;
/// Bodies up to this size are buffered (exact Content-Length upstream, cheap
/// retries); larger ones (video uploads) are streamed through.
const BUFFER_LIMIT: usize = 8 * 1024 * 1024;

const ALLOWED_ACTIONS: &[&str] = &[
    "generateContent",
    "streamGenerateContent",
    "countTokens",
    "embedContent",
    "batchEmbedContents",
];

// ─── Tokens ──────────────────────────────────────────────────────────────────

fn sign(secret: &str, payload: &str) -> String {
    let mut mac = HmacSha256::new_from_slice(secret.as_bytes()).expect("hmac accepts any key");
    mac.update(payload.as_bytes());
    hex::encode(mac.finalize().into_bytes())
}

/// Mint a proxy token for `uid`. Returns an empty string when the proxy is not
/// configured, which tells clients to keep using the legacy raw key.
pub fn mint_token(secret: &str, uid: &str, now: i64) -> String {
    if secret.is_empty() || uid.is_empty() {
        return String::new();
    }
    let payload = format!(
        "{}.{}.{}",
        TOKEN_PREFIX,
        URL_SAFE_NO_PAD.encode(uid.as_bytes()),
        now + TOKEN_TTL_SECS
    );
    let sig = sign(secret, &payload);
    format!("{}.{}", payload, sig)
}

/// Verify a proxy token and return the uid it was minted for.
pub fn verify_token(secret: &str, token: &str, now: i64) -> Result<String, &'static str> {
    if secret.is_empty() {
        return Err("proxy not configured");
    }
    let parts: Vec<&str> = token.split('.').collect();
    if parts.len() != 4 || parts[0] != TOKEN_PREFIX {
        return Err("malformed token");
    }
    let payload = format!("{}.{}.{}", parts[0], parts[1], parts[2]);
    let mut mac = HmacSha256::new_from_slice(secret.as_bytes()).expect("hmac accepts any key");
    mac.update(payload.as_bytes());
    let sig = hex::decode(parts[3]).map_err(|_| "malformed signature")?;
    // Constant-time comparison.
    mac.verify_slice(&sig).map_err(|_| "bad signature")?;
    let exp: i64 = parts[2].parse().map_err(|_| "malformed expiry")?;
    if exp < now {
        return Err("token expired");
    }
    let uid = URL_SAFE_NO_PAD
        .decode(parts[1])
        .ok()
        .and_then(|b| String::from_utf8(b).ok())
        .filter(|u| !u.is_empty())
        .ok_or("malformed uid")?;
    Ok(uid)
}

// ─── Path and model policy ───────────────────────────────────────────────────

#[derive(Debug, PartialEq)]
pub struct Target {
    /// Model id for `models/{id}[:action]` calls, used for the allowlist + logs.
    pub model: Option<String>,
    /// `generateContent`, `files`, `listModels`, ...
    pub action: String,
}

/// Decide whether `method path` is something the desktop app legitimately
/// calls. Everything else (tuned models, caches, batches, corpora, ...) is
/// refused so a stolen token cannot be used as a general-purpose Gemini key.
pub fn classify(method: &Method, path: &str) -> Option<Target> {
    let path = path.trim_matches('/');
    let (is_upload, rest) = match path.strip_prefix("upload/") {
        Some(r) => (true, r),
        None => (false, path),
    };
    let mut segs = rest.split('/');
    let version = segs.next()?;
    if !matches!(version, "v1beta" | "v1" | "v1alpha") {
        return None;
    }
    let resource = segs.next()?;
    let tail: Vec<&str> = segs.collect();
    match (resource, tail.as_slice()) {
        ("files", []) if is_upload && (method == Method::POST || method == Method::PUT) => {
            Some(Target {
                model: None,
                action: "files.upload".into(),
            })
        }
        ("files", []) if !is_upload && method == Method::GET => Some(Target {
            model: None,
            action: "files.list".into(),
        }),
        ("files", [id])
            if !is_upload && !id.is_empty() && (method == Method::GET || method == Method::DELETE) =>
        {
            Some(Target {
                model: None,
                action: "files.item".into(),
            })
        }
        ("models", []) if !is_upload && method == Method::GET => Some(Target {
            model: None,
            action: "listModels".into(),
        }),
        ("models", [last]) if !is_upload => match last.split_once(':') {
            Some((model, action))
                if method == Method::POST
                    && !model.is_empty()
                    && ALLOWED_ACTIONS.contains(&action) =>
            {
                Some(Target {
                    model: Some(model.to_string()),
                    action: action.to_string(),
                })
            }
            None if method == Method::GET && !last.is_empty() => Some(Target {
                model: Some(last.to_string()),
                action: "getModel".into(),
            }),
            _ => None,
        },
        _ => None,
    }
}

/// `patterns` entries are exact ids or prefixes ending in `*`.
pub fn model_allowed(patterns: &[String], model: &str) -> bool {
    patterns.iter().any(|p| match p.strip_suffix('*') {
        Some(prefix) => model.starts_with(prefix),
        None => p == model,
    })
}

// ─── Rate limit ──────────────────────────────────────────────────────────────

const RATE_WINDOW: Duration = Duration::from_secs(60);

/// Fixed one-minute window per key. In-memory, so per Cloud Run instance: the
/// effective ceiling is `limit` x instance count, which is still a hard bound
/// on what one token can spend.
fn allow(key: &str, limit: u32) -> bool {
    static HITS: OnceLock<Mutex<HashMap<String, (Instant, u32)>>> = OnceLock::new();
    let mut hits = HITS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let now = Instant::now();
    if hits.len() > 10_000 {
        hits.retain(|_, (start, _)| now.duration_since(*start) < RATE_WINDOW);
    }
    let entry = hits.entry(key.to_string()).or_insert((now, 0));
    if now.duration_since(entry.0) >= RATE_WINDOW {
        *entry = (now, 0);
    }
    entry.1 += 1;
    entry.1 <= limit
}

// ─── Handler ─────────────────────────────────────────────────────────────────

/// Errors use Google's JSON error shape so gemini-cli and the Swift client
/// surface the message instead of a bare status code.
fn api_error(status: StatusCode, message: &str) -> Response {
    let body = serde_json::json!({
        "error": {
            "code": status.as_u16(),
            "message": message,
            "status": status.canonical_reason().unwrap_or("ERROR"),
        }
    });
    (status, axum::Json(body)).into_response()
}

fn http_client() -> &'static reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            // No total timeout: generations stream for minutes. Cloud Run's
            // request timeout bounds the whole exchange.
            .read_timeout(Duration::from_secs(600))
            .build()
            .expect("reqwest client")
    })
}

/// Pull the caller's token from wherever Google clients put an API key.
fn extract_token(headers: &HeaderMap, query: &str) -> Option<String> {
    if let Some(v) = headers.get("x-goog-api-key").and_then(|v| v.to_str().ok()) {
        if !v.trim().is_empty() {
            return Some(v.trim().to_string());
        }
    }
    for (k, v) in url::form_urlencoded::parse(query.as_bytes()) {
        if k == "key" && !v.is_empty() {
            return Some(v.into_owned());
        }
    }
    headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

/// Query string without the caller's `key` (the real key goes in a header).
fn upstream_query(query: &str) -> String {
    let mut out = url::form_urlencoded::Serializer::new(String::new());
    let mut any = false;
    for (k, v) in url::form_urlencoded::parse(query.as_bytes()) {
        if k != "key" {
            out.append_pair(&k, &v);
            any = true;
        }
    }
    if any {
        out.finish()
    } else {
        String::new()
    }
}

/// Resumable uploads answer with an absolute Google URL for the bytes. Point
/// it back at this proxy (carrying the caller's token) so the client never
/// talks to Google directly and never needs the real key.
fn rewrite_upload_url(upstream_url: &str, public_base: &str, token: &str) -> Option<String> {
    let parsed = url::Url::parse(upstream_url).ok()?;
    let mut q = url::form_urlencoded::Serializer::new(String::new());
    for (k, v) in parsed.query_pairs() {
        if k != "key" {
            q.append_pair(&k, &v);
        }
    }
    q.append_pair("key", token);
    Some(format!(
        "{}/v1/gemini{}?{}",
        public_base.trim_end_matches('/'),
        parsed.path(),
        q.finish()
    ))
}

fn public_base(headers: &HeaderMap) -> String {
    let host = headers
        .get("host")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("localhost");
    let proto = headers
        .get("x-forwarded-proto")
        .and_then(|v| v.to_str().ok())
        .unwrap_or(if host.starts_with("localhost") || host.starts_with("127.") {
            "http"
        } else {
            "https"
        });
    format!("{}://{}", proto, host)
}

pub async fn proxy(
    Extension(config): Extension<Arc<Config>>,
    Path(path): Path<String>,
    request: Request,
) -> Response {
    let (parts, body) = request.into_parts();
    let method = parts.method.clone();
    let headers = parts.headers;
    let query = parts.uri.query().unwrap_or("").to_string();
    let ip = client_ip(&headers);

    if config.gemini_proxy_secret.is_empty() || config.gemini_api_key.trim().is_empty() {
        return api_error(StatusCode::SERVICE_UNAVAILABLE, "Gemini proxy is not configured");
    }
    if config.blocked_ips.iter().any(|b| b == &ip) {
        tracing::warn!("Gemini proxy BLOCKED ip={}", ip);
        return api_error(StatusCode::FORBIDDEN, "Access denied");
    }

    let token = match extract_token(&headers, &query) {
        Some(t) => t,
        None => return api_error(StatusCode::UNAUTHORIZED, "Missing credentials"),
    };
    let now = chrono::Utc::now().timestamp();
    let uid = match verify_token(&config.gemini_proxy_secret, &token, now) {
        Ok(uid) => uid,
        Err(reason) => {
            tracing::warn!("Gemini proxy REJECTED token ip={} reason={}", ip, reason);
            return api_error(
                StatusCode::UNAUTHORIZED,
                "Invalid or expired Fazm credentials. Restart Fazm to refresh them.",
            );
        }
    };
    if config.blocked_uids.iter().any(|b| b == &uid) {
        tracing::warn!("Gemini proxy BLOCKED uid={} ip={}", uid, ip);
        return api_error(StatusCode::FORBIDDEN, "Access denied");
    }

    let target = match classify(&method, &path) {
        Some(t) => t,
        None => {
            tracing::warn!(
                "Gemini proxy REFUSED path uid={} ip={} {} {}",
                uid,
                ip,
                method,
                path
            );
            return api_error(StatusCode::NOT_FOUND, "Unsupported Gemini API method");
        }
    };
    if let Some(model) = &target.model {
        if !model_allowed(&config.gemini_proxy_allowed_models, model) {
            tracing::warn!(
                "Gemini proxy REFUSED model uid={} ip={} model={}",
                uid,
                ip,
                model
            );
            return api_error(
                StatusCode::FORBIDDEN,
                &format!("Model {} is not available through Fazm", model),
            );
        }
    }
    if !allow(&format!("uid:{}", uid), config.gemini_proxy_rpm_per_uid) {
        tracing::warn!("Gemini proxy RATE LIMITED uid={} ip={}", uid, ip);
        let mut resp = api_error(
            StatusCode::TOO_MANY_REQUESTS,
            "Too many requests, slow down and retry in a minute",
        );
        resp.headers_mut()
            .insert("retry-after", HeaderValue::from_static("30"));
        return resp;
    }

    // Build the upstream request.
    let uq = upstream_query(&query);
    let upstream_url = if uq.is_empty() {
        format!("{}/{}", UPSTREAM, path.trim_start_matches('/'))
    } else {
        format!("{}/{}?{}", UPSTREAM, path.trim_start_matches('/'), uq)
    };
    let mut up = http_client()
        .request(method.clone(), &upstream_url)
        .header("x-goog-api-key", config.gemini_api_key.trim());
    for (name, value) in headers.iter() {
        let n = name.as_str();
        let forward = n == "content-type"
            || n == "accept"
            || n == "x-goog-api-client"
            || n.starts_with("x-goog-upload-");
        if forward {
            up = up.header(name, value);
        }
    }

    let declared_len = headers
        .get("content-length")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<usize>().ok());
    let req_bytes;
    match declared_len {
        Some(len) if len > BUFFER_LIMIT => {
            req_bytes = len;
            up = up
                .header("content-length", len)
                .body(reqwest::Body::wrap_stream(body.into_data_stream()));
        }
        _ => {
            let bytes = match axum::body::to_bytes(body, BUFFER_LIMIT).await {
                Ok(b) => b,
                Err(_) => {
                    return api_error(StatusCode::PAYLOAD_TOO_LARGE, "Request body too large")
                }
            };
            req_bytes = bytes.len();
            if !bytes.is_empty() || method == Method::POST || method == Method::PUT {
                up = up.body(bytes);
            }
        }
    }

    let started = Instant::now();
    let upstream = match up.send().await {
        Ok(r) => r,
        Err(e) => {
            tracing::error!(
                "Gemini proxy upstream error uid={} action={} err={}",
                uid,
                target.action,
                e
            );
            return api_error(StatusCode::BAD_GATEWAY, "Could not reach Gemini");
        }
    };

    let status = StatusCode::from_u16(upstream.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
    tracing::info!(
        "Gemini proxy uid={} ip={} model={} action={} status={} req_bytes={} ttfb_ms={}",
        uid,
        ip,
        target.model.as_deref().unwrap_or("-"),
        target.action,
        status.as_u16(),
        req_bytes,
        started.elapsed().as_millis()
    );

    let mut out = Response::builder().status(status);
    let base = public_base(&headers);
    for (name, value) in upstream.headers().iter() {
        let n = name.as_str();
        if n == "x-goog-upload-url" || n == "x-goog-upload-control-url" {
            let rewritten = value
                .to_str()
                .ok()
                .and_then(|v| rewrite_upload_url(v, &base, &token))
                .and_then(|v| HeaderValue::from_str(&v).ok());
            if let Some(v) = rewritten {
                out = out.header(name, v);
            }
        } else if n == "content-type" || n == "retry-after" || n.starts_with("x-goog-upload-") {
            out = out.header(
                HeaderName::from_bytes(n.as_bytes()).expect("valid header name"),
                value.clone(),
            );
        }
    }
    out.body(Body::from_stream(upstream.bytes_stream()))
        .unwrap_or_else(|_| api_error(StatusCode::BAD_GATEWAY, "Bad upstream response"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_round_trip_and_rejections() {
        let t = mint_token("secret", "uid-123", 1_000);
        assert_eq!(verify_token("secret", &t, 1_000).unwrap(), "uid-123");
        // Wrong secret, tampered uid, expiry, garbage.
        assert!(verify_token("other", &t, 1_000).is_err());
        let mut parts: Vec<String> = t.split('.').map(String::from).collect();
        parts[1] = URL_SAFE_NO_PAD.encode(b"someone-else");
        assert!(verify_token("secret", &parts.join("."), 1_000).is_err());
        assert!(verify_token("secret", &t, 1_000 + TOKEN_TTL_SECS + 1).is_err());
        assert!(verify_token("secret", "AIzaSyNotAProxyToken", 1_000).is_err());
        // Unconfigured proxy never mints or verifies.
        assert_eq!(mint_token("", "uid-123", 1_000), "");
        assert!(verify_token("", &t, 1_000).is_err());
    }

    #[test]
    fn classify_allows_only_what_the_app_calls() {
        let post = Method::POST;
        let get = Method::GET;
        let t = classify(&post, "v1beta/models/gemini-flash-latest:streamGenerateContent").unwrap();
        assert_eq!(t.model.as_deref(), Some("gemini-flash-latest"));
        assert_eq!(t.action, "streamGenerateContent");
        assert!(classify(&post, "v1beta/models/x:countTokens").is_some());
        assert!(classify(&get, "v1beta/models").is_some());
        assert!(classify(&get, "v1beta/models/gemini-pro-latest").is_some());
        assert!(classify(&post, "upload/v1beta/files").is_some());
        assert!(classify(&Method::PUT, "upload/v1beta/files").is_some());
        assert!(classify(&get, "v1beta/files/abc123").is_some());
        assert!(classify(&Method::DELETE, "v1beta/files/abc123").is_some());
        // Not ours: other actions, other resources, wrong verbs, odd versions.
        assert!(classify(&post, "v1beta/models/x:predictLongRunning").is_none());
        assert!(classify(&post, "v1beta/tunedModels/x:generateContent").is_none());
        assert!(classify(&post, "v1beta/cachedContents").is_none());
        assert!(classify(&post, "v1beta/batches").is_none());
        assert!(classify(&get, "v1beta/models/x:generateContent").is_none());
        assert!(classify(&post, "v2/models/x:generateContent").is_none());
        assert!(classify(&post, "v1beta/models/a/b:generateContent").is_none());
        assert!(classify(&get, "").is_none());
    }

    #[test]
    fn model_allowlist_matches_exact_and_prefix() {
        let p: Vec<String> = ["gemini-flash-latest", "gemini-3*"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert!(model_allowed(&p, "gemini-flash-latest"));
        assert!(model_allowed(&p, "gemini-3.8-flash"));
        assert!(!model_allowed(&p, "gemini-4-argon"));
        assert!(!model_allowed(&p, "gemini-flash-latest-x"));
        assert!(!model_allowed(&[], "gemini-flash-latest"));
    }

    #[test]
    fn upload_url_is_pointed_back_at_the_proxy() {
        let u = rewrite_upload_url(
            "https://generativelanguage.googleapis.com/upload/v1beta/files?key=REAL&upload_id=abc&upload_protocol=resumable",
            "https://backend.example",
            "fzg1.tok",
        )
        .unwrap();
        assert!(u.starts_with("https://backend.example/v1/gemini/upload/v1beta/files?"));
        assert!(u.contains("upload_id=abc"));
        assert!(u.contains("key=fzg1.tok"));
        assert!(!u.contains("REAL"));
    }

    #[test]
    fn caller_key_is_stripped_from_upstream_query() {
        assert_eq!(upstream_query("key=fzg1.x&alt=sse"), "alt=sse");
        assert_eq!(upstream_query("key=fzg1.x"), "");
        assert_eq!(upstream_query(""), "");
    }

    #[test]
    fn rate_limit_blocks_after_limit() {
        for _ in 0..3 {
            assert!(allow("test:gemini-proxy", 3));
        }
        assert!(!allow("test:gemini-proxy", 3));
    }
}
