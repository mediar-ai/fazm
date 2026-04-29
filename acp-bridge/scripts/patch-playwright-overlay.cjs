#!/usr/bin/env node
/**
 * Patches Playwright MCP's extensionContextFactory.js to inject the Fazm
 * browser overlay on every page load when running in extension mode.
 *
 * WHY THIS PATCH EXISTS:
 * Playwright's addInitScript() does NOT work on CDP-connected contexts
 * (which is what extension mode uses via connectOverCDP). So we can't use
 * the built-in --init-script flag. Instead, this patch hooks into
 * createContext() to register page 'load'/'domcontentloaded' event listeners
 * that call page.evaluate() with the overlay script.
 *
 * HOW IT WORKS:
 * 1. Adds require("path") and require("fs") imports
 * 2. Loads browser-overlay-init.js from the acp-bridge root at module init time
 * 3. Patches createContext() to set up page event listeners that inject the overlay
 *
 * WHEN PLAYWRIGHT UPDATES:
 * If the Playwright MCP package updates and the code structure of
 * extensionContextFactory.js changes, the string replacements below may fail
 * silently (the overlay just won't appear — nothing breaks). To fix:
 * 1. Look at the new extensionContextFactory.js in node_modules
 * 2. Update the string patterns below to match the new code
 * 3. Run: node scripts/patch-playwright-overlay.cjs
 * 4. Verify with: grep _fazmOverlayScript node_modules/playwright/lib/mcp/extension/extensionContextFactory.js
 *
 * RELATED FILES:
 * - acp-bridge/browser-overlay-init.js — the overlay UI (CSS animations, DOM elements)
 * - acp-bridge/package.json — "postinstall" hook that runs this script
 * - build.sh / run.sh — copy browser-overlay-init.js into the app bundle
 *
 * Run automatically via npm postinstall. Safe to run manually at any time.
 */
const fs = require("fs");
const path = require("path");

const targetFile = path.join(
  __dirname,
  "..",
  "node_modules",
  "playwright",
  "lib",
  "mcp",
  "extension",
  "extensionContextFactory.js"
);

if (!fs.existsSync(targetFile)) {
  console.log("[patch-overlay] extensionContextFactory.js not found, skipping");
  process.exit(0);
}

let code = fs.readFileSync(targetFile, "utf-8");

// Migration: if the old patch (without immediate injection on already-loaded pages)
// is present, upgrade it in place. The old _setupPage only registered load/
// domcontentloaded listeners, which don't fire for pages already loaded at CDP-attach
// time, so overlay never appeared in extension mode unless the agent navigated.
const OLD_SETUP = 'const _setupPage = (p) => { p.on("load", () => _injectOverlay(p)); p.on("domcontentloaded", () => _injectOverlay(p)); };';
const NEW_SETUP = 'const _setupPage = (p) => { p.on("load", () => _injectOverlay(p)); p.on("domcontentloaded", () => _injectOverlay(p)); _injectOverlay(p); };';
if (code.includes(OLD_SETUP)) {
  code = code.replace(OLD_SETUP, NEW_SETUP);
  fs.writeFileSync(targetFile, code);
  console.log("[patch-overlay] Upgraded existing patch to inject on already-loaded pages");
  process.exit(0);
}

// Already fully patched?
if (code.includes("_fazmOverlayScript")) {
  console.log("[patch-overlay] Already patched, skipping");
  process.exit(0);
}

// --- Step 1: Add path/fs requires (needed to load the overlay script from disk) ---
if (!code.includes('require("path")')) {
  code = code.replace(
    'var import_cdpRelay = require("./cdpRelay");',
    'var import_cdpRelay = require("./cdpRelay");\nvar import_path = require("path");\nvar import_fs = require("fs");'
  );
}

// --- Step 2: Load the overlay script at module init time ---
// The path goes 5 levels up from extensionContextFactory.js to reach acp-bridge root:
//   extension/ -> mcp/ -> lib/ -> playwright/ -> node_modules/ -> acp-bridge/
const overlayLoader = `
// Fazm: load overlay init script for browser injection
let _fazmOverlayScript = null;
try {
  const overlayPath = import_path.join(__dirname, "..", "..", "..", "..", "..", "browser-overlay-init.js");
  if (import_fs.existsSync(overlayPath)) {
    _fazmOverlayScript = import_fs.readFileSync(overlayPath, "utf-8");
  }
} catch (e) {
  // Overlay is optional — don't break Playwright MCP if loading fails
}
`;

code = code.replace(
  'const debugLogger = (0, import_utilsBundle.debug)("pw:mcp:relay");',
  'const debugLogger = (0, import_utilsBundle.debug)("pw:mcp:relay");\n' + overlayLoader
);

// --- Step 3: Patch createContext() to inject overlay via page event listeners ---
// The original code returns browser.contexts()[0] inline. We extract it to a variable
// so we can set up event listeners before returning.
code = code.replace(
  `async createContext(clientInfo, abortSignal, options) {
    const browser = await this._obtainBrowser(clientInfo, abortSignal, options?.toolName);
    return {
      browserContext: browser.contexts()[0],`,
  `async createContext(clientInfo, abortSignal, options) {
    const browser = await this._obtainBrowser(clientInfo, abortSignal, options?.toolName);
    const browserContext = browser.contexts()[0];
    // Fazm: inject overlay on every page load via event listeners AND immediately on
    // already-loaded pages (load/domcontentloaded won't re-fire for pages whose load
    // completed before the CDP attach — in extension mode this is the common case).
    // addInitScript does NOT work on CDP-connected contexts, so we use page events.
    if (_fazmOverlayScript && browserContext) {
      const _injectOverlay = async (p) => { try { await p.evaluate(_fazmOverlayScript); } catch (e) {} };
      const _setupPage = (p) => {
        p.on("load", () => _injectOverlay(p));
        p.on("domcontentloaded", () => _injectOverlay(p));
        _injectOverlay(p);
      };
      for (const p of browserContext.pages()) _setupPage(p);
      browserContext.on("page", (p) => _setupPage(p));
    }
    return {
      browserContext,`
);

// Verify the patch was applied
if (!code.includes("_fazmOverlayScript")) {
  console.error("[patch-overlay] FATAL: Patch failed to apply — Playwright MCP internals likely changed.");
  console.error("[patch-overlay] The overlay won't appear in shipped builds. See comments in this file for how to fix.");
  // In CI we MUST fail so a broken overlay never ships. In local dev we also fail
  // so the developer notices immediately instead of debugging a missing overlay later.
  // Set FAZM_ALLOW_MISSING_OVERLAY=1 to bypass (only for emergency local debugging).
  if (process.env.FAZM_ALLOW_MISSING_OVERLAY === "1") {
    console.error("[patch-overlay] FAZM_ALLOW_MISSING_OVERLAY=1 set — continuing without patch (overlay will be missing).");
    process.exit(0);
  }
  process.exit(1);
}

fs.writeFileSync(targetFile, code);
console.log("[patch-overlay] Successfully patched extensionContextFactory.js");
