/// Backend configuration loaded from environment variables
#[derive(Clone)]
pub struct Config {
    pub port: u16,
    pub firebase_project_id: String,
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
    // API keys served to authenticated clients
    pub anthropic_api_key: String,
    pub deepgram_api_key: String,
    pub gemini_api_key: String,
    pub elevenlabs_api_key: String,
    // Comma-separated list of Firebase UIDs or device IDs that should NOT receive the builtin API key.
    // Set to "*" to block ALL users (global kill switch).
    pub builtin_key_blocklist: Vec<String>,
    // Mediar dashboard forwarding
    pub mediar_usage_ingest_url: String,
    pub mediar_usage_ingest_secret: String,
    // Shared secret for release management (register/promote endpoints)
    pub release_secret: String,
    // Stripe
    pub stripe_secret_key: String,
    pub stripe_price_id: String,
    pub stripe_intro_coupon_id: String,
    pub stripe_webhook_secret: String,
    pub stripe_trial_days: u32,
    // Resend (email service)
    pub resend_api_key: String,
    // GitHub PAT for /appcast.xml generation. Optional — when set, the appcast
    // route uses authenticated GitHub API requests (5,000 req/hr/token vs 60
    // req/hr/IP unauthenticated), protecting against burst-induced 403s when
    // many Sparkle clients sync within the same hour.
    pub github_token: Option<String>,
}

impl Config {
    pub fn from_env() -> Self {
        Self {
            port: std::env::var("PORT")
                .ok()
                .and_then(|p| p.parse().ok())
                .unwrap_or(8080),
            firebase_project_id: std::env::var("FIREBASE_PROJECT_ID")
                .unwrap_or_else(|_| "fazm-prod".to_string()),
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
                            .expect("VERTEX_SA_PRIVATE_KEY_PEM is not valid base64"),
                    )
                    .expect("VERTEX_SA_PRIVATE_KEY_PEM base64 is not valid UTF-8")
                }
            },
            vertex_issuer: std::env::var("VERTEX_ISSUER").expect("VERTEX_ISSUER must be set"),
            vertex_project_id: std::env::var("VERTEX_PROJECT_ID")
                .unwrap_or_else(|_| "fazm-prod".to_string()),
            vertex_region: std::env::var("VERTEX_REGION")
                .unwrap_or_else(|_| "us-east5".to_string()),
            gcp_project_number: std::env::var("GCP_PROJECT_NUMBER").unwrap_or_default(),
            gcp_workload_pool: std::env::var("GCP_WORKLOAD_POOL")
                .unwrap_or_else(|_| "fazm-desktop-pool".to_string()),
            gcp_oidc_provider: std::env::var("GCP_OIDC_PROVIDER")
                .unwrap_or_else(|_| "fazm-backend-provider".to_string()),
            gcp_service_account: std::env::var("GCP_SERVICE_ACCOUNT").unwrap_or_default(),
            gcs_session_replay_bucket: std::env::var("GCS_SESSION_REPLAY_BUCKET")
                .unwrap_or_else(|_| "fazm-session-recordings".to_string()),
            posthog_personal_api_key: std::env::var("POSTHOG_PERSONAL_API_KEY").unwrap_or_default(),
            anthropic_api_key: std::env::var("ANTHROPIC_API_KEY").unwrap_or_default(),
            deepgram_api_key: std::env::var("DEEPGRAM_API_KEY").unwrap_or_default(),
            gemini_api_key: std::env::var("GEMINI_API_KEY").unwrap_or_default(),
            elevenlabs_api_key: std::env::var("ELEVENLABS_API_KEY").unwrap_or_default(),
            builtin_key_blocklist: std::env::var("BUILTIN_KEY_BLOCKLIST")
                .unwrap_or_default()
                .split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect(),
            mediar_usage_ingest_url: std::env::var("MEDIAR_USAGE_INGEST_URL").unwrap_or_default(),
            mediar_usage_ingest_secret: std::env::var("MEDIAR_USAGE_INGEST_SECRET")
                .unwrap_or_default(),
            release_secret: std::env::var("RELEASE_SECRET").unwrap_or_default(),
            stripe_secret_key: std::env::var("STRIPE_SECRET_KEY").unwrap_or_default(),
            stripe_price_id: std::env::var("STRIPE_PRICE_ID").unwrap_or_default(),
            stripe_intro_coupon_id: std::env::var("STRIPE_INTRO_COUPON_ID").unwrap_or_default(),
            stripe_webhook_secret: std::env::var("STRIPE_WEBHOOK_SECRET").unwrap_or_default(),
            stripe_trial_days: std::env::var("STRIPE_TRIAL_DAYS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(1),
            resend_api_key: std::env::var("RESEND_API_KEY").unwrap_or_default(),
            github_token: std::env::var("GITHUB_TOKEN")
                .ok()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty()),
        }
    }
}
