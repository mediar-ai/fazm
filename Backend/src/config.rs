/// Backend configuration loaded from environment variables
#[derive(Clone)]
pub struct Config {
    pub port: u16,
    pub backend_secret: String,
    pub vertex_sa_private_key_pem: String,
    pub vertex_issuer: String,
    pub vertex_project_id: String,
    pub vertex_region: String,
    pub gcp_project_number: String,
    pub gcp_workload_pool: String,
    pub gcp_oidc_provider: String,
    pub gcp_service_account: String,
    // Session replay GCS bucket
    pub gcs_session_replay_bucket: String,
    // PostHog personal API key (for session recording auto-enrollment)
    pub posthog_personal_api_key: String,
    // Max users to auto-enroll for session recording
    pub session_recording_max_auto_enroll: usize,
}

impl Config {
    pub fn from_env() -> Self {
        Self {
            port: std::env::var("PORT")
                .ok()
                .and_then(|p| p.parse().ok())
                .unwrap_or(8080),
            backend_secret: std::env::var("FAZM_BACKEND_SECRET")
                .expect("FAZM_BACKEND_SECRET must be set"),
            vertex_sa_private_key_pem: {
                let raw = std::env::var("VERTEX_SA_PRIVATE_KEY_PEM")
                    .expect("VERTEX_SA_PRIVATE_KEY_PEM must be set");
                // Support base64-encoded PEM (no BEGIN/END header = base64)
                if raw.contains("BEGIN") {
                    raw
                } else {
                    use base64::Engine;
                    String::from_utf8(
                        base64::engine::general_purpose::STANDARD
                            .decode(&raw)
                            .expect("VERTEX_SA_PRIVATE_KEY_PEM is not valid base64")
                    ).expect("VERTEX_SA_PRIVATE_KEY_PEM base64 is not valid UTF-8")
                }
            },
            vertex_issuer: std::env::var("VERTEX_ISSUER")
                .expect("VERTEX_ISSUER must be set"),
            vertex_project_id: std::env::var("VERTEX_PROJECT_ID")
                .unwrap_or_else(|_| "fazm-prod".to_string()),
            vertex_region: std::env::var("VERTEX_REGION")
                .unwrap_or_else(|_| "us-east5".to_string()),
            gcp_project_number: std::env::var("GCP_PROJECT_NUMBER")
                .unwrap_or_default(),
            gcp_workload_pool: std::env::var("GCP_WORKLOAD_POOL")
                .unwrap_or_else(|_| "fazm-desktop-pool".to_string()),
            gcp_oidc_provider: std::env::var("GCP_OIDC_PROVIDER")
                .unwrap_or_else(|_| "fazm-backend-provider".to_string()),
            gcp_service_account: std::env::var("GCP_SERVICE_ACCOUNT")
                .unwrap_or_default(),
            gcs_session_replay_bucket: std::env::var("GCS_SESSION_REPLAY_BUCKET")
                .unwrap_or_else(|_| "fazm-session-recordings".to_string()),
            posthog_personal_api_key: std::env::var("POSTHOG_PERSONAL_API_KEY")
                .unwrap_or_default(),
            session_recording_max_auto_enroll: std::env::var("SESSION_RECORDING_MAX_AUTO_ENROLL")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(10),
        }
    }
}
