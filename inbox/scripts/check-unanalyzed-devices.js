#!/usr/bin/env node

/**
 * Find the next unanalyzed session recording device to process.
 *
 * Uses the analytics orchestrate API to:
 *   1. Get all devices and their analysis status
 *   2. Find devices with unanalyzed chunks (between 1 and 100)
 *   3. Pick the one with the most unanalyzed chunks (prioritize users with more activity)
 *   4. Resolve Firebase UID to email via Firebase Admin SDK
 *
 * Also checks the session_replay_investigations table to skip devices
 * that have already been investigated by this pipeline.
 *
 * Returns JSON: { deviceId, email, displayName, totalChunks, unanalyzedChunks, lastActivity }
 * Returns "null" if nothing to process.
 */

const https = require('https');
const admin = require('firebase-admin');
const { neon } = require('@neondatabase/serverless');

const ORCHESTRATE_URL = 'https://omi-analytics.vercel.app/api/session-recordings/orchestrate';
const CRON_SECRET = process.env.CRON_SECRET || '2d17eac34d9fdc61e555e972089a17c9';
const MAX_CHUNKS = 60;
const MIN_CHUNKS = 5; // Skip devices with very few chunks (not enough data)

function fetchJSON(url, options = {}) {
  return new Promise((resolve, reject) => {
    const urlObj = new URL(url);
    const reqOptions = {
      hostname: urlObj.hostname,
      path: urlObj.pathname + urlObj.search,
      method: options.method || 'GET',
      headers: {
        'Authorization': `Bearer ${CRON_SECRET}`,
        'Content-Type': 'application/json',
        ...options.headers,
      },
    };
    const req = https.request(reqOptions, (res) => {
      let data = '';
      res.on('data', (chunk) => data += chunk);
      res.on('end', () => {
        try { resolve(JSON.parse(data)); }
        catch (e) { reject(new Error(`Invalid JSON: ${data.slice(0, 200)}`)); }
      });
    });
    req.on('error', reject);
    if (options.body) req.write(options.body);
    req.end();
  });
}

function initFirebase() {
  const serviceAccountJson = process.env.FIREBASE_SERVICE_ACCOUNT_JSON;
  if (!serviceAccountJson) {
    console.error('FIREBASE_SERVICE_ACCOUNT_JSON not set');
    return null;
  }
  try {
    const serviceAccount = JSON.parse(serviceAccountJson);
    if (!admin.apps.length) {
      admin.initializeApp({
        credential: admin.credential.cert(serviceAccount),
        projectId: 'fazm-prod',
      });
    }
    return admin.auth();
  } catch (err) {
    console.error('Firebase init error:', err.message);
    return null;
  }
}

async function resolveEmail(auth, deviceId) {
  if (!auth) return { email: null, displayName: null };
  // Firebase UIDs are alphanumeric without dashes
  if (deviceId.includes('-') || deviceId === 'unknown') {
    return { email: null, displayName: null };
  }
  try {
    const user = await auth.getUser(deviceId);
    return {
      email: user.email || null,
      displayName: user.displayName || null,
    };
  } catch (err) {
    return { email: null, displayName: null };
  }
}

async function getInvestigatedDevices() {
  const dbUrl = process.env.DATABASE_URL;
  if (!dbUrl) return new Set();
  try {
    const sql = neon(dbUrl);
    const result = await sql.query(
      `SELECT device_id FROM session_replay_investigations WHERE investigated_at IS NOT NULL`
    );
    const rows = result.rows || result;
    return new Set(rows.map(r => r.device_id));
  } catch (err) {
    // Table might not exist yet; that's fine
    if (err.message && err.message.includes('does not exist')) return new Set();
    console.error('DB query error:', err.message);
    return new Set();
  }
}

async function main() {
  // Get all devices with their analysis status
  const status = await fetchJSON(`${ORCHESTRATE_URL}?action=status`);

  if (!status.devices || status.devices.length === 0) {
    console.log('null');
    return;
  }

  // Get already-investigated devices
  const investigated = await getInvestigatedDevices();

  // Filter to devices that:
  // 1. Have unanalyzed chunks (need Gemini analysis first) OR have analyses with issues
  // 2. Haven't been investigated by this pipeline yet
  // 3. Have at least MIN_CHUNKS total, and ≤MAX_CHUNKS unanalyzed
  // 4. Are not "unknown"
  const candidates = status.devices.filter(d => {
    if (d.deviceId === 'unknown') return false;
    if (d.deviceId.includes('-')) return false; // Not a Firebase UID
    if (investigated.has(d.deviceId)) return false;
    if (d.totalChunks < MIN_CHUNKS) return false;
    if (d.unanalyzedChunks > MAX_CHUNKS) return false; // Cap on unanalyzed, not total
    return true;
  });

  if (candidates.length === 0) {
    console.log('null');
    return;
  }

  // Priority: devices with analyses that have issues > devices needing analysis
  // Among those, pick the one with most activity (most chunks)
  candidates.sort((a, b) => {
    // Prefer devices that already have analyses with issues
    if (a.withIssues > 0 && b.withIssues === 0) return -1;
    if (b.withIssues > 0 && a.withIssues === 0) return 1;
    // Then prefer more chunks (more data to investigate)
    return b.totalChunks - a.totalChunks;
  });

  const device = candidates[0];

  // Resolve Firebase UID to email
  const auth = initFirebase();
  const { email, displayName } = await resolveEmail(auth, device.deviceId);

  const result = {
    deviceId: device.deviceId,
    email,
    displayName,
    totalChunks: device.totalChunks,
    analyzedChunks: device.analyzedChunks,
    unanalyzedChunks: device.unanalyzedChunks,
    totalAnalyses: device.totalAnalyses,
    withIssues: device.withIssues,
    noIssues: device.noIssues,
    lastActivity: device.lastActivity,
    needsGeminiAnalysis: device.unanalyzedChunks > 0,
  };

  console.log(JSON.stringify(result));
}

main().catch(err => {
  console.error('Error:', err.message);
  process.exit(1);
});
