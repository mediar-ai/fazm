use axum::{
    extract::Extension,
    http::{header, StatusCode},
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use std::sync::{Arc, LazyLock};
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

use crate::config::Config;
use crate::firestore;

const GITHUB_REPO: &str = "mediar-ai/fazm";
const GITHUB_API: &str = "https://api.github.com";

/// Minimum supported app version. Clients below this see the latest update marked as
/// a Sparkle critical update (non-skippable prompt, aggressive re-prompt on relaunch).
/// Raise this when a newly shipped enforcement (paywall, auth gate, etc.) must not be
/// bypassable by running an older binary. Clients at or above this version are unaffected.
const MIN_SUPPORTED_VERSION: &str = "2.1.0";

/// Cache the generated appcast XML for this long. Sparkle clients re-check every 24h
/// per install, so a 5 minute cache is invisible to users but eliminates per-request
/// GitHub + Firestore round trips and protects against the 60 req/hr unauthenticated
/// GitHub rate limit on shared Cloud Run egress IPs.
const CACHE_TTL: Duration = Duration::from_secs(300);

/// If the upstream fetch (GitHub or Firestore) fails, serve a stale cached XML up to
/// this old. Better to deliver yesterday's appcast than a 500 that triggers Sparkle
/// SUAppcastError 2001 on every client.
const STALE_TTL: Duration = Duration::from_secs(24 * 3600);

/// Per-request timeout for upstream calls. Sparkle's default fetch timeout is generous
/// (~30s) but we want to fail fast and serve stale rather than hold a connection open.
const UPSTREAM_TIMEOUT: Duration = Duration::from_secs(8);

#[derive(Clone)]
struct CacheEntry {
    xml: String,
    fetched_at: Instant,
}

/// In-memory cache of the rendered appcast XML. Per-process, so each Cloud Run
/// instance maintains its own copy. With min=2..max=3 instances and a 5 min TTL,
/// upstream fetches drop to ~24/hr, well under GitHub's 60 req/hr unauthenticated cap.
static APPCAST_CACHE: LazyLock<Mutex<Option<CacheEntry>>> = LazyLock::new(|| Mutex::new(None));

/// Shared HTTP client. Constructing a `reqwest::Client` per request triggered a fresh
/// TLS handshake every time (~500-800ms TTFB). One client = pooled connections =
/// negligible TLS cost on warm requests.
static HTTP_CLIENT: LazyLock<reqwest::Client> = LazyLock::new(|| {
    reqwest::Client::builder()
        .user_agent("fazm-backend/1.0")
        .timeout(UPSTREAM_TIMEOUT)
        .pool_idle_timeout(Duration::from_secs(90))
        .build()
        .expect("failed to build appcast HTTP client")
});

#[derive(Deserialize)]
struct GitHubRelease {
    tag_name: String,
    published_at: String,
    body: Option<String>,
    assets: Vec<GitHubAsset>,
    draft: bool,
}

#[derive(Deserialize)]
struct GitHubAsset {
    name: String,
    browser_download_url: String,
    size: u64,
}

/// GET /appcast.xml
/// Dynamically generates a Sparkle-compatible appcast from GitHub releases.
/// Channels are read from Firestore `desktop_releases` collection.
/// Fallback: if Firestore is unavailable, uses GitHub's isPrerelease flag.
///
/// Caching strategy:
///   1. Fresh cache (<5 min old): return immediately, no upstream calls.
///   2. Stale cache + upstream succeeds: refresh and return new XML.
///   3. Stale cache + upstream fails: return stale XML (up to 24h old) with a warning log.
///   4. No cache + upstream fails: return 500 (Sparkle will retry on next 24h check).
pub async fn appcast(Extension(config): Extension<Arc<Config>>) -> Response {
    // Fast path: serve fresh cache without touching upstream.
    {
        let guard = APPCAST_CACHE.lock().await;
        if let Some(entry) = guard.as_ref() {
            if entry.fetched_at.elapsed() < CACHE_TTL {
                return ok_response(entry.xml.clone());
            }
        }
    }

    // Slow path: regenerate from GitHub + Firestore.
    match generate_appcast(&config).await {
        Ok(xml) => {
            let mut guard = APPCAST_CACHE.lock().await;
            *guard = Some(CacheEntry {
                xml: xml.clone(),
                fetched_at: Instant::now(),
            });
            ok_response(xml)
        }
        Err(e) => {
            // Fall back to stale cache if we have anything reasonably recent.
            let stale = APPCAST_CACHE.lock().await.as_ref().and_then(|entry| {
                if entry.fetched_at.elapsed() < STALE_TTL {
                    Some(entry.xml.clone())
                } else {
                    None
                }
            });

            if let Some(xml) = stale {
                tracing::warn!(
                    "Appcast upstream failed ({}), serving stale cache (age {:?})",
                    e,
                    APPCAST_CACHE
                        .lock()
                        .await
                        .as_ref()
                        .map(|c| c.fetched_at.elapsed())
                        .unwrap_or_default()
                );
                return ok_response(xml);
            }

            tracing::error!("Failed to generate appcast (no cache to fall back on): {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("Failed to generate appcast: {}", e),
            )
                .into_response()
        }
    }
}

fn ok_response(xml: String) -> Response {
    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "application/rss+xml; charset=utf-8"),
            // 60s public cache lets browsers and proxies smooth burst traffic too.
            (header::CACHE_CONTROL, "public, max-age=60"),
        ],
        xml,
    )
        .into_response()
}

async fn generate_appcast(
    config: &Arc<Config>,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    // Fetch Firestore channel map (tag → channel) in parallel with GitHub releases
    let (firestore_result, github_result) = tokio::join!(
        fetch_firestore_channels(config),
        fetch_github_releases(config.github_token.as_deref())
    );

    let channel_map = firestore_result.unwrap_or_else(|e| {
        tracing::warn!(
            "Firestore unavailable, falling back to GitHub isPrerelease: {}",
            e
        );
        std::collections::HashMap::new()
    });

    let releases = github_result?;
    let mut items = Vec::new();

    for release in &releases {
        if release.draft {
            continue;
        }

        // Find the .zip asset (not appcast.xml)
        let zip_asset = release
            .assets
            .iter()
            .find(|a| a.name.ends_with(".zip") && !a.name.to_lowercase().contains("appcast"));

        let zip_asset = match zip_asset {
            Some(a) => a,
            None => continue,
        };

        // Parse version from tag: v0.9.1+57-macos-staging
        let version_re =
            regex_lite::Regex::new(r"v?(\d+\.\d+\.\d+)(?:\+(\d+))?(?:-macos)?(?:-(staging|beta))?")
                .unwrap();

        let caps = match version_re.captures(&release.tag_name) {
            Some(c) => c,
            None => continue,
        };

        let version = &caps[1];
        let build_number = if let Some(b) = caps.get(2) {
            b.as_str().to_string()
        } else {
            let parts: Vec<u64> = version.split('.').filter_map(|p| p.parse().ok()).collect();
            parts
                .iter()
                .fold(0u64, |acc, &p| acc * 1000 + p)
                .to_string()
        };

        // Determine channel:
        // 1. Check Firestore (authoritative — supports all 3 channels)
        // 2. Fallback: Firestore empty → use GitHub isPrerelease
        //    (isPrerelease=false → stable, isPrerelease=true → staging)
        let channel = channel_map
            .get(&release.tag_name)
            .cloned()
            .unwrap_or_else(|| {
                // Firestore not available — skip this release (only show Firestore-tracked ones)
                // If channel_map is empty (Firestore failed), fall back to a simple heuristic
                if channel_map.is_empty() {
                    // Fallback: use tag suffix
                    if release.tag_name.ends_with("-staging") {
                        "staging".to_string()
                    } else {
                        "stable".to_string()
                    }
                } else {
                    // Firestore available but no doc for this tag → skip
                    "skip".to_string()
                }
            });

        if channel == "skip" {
            continue;
        }

        // Extract EdDSA signature from release body
        let ed_sig = release
            .body
            .as_deref()
            .and_then(|body| {
                let re =
                    regex_lite::Regex::new(r#"edSignature[\"=:]\s*[\"]*([A-Za-z0-9+/=]{40,})"#)
                        .ok()?;
                re.captures(body)
                    .and_then(|c| c.get(1))
                    .map(|m| m.as_str().to_string())
            })
            .unwrap_or_default();

        // Extract release notes from GitHub release body (markdown → HTML)
        let release_notes_html = release
            .body
            .as_deref()
            .map(|body| markdown_to_html_release_notes(body, version))
            .unwrap_or_default();

        let pub_date = format_rfc2822(&release.published_at);

        // Sparkle channel tags — each release may appear on multiple channels:
        //   stable  → no tag (visible to everyone)
        //   beta    → emitted on both "beta" and "staging" channels
        //   staging → "staging" channel only
        let channel_tags: Vec<String> = match channel.as_str() {
            "staging" => vec!["\n      <sparkle:channel>staging</sparkle:channel>".to_string()],
            "beta" => vec![
                "\n      <sparkle:channel>beta</sparkle:channel>".to_string(),
                "\n      <sparkle:channel>staging</sparkle:channel>".to_string(),
            ],
            _ => vec![String::new()], // stable = no tag
        };

        let mut enclosure_attrs = format!(r#"url="{}""#, zip_asset.browser_download_url);
        if !ed_sig.is_empty() {
            enclosure_attrs.push_str(&format!(
                "\n                 sparkle:edSignature=\"{}\"",
                ed_sig
            ));
        }
        enclosure_attrs.push_str(&format!("\n                 length=\"{}\"", zip_asset.size));
        enclosure_attrs.push_str("\n                 type=\"application/octet-stream\"");

        for channel_tag in &channel_tags {
            let description_block = if !release_notes_html.is_empty() {
                format!(
                    "\n      <description><![CDATA[{}]]></description>",
                    release_notes_html
                )
            } else {
                String::new()
            };

            items.push(format!(
                r#"    <item>
      <title>Version {version}</title>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{build_number}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:criticalUpdate sparkle:version="{MIN_SUPPORTED_VERSION}"/>{channel_tag}{description_block}
      <enclosure {enclosure_attrs}/>
    </item>"#,
            ));
        }
    }

    Ok(format!(
        r#"<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Fazm</title>
    <link>https://github.com/mediar-ai/fazm/releases</link>
    <description>Fazm Desktop Updates</description>
    <language>en</language>
{items}
  </channel>
</rss>"#,
        items = items.join("\n")
    ))
}

/// Fetch channel assignments from Firestore. Returns a map of tag → channel.
async fn fetch_firestore_channels(
    config: &Arc<Config>,
) -> Result<std::collections::HashMap<String, String>, Box<dyn std::error::Error + Send + Sync>> {
    let token = firestore::get_access_token(config).await?;
    let releases = firestore::list_live_releases(config, &token).await?;
    Ok(releases.into_iter().map(|r| (r.tag, r.channel)).collect())
}

async fn fetch_github_releases(
    token: Option<&str>,
) -> Result<Vec<GitHubRelease>, Box<dyn std::error::Error + Send + Sync>> {
    let mut req = HTTP_CLIENT.get(format!(
        "{}/repos/{}/releases?per_page=20",
        GITHUB_API, GITHUB_REPO
    ));

    // Authenticated requests bump the rate limit from 60/hr/IP to 5,000/hr/token.
    // Optional: if no token is configured we fall back to unauthenticated, which
    // is fine when the in-memory cache is doing its job.
    if let Some(t) = token {
        if !t.is_empty() {
            req = req.header("Authorization", format!("Bearer {}", t));
            req = req.header("X-GitHub-Api-Version", "2022-11-28");
        }
    }

    Ok(req.send().await?.error_for_status()?.json().await?)
}

/// Convert GitHub release body markdown into simple HTML for Sparkle release notes.
/// Extracts the "What's New" section and converts markdown list items to HTML.
fn markdown_to_html_release_notes(body: &str, version: &str) -> String {
    // Extract lines between "### What's New" and the next "###" or end
    let mut in_section = false;
    let mut items: Vec<String> = Vec::new();

    for line in body.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("### What's New") {
            in_section = true;
            continue;
        }
        if in_section && trimmed.starts_with("###") {
            break;
        }
        if in_section && trimmed.starts_with("- ") {
            let text = &trimmed[2..];
            // Escape HTML entities
            let escaped = text
                .replace('&', "&amp;")
                .replace('<', "&lt;")
                .replace('>', "&gt;");
            items.push(format!("<li>{}</li>", escaped));
        }
    }

    // If no "What's New" section, try all top-level list items
    if items.is_empty() {
        for line in body.lines() {
            let trimmed = line.trim();
            if trimmed.starts_with("- ") {
                let text = &trimmed[2..];
                let escaped = text
                    .replace('&', "&amp;")
                    .replace('<', "&lt;")
                    .replace('>', "&gt;");
                items.push(format!("<li>{}</li>", escaped));
            }
        }
    }

    if items.is_empty() {
        return String::new();
    }

    format!(
        "<h2>What's New in {}</h2><ul>{}</ul>",
        version,
        items.join("")
    )
}

fn format_rfc2822(iso: &str) -> String {
    let normalized = iso.replace('Z', "+00:00");
    if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(&normalized) {
        dt.format("%a, %d %b %Y %H:%M:%S +0000").to_string()
    } else {
        iso.to_string()
    }
}
