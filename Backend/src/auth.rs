use axum::{
    extract::Request,
    http::StatusCode,
    middleware::Next,
    response::Response,
};
use std::sync::Arc;

use crate::config::Config;

/// Authenticated device info extracted from headers
#[derive(Clone, Debug)]
pub struct AuthDevice {
    pub device_id: String,
}

/// Middleware that validates the shared secret and extracts device ID
pub async fn auth_middleware(
    request: Request,
    next: Next,
) -> Result<Response, StatusCode> {
    let config = request
        .extensions()
        .get::<Arc<Config>>()
        .cloned()
        .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;

    // Check Authorization header
    let auth_header = request
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .ok_or(StatusCode::UNAUTHORIZED)?;

    if !auth_header.starts_with("Bearer ") {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let token = &auth_header[7..];
    if token != config.backend_secret {
        return Err(StatusCode::UNAUTHORIZED);
    }

    // Extract device ID
    let device_id = request
        .headers()
        .get("x-device-id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("unknown")
        .to_string();

    let mut request = request;
    request.extensions_mut().insert(AuthDevice { device_id });

    Ok(next.run(request).await)
}
