use axum::{
    extract::Extension,
    http::{header, StatusCode},
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use std::sync::Arc;

use crate::config::Config;
use crate::firestore;

const GITHUB_REPO: &str = "m13v/fazm";
const GITHUB_API: &str = "https://api.github.com";

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
pub async fn appcast(Extension(config): Extension<Arc<Config>>) -> Response {
    match generate_appcast(&config).await {
        Ok(xml) => (
            StatusCode::OK,
            [
                (header::CONTENT_TYPE, "application/rss+xml; charset=utf-8"),
                (header::CACHE_CONTROL, "public, max-age=60"),
            ],
            xml,
        )
            .into_response(),
        Err(e) => {
            tracing::error!("Failed to generate appcast: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("Failed to generate appcast: {}", e),
            )
                .into_response()
        }
    }
}

async fn generate_appcast(
    config: &Arc<Config>,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    // Fetch Firestore channel map (tag → channel) in parallel with GitHub releases
    let (firestore_result, github_result) = tokio::join!(
        fetch_firestore_channels(config),
        fetch_github_releases()
    );

    let channel_map = firestore_result.unwrap_or_else(|e| {
        tracing::warn!("Firestore unavailable, falling back to GitHub isPrerelease: {}", e);
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
            parts.iter().fold(0u64, |acc, &p| acc * 1000 + p).to_string()
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
            items.push(format!(
                r#"    <item>
      <title>Version {version}</title>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{build_number}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>{channel_tag}
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
    <link>https://github.com/m13v/fazm/releases</link>
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
    Ok(releases
        .into_iter()
        .map(|r| (r.tag, r.channel))
        .collect())
}

async fn fetch_github_releases(
) -> Result<Vec<GitHubRelease>, Box<dyn std::error::Error + Send + Sync>> {
    let client = reqwest::Client::builder()
        .user_agent("fazm-backend/1.0")
        .build()?;

    Ok(client
        .get(format!(
            "{}/repos/{}/releases?per_page=20",
            GITHUB_API, GITHUB_REPO
        ))
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?)
}

fn format_rfc2822(iso: &str) -> String {
    let normalized = iso.replace('Z', "+00:00");
    if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(&normalized) {
        dt.format("%a, %d %b %Y %H:%M:%S +0000").to_string()
    } else {
        iso.to_string()
    }
}
