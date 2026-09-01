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
    // API keys served to authenticated clients. The bundled Anthropic/Claude key
    // was discontinued in 2026-06 (see routes/keys.rs); the backend no longer
    // loads or serves it.
    pub deepgram_api_key: String,
    pub gemini_api_key: String,
    pub elevenlabs_api_key: String,
    // Server-only ElevenLabs key used by the /v1/tts moderation proxy. Kept
    // separate from `elevenlabs_api_key` (which is still handed to legacy
    // clients via /v1/keys) so the proxy's traffic can be attributed and the
    // client-shipped key revoked independently. Falls back to
    // `elevenlabs_api_key` when unset.
    pub elevenlabs_proxy_api_key: String,
    // Model used to moderate TTS text before generation (Gemini AI Studio).
    pub tts_moderation_model: String,
    // Mediar dashboard forwarding
    pub mediar_usage_ingest_url: String,
    pub mediar_usage_ingest_secret: String,
    // Shared secret for release management (register/promote endpoints)
    pub release_secret: String,
    // Stripe
    pub stripe_secret_key: String,
    pub stripe_price_id: String,
    // Treatment arm price ID for pricing A/B test ($19.99/mo). When empty,
    // every user falls through to the control price regardless of variant.
    pub stripe_price_id_treatment: String,
    // Kill switch for the pricing A/B test. When false, every user gets
    // control. Mirrors PRICING_AB_ENABLED on the website.
    pub pricing_ab_enabled: bool,
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
    // Composio (third-party integrations: Gmail, Slack, GitHub, etc.)
    // The API key stays server-side and gates the /api/composio/* routes.
    // Each toolkit maps a Composio auth_config_id (OAuth shell) and a Composio
    // mcp_server_id (the MCP endpoint that exposes that toolkit's tools).
    pub composio_api_key: String,
    pub composio_gmail_auth_config_id: String,
    pub composio_gmail_mcp_server_id: String,
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
            deepgram_api_key: std::env::var("DEEPGRAM_API_KEY").unwrap_or_default(),
            gemini_api_key: std::env::var("GEMINI_API_KEY").unwrap_or_default(),
            elevenlabs_api_key: std::env::var("ELEVENLABS_API_KEY").unwrap_or_default(),
            elevenlabs_proxy_api_key: {
                let proxy = std::env::var("ELEVENLABS_PROXY_API_KEY")
                    .unwrap_or_default()
                    .trim()
                    .to_string();
                if proxy.is_empty() {
                    std::env::var("ELEVENLABS_API_KEY").unwrap_or_default()
                } else {
                    proxy
                }
            },
            tts_moderation_model: std::env::var("TTS_MODERATION_MODEL")
                .ok()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "gemini-2.5-flash-lite".to_string()),
            mediar_usage_ingest_url: std::env::var("MEDIAR_USAGE_INGEST_URL").unwrap_or_default(),
            mediar_usage_ingest_secret: std::env::var("MEDIAR_USAGE_INGEST_SECRET")
                .unwrap_or_default(),
            release_secret: std::env::var("RELEASE_SECRET").unwrap_or_default(),
            stripe_secret_key: std::env::var("STRIPE_SECRET_KEY").unwrap_or_default(),
            stripe_price_id: std::env::var("STRIPE_PRICE_ID").unwrap_or_default(),
            stripe_price_id_treatment: std::env::var("STRIPE_PRICE_ID_TREATMENT")
                .unwrap_or_default(),
            pricing_ab_enabled: std::env::var("PRICING_AB_ENABLED")
                .map(|v| v.trim().to_lowercase() != "false")
                .unwrap_or(true),
            stripe_intro_coupon_id: std::env::var("STRIPE_INTRO_COUPON_ID").unwrap_or_default(),
            stripe_webhook_secret: std::env::var("STRIPE_WEBHOOK_SECRET").unwrap_or_default(),
            stripe_trial_days: std::env::var("STRIPE_TRIAL_DAYS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(0),
            resend_api_key: std::env::var("RESEND_API_KEY").unwrap_or_default(),
            github_token: std::env::var("GITHUB_TOKEN")
                .ok()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty()),
            composio_api_key: std::env::var("COMPOSIO_API_KEY").unwrap_or_default(),
            composio_gmail_auth_config_id: std::env::var("COMPOSIO_GMAIL_AUTH_CONFIG_ID")
                .unwrap_or_default(),
            composio_gmail_mcp_server_id: std::env::var("COMPOSIO_GMAIL_MCP_SERVER_ID")
                .unwrap_or_default(),
        }
    }
}
