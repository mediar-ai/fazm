# Desktop App Runtime Bootstrap Config
#
# This file gets copied into the app bundle as .env at build time by run.sh.
# It is intentionally checked into the public repo so `git clone && ./run.sh`
# produces a working app that points at the hosted Fazm backend.
#
# Nothing here is a credential:
#   - FAZM_BACKEND_URL is a public Cloud Run URL.
#   - FIREBASE_API_KEY is public by design (Firebase enforces access via
#     security rules + App Check, not via key secrecy). See
#     https://firebase.google.com/docs/projects/api-keys.
#   - GOOGLE_CLIENT_ID is the public half of the OAuth pair.
#   - VERTEX_* and GCP_* are identifiers/addresses; auth happens via WIF
#     server-side and requires a valid Firebase ID token, not these strings.
#
# Real billable model API keys (Anthropic, Deepgram, Gemini-for-models,
# ElevenLabs) are fetched from the backend at runtime via KeyService, gated by
# Firebase auth + a $10 lifetime cap per user. They never ship in any binary.
#
# Local dev overrides go in .env.app.dev (gitignored), which run.sh prefers
# when present.

# Transcription

# Claude Agent SDK (for chat)

# Vertex AI / WIF Configuration (Fazm built-in Claude account)
FAZM_BACKEND_URL=https://fazm-backend-472661769323.us-east5.run.app
VERTEX_PROJECT_ID=fazm-prod
VERTEX_REGION=us-east5
GCP_PROJECT_NUMBER=472661769323
GCP_WORKLOAD_POOL=fazm-desktop-pool
GCP_OIDC_PROVIDER=fazm-backend-provider
GCP_SERVICE_ACCOUNT=vertex-ai-sa@fazm-prod.iam.gserviceaccount.com

# Firebase Auth (Google OAuth Desktop flow)
FIREBASE_API_KEY=AIzaSyCZakQRnmqPf_qAPnXDsCx_QErkZA4dbRA
GOOGLE_CLIENT_ID=472661769323-fjkn42ivn7alcd7mneaff5c7e70a942u.apps.googleusercontent.com


# Gemini CLI (experimental ACP provider, off by default)
# Set FAZM_GEMINI_ENABLED=true to enable the Gemini ACP backend alongside Claude/Codex.
# Auth: GEMINI_API_KEY (free tier) OR GOOGLE_GENAI_USE_VERTEXAI=true + GOOGLE_CLOUD_PROJECT + GOOGLE_CLOUD_LOCATION (WIF).
FAZM_GEMINI_ENABLED=true
