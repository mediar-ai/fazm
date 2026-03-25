use axum::{middleware, Extension, Router};
use std::sync::Arc;
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;

mod auth;
mod config;
mod firestore;
mod routes;

use config::Config;
use routes::relay;

#[tokio::main]
async fn main() {
    // Initialize tracing
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "fazm_backend=info,tower_http=info".into()),
        )
        .with_target(false)
        .init();

    dotenvy::dotenv().ok();

    let config = Arc::new(Config::from_env());
    let port = config.port;
    let tunnel_registry = relay::new_tunnel_registry();

    // Authed routes (require shared secret)
    let authed_routes = Router::new()
        .route(
            "/v1/vertex/subject-token",
            axum::routing::post(routes::vertex::subject_token),
        )
        .route(
            "/api/session-recording/get-upload-url",
            axum::routing::post(routes::session_recording::get_upload_url),
        )
        .route(
            "/api/session-recording/auto-enroll",
            axum::routing::post(routes::session_recording::auto_enroll),
        )
        .route(
            "/v1/keys",
            axum::routing::post(routes::keys::get_keys),
        )
        .route(
            "/api/releases/register",
            axum::routing::post(routes::releases::register),
        )
        .route(
            "/api/releases/promote",
            axum::routing::patch(routes::releases::promote),
        )
        .route(
            "/api/relay/register",
            axum::routing::post(routes::relay::register),
        )
        .route(
            "/api/relay/unregister",
            axum::routing::post(routes::relay::unregister),
        )
        .route(
            "/api/relay/discover",
            axum::routing::get(routes::relay::discover),
        )
        .layer(middleware::from_fn(auth::auth_middleware));

    // Public routes
    let public_routes = Router::new()
        .route("/health", axum::routing::get(routes::vertex::health))
        .route("/appcast.xml", axum::routing::get(routes::appcast::appcast))
        .route(
            "/api/releases",
            axum::routing::get(routes::releases::list),
        )
        .route(
            "/v1/vertex/jwks",
            axum::routing::get(routes::vertex::jwks),
        )
        .route(
            "/.well-known/openid-configuration",
            axum::routing::get(routes::vertex::openid_configuration),
        );

    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    let jwks_cache = auth::new_jwks_cache();

    let app = Router::new()
        .merge(authed_routes)
        .merge(public_routes)
        .layer(Extension(jwks_cache))
        .layer(Extension(tunnel_registry))
        .layer(Extension(config))
        .layer(cors)
        .layer(TraceLayer::new_for_http());

    let addr = format!("0.0.0.0:{}", port);
    tracing::info!("Starting Fazm Backend on {}", addr);

    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

