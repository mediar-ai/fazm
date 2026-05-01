/**
 * Standalone OAuth flow for Codex (ChatGPT subscription) authentication.
 * Mirrors oauth-flow.ts but targets OpenAI's auth endpoints.
 *
 * Flow:
 * 1. Generate PKCE (code_verifier + code_challenge)
 * 2. Start local HTTP callback server
 * 3. Build authorize URL → caller opens in browser
 * 4. Wait for callback with auth code
 * 5. Exchange code for tokens
 * 6. Write ~/.codex/auth.json in the format codex-acp expects
 * 7. Redirect browser to success page
 */

import { createServer, type Server, type IncomingMessage, type ServerResponse } from "http";
import { request as httpsRequest } from "https";
import { randomBytes, createHash } from "crypto";
import { writeFileSync, mkdirSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import { URL } from "url";

// --- Constants (from codex binary strings analysis) ---

const CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize";
const TOKEN_URL = "https://auth.openai.com/oauth/token";
const SCOPES = "openid profile email offline_access api.connectors.read api.connectors.invoke";

// --- Error Types ---

export class CodexOAuthTokenError extends Error {
  readonly httpStatus: number;
  constructor(httpStatus: number, body: string) {
    super(`Codex token exchange failed (${httpStatus}): ${body}`);
    this.name = "CodexOAuthTokenError";
    this.httpStatus = httpStatus;
  }
}

// --- PKCE Helpers ---

function base64url(buf: Buffer): string {
  return buf.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}

function generateCodeVerifier(): string {
  return base64url(randomBytes(32));
}

function generateCodeChallenge(verifier: string): string {
  return base64url(createHash("sha256").update(verifier).digest());
}

function generateState(): string {
  return base64url(randomBytes(32));
}

// --- OAuth Result ---

export interface CodexOAuthResult {
  idToken: string;
  accessToken: string;
  refreshToken: string;
  accountId: string;
}

export interface CodexOAuthFlowHandle {
  /** URL to open in the browser */
  authUrl: string;
  /** Resolves when OAuth completes and auth.json is written */
  complete: Promise<CodexOAuthResult>;
  /** Cancel the flow */
  cancel: () => void;
}

/**
 * Start the Codex OAuth flow. Returns the auth URL and a promise that
 * resolves when the user completes auth in the browser.
 */
export async function startCodexOAuthFlow(logErr: (msg: string) => void): Promise<CodexOAuthFlowHandle> {
  const codeVerifier = generateCodeVerifier();
  const codeChallenge = generateCodeChallenge(codeVerifier);
  const state = generateState();

  const { server, port } = await startCallbackServer();
  logErr(`Codex OAuth callback server listening on port ${port}`);

  const redirectUri = `http://localhost:${port}/auth/callback`;

  const authUrl = new URL(AUTHORIZE_URL);
  authUrl.searchParams.set("response_type", "code");
  authUrl.searchParams.set("client_id", CLIENT_ID);
  authUrl.searchParams.set("redirect_uri", redirectUri);
  authUrl.searchParams.set("scope", SCOPES);
  authUrl.searchParams.set("code_challenge", codeChallenge);
  authUrl.searchParams.set("code_challenge_method", "S256");
  authUrl.searchParams.set("id_token_add_organizations", "true");
  authUrl.searchParams.set("codex_cli_simplified_flow", "true");
  authUrl.searchParams.set("state", state);
  authUrl.searchParams.set("originator", "codex_cli_rs");

  let cancelled = false;
  let cancelReject: ((err: Error) => void) | null = null;

  const complete = new Promise<CodexOAuthResult>((resolve, reject) => {
    cancelReject = reject;

    waitForCallback(server, state, logErr)
      .then(async (code) => {
        if (cancelled) return;
        logErr("Codex OAuth callback received, exchanging code for tokens...");
        const tokens = await exchangeCodeForToken(code, codeVerifier, redirectUri, logErr);
        writeAuthJson(tokens, logErr);
        resolve(tokens);
      })
      .catch((err) => {
        if (!cancelled) reject(err);
      })
      .finally(() => {
        server.close();
      });
  });

  return {
    authUrl: authUrl.toString(),
    complete,
    cancel: () => {
      cancelled = true;
      server.close();
      cancelReject?.(new Error("Codex OAuth flow cancelled"));
    },
  };
}

// --- Callback Server ---

// OpenAI only accepts these specific ports as registered redirect URIs for the Codex client.
// Match the same port selection logic used by the codex-rs login/src/server.rs.
const CALLBACK_PORT_DEFAULT = 1455;
const CALLBACK_PORT_FALLBACK = 1457;

async function startCallbackServer(): Promise<{ server: Server; port: number }> {
  for (const port of [CALLBACK_PORT_DEFAULT, CALLBACK_PORT_FALLBACK]) {
    try {
      const result = await tryBindPort(port);
      return result;
    } catch {
      // Try next port
    }
  }
  throw new Error(`Failed to bind OAuth callback server on ports ${CALLBACK_PORT_DEFAULT} or ${CALLBACK_PORT_FALLBACK}. Another process may be using them.`);
}

function tryBindPort(port: number): Promise<{ server: Server; port: number }> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", (err) => {
      server.close();
      reject(err);
    });
    server.listen(port, "127.0.0.1", () => {
      const addr = server.address();
      if (!addr || typeof addr === "string") {
        reject(new Error("Failed to get server address"));
        return;
      }
      resolve({ server, port: addr.port });
    });
  });
}

function waitForCallback(
  server: Server,
  expectedState: string,
  logErr: (msg: string) => void
): Promise<string> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error("Codex OAuth callback timed out (10 minutes)"));
      server.close();
    }, 10 * 60 * 1000);

    server.on("request", (req: IncomingMessage, res: ServerResponse) => {
      const parsed = new URL(req.url || "", "http://localhost");

      if (parsed.pathname !== "/auth/callback") {
        res.writeHead(404);
        res.end("Not Found");
        return;
      }

      const code = parsed.searchParams.get("code");
      const state = parsed.searchParams.get("state");

      if (!code) {
        res.writeHead(400);
        res.end("Authorization code not found");
        reject(new Error("No authorization code received"));
        clearTimeout(timeout);
        return;
      }

      if (state !== expectedState) {
        res.writeHead(400);
        res.end("Invalid state parameter");
        reject(new Error("Invalid state parameter"));
        clearTimeout(timeout);
        return;
      }

      logErr("Codex OAuth callback received with valid code");

      const successHTML = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Fazm — ChatGPT Connected</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif;
      display: flex; justify-content: center; align-items: center;
      height: 100vh; background: #0F0F0F; color: white;
    }
    .container { text-align: center; max-width: 420px; padding: 40px; }
    .icon {
      width: 64px; height: 64px; margin: 0 auto 24px;
      background: linear-gradient(135deg, #10A37F, #0D8A6B);
      border-radius: 16px; display: flex; align-items: center;
      justify-content: center; font-size: 28px;
    }
    h1 { font-size: 24px; font-weight: 700; margin-bottom: 8px; }
    .subtitle { color: #888; font-size: 15px; line-height: 1.5; margin-bottom: 32px; }
    .hint { color: #555; font-size: 12px; margin-top: 16px; }
  </style>
</head>
<body>
  <div class="container">
    <div class="icon">&#10003;</div>
    <h1>ChatGPT connected!</h1>
    <p class="subtitle">Your ChatGPT subscription has been linked to Fazm.<br>You can close this tab and return to the app.</p>
    <p class="hint">This tab will close automatically.</p>
  </div>
  <script>setTimeout(function() { window.close(); }, 3000);</script>
</body>
</html>`;
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(successHTML);

      clearTimeout(timeout);
      resolve(code);
    });
  });
}

// --- Token Exchange ---

interface TokenResponse {
  id_token?: string;
  access_token: string;
  refresh_token?: string;
  expires_in?: number;
  scope?: string;
}

async function exchangeCodeForToken(
  code: string,
  codeVerifier: string,
  redirectUri: string,
  logErr: (msg: string) => void
): Promise<CodexOAuthResult> {
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    redirect_uri: redirectUri,
    client_id: CLIENT_ID,
    code_verifier: codeVerifier,
  });

  const bodyStr = body.toString();
  const tokenUrl = new URL(TOKEN_URL);

  const data = await new Promise<TokenResponse>((resolve, reject) => {
    const req = httpsRequest(
      {
        hostname: tokenUrl.hostname,
        port: 443,
        path: tokenUrl.pathname,
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "Content-Length": Buffer.byteLength(bodyStr),
        },
      },
      (res) => {
        let responseBody = "";
        res.on("data", (chunk: Buffer) => {
          responseBody += chunk.toString();
        });
        res.on("end", () => {
          if (res.statusCode && res.statusCode >= 200 && res.statusCode < 300) {
            try {
              resolve(JSON.parse(responseBody));
            } catch (parseErr) {
              reject(new Error(`Failed to parse Codex token response: ${parseErr}`));
            }
          } else {
            reject(new CodexOAuthTokenError(res.statusCode ?? 0, responseBody));
          }
        });
      }
    );

    req.on("error", (err) => {
      logErr(`Codex token exchange network error: ${err.message}`);
      reject(new Error(`Codex token exchange network error: ${err.message}`));
    });

    req.write(bodyStr);
    req.end();
  });

  logErr("Codex token exchange successful");

  // Extract account_id from the access_token JWT payload
  const accountId = extractAccountId(data.access_token);

  return {
    idToken: data.id_token ?? data.access_token,
    accessToken: data.access_token,
    refreshToken: data.refresh_token ?? "",
    accountId,
  };
}

/** Extract chatgpt_account_id from the access token JWT payload */
function extractAccountId(accessToken: string): string {
  try {
    const parts = accessToken.split(".");
    if (parts.length < 2) return "";
    const payload = JSON.parse(Buffer.from(parts[1], "base64").toString("utf8")) as Record<string, unknown>;
    const auth = payload["https://api.openai.com/auth"] as Record<string, unknown> | undefined;
    return (auth?.["chatgpt_account_id"] as string | undefined) ?? "";
  } catch {
    return "";
  }
}

// --- Write auth.json ---

function writeAuthJson(tokens: CodexOAuthResult, logErr: (msg: string) => void): void {
  const codexDir = join(homedir(), ".codex");
  try {
    mkdirSync(codexDir, { recursive: true });
  } catch {
    // ignore if already exists
  }

  const authJson = {
    auth_mode: "chatgpt",
    OPENAI_API_KEY: null,
    tokens: {
      id_token: tokens.idToken,
      access_token: tokens.accessToken,
      refresh_token: tokens.refreshToken,
      account_id: tokens.accountId,
    },
    last_refresh: new Date().toISOString(),
  };

  const authPath = join(codexDir, "auth.json");
  writeFileSync(authPath, JSON.stringify(authJson, null, 2), { mode: 0o600 });
  logErr(`Codex auth.json written to ${authPath}`);
}
