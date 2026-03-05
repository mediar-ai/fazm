use axum::{middleware, Extension, Router};
use std::sync::Arc;
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;

mod auth;
mod config;
mod routes;

use config::Config;

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

    // Authed routes (require shared secret)
    let authed_routes = Router::new()
        .route(
            "/v1/vertex/subject-token",
            axum::routing::post(routes::vertex::subject_token),
        )
        .layer(middleware::from_fn(auth::auth_middleware));

    // Public routes
    let public_routes = Router::new()
        .route("/health", axum::routing::get(routes::vertex::health))
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

    let app = Router::new()
        .merge(authed_routes)
        .merge(public_routes)
        .layer(Extension(config))
        .layer(cors)
        .layer(TraceLayer::new_for_http());

    let addr = format!("0.0.0.0:{}", port);
    tracing::info!("Starting Fazm Backend on {}", addr);

    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
