#!/usr/bin/env node
/**
 * Patches playwright-core's coreBundle.js to inject the Fazm browser overlay
 * on every page load when running in extension mode (CDP-connected pages).
 *
 * WHY THIS PATCH EXISTS:
 * Playwright's addInitScript() does NOT work on CDP-connected contexts
 * (which is what extension mode uses via connectOverCDP). So we can't use
 * the built-in --init-script flag. Instead, this patch hooks into the
 * extension-mode `create()` callback to register page 'load'/'domcontentloaded'
 * event listeners that call page.evaluate() with the overlay script, plus
 * immediate injection for already-loaded pages (the common case at CDP attach).
 *
 * HOW IT WORKS:
 * The patched `create()` callback receives the extension browser, takes
 * `browser.contexts()[0]`, and (before constructing BrowserBackend) sets up
 * the listeners and injects on existing pages.
 *
 * WHEN PLAYWRIGHT UPDATES:
 * @playwright/mcp 0.0.71 collapsed everything into playwright-core's
 * coreBundle.js. If the upstream `if (config.extension) { ... }` block
 * changes shape, the string match below will fail. To fix:
 * 1. Open node_modules/playwright-core/lib/coreBundle.js
 * 2. Find the `if (config.extension) {` block; locate the `create:` callback
 *    that does `browser.contexts()[0]` then `new BrowserBackend(...)`
 * 3. Update OLD_BLOCK below to match the new code
 * 4. Re-run: node scripts/patch-playwright-overlay.cjs
 * 5. Verify with: grep _fazmOverlayScript node_modules/playwright-core/lib/coreBundle.js
 *
 * RELATED FILES:
 * - acp-bridge/browser-overlay-init.js — the overlay UI
 * - acp-bridge/package.json — "postinstall" hook
 * - codemagic.yaml — hard-checks _fazmOverlayScript is present in coreBundle.js
 *
 * Run automatically via npm postinstall. Safe to run repeatedly (idempotent).
 */
const fs = require("fs");
const path = require("path");

const targetFile = path.join(
  __dirname,
  "..",
  "node_modules",
  "playwright-core",
  "lib",
  "coreBundle.js"
);

if (!fs.existsSync(targetFile)) {
  console.log("[patch-overlay] coreBundle.js not found, skipping");
  process.exit(0);
}

let code = fs.readFileSync(targetFile, "utf-8");

if (code.includes("_fazmOverlayScript")) {
  console.log("[patch-overlay] Already patched, skipping");
  process.exit(0);
}

// The extension-mode block in @playwright/mcp 0.0.71 (bundled into
// playwright-core/lib/coreBundle.js). Indentation matters — this is the
// exact bundled output. If upstream reformats this, update OLD_BLOCK.
const OLD_BLOCK =
  '        create: async (clientInfo) => {\n' +
  '          const browser = await createBrowser(config, clientInfo);\n' +
  '          const browserContext = browser.contexts()[0];\n' +
  '          return new BrowserBackend(config, browserContext, tools);\n' +
  '        },';

const NEW_BLOCK =
  '        create: async (clientInfo) => {\n' +
  '          const browser = await createBrowser(config, clientInfo);\n' +
  '          const browserContext = browser.contexts()[0];\n' +
  '          // Fazm: inject overlay on every page in extension mode.\n' +
  '          // addInitScript does NOT work on CDP-connected contexts, so we use\n' +
  '          // page events + immediate injection for already-loaded pages.\n' +
  '          try {\n' +
  '            const _fazmFs = require("fs");\n' +
  '            const _fazmPath = require("path");\n' +
  '            const _fazmOverlayPath = _fazmPath.join(__dirname, "..", "..", "..", "browser-overlay-init.js");\n' +
  '            if (_fazmFs.existsSync(_fazmOverlayPath)) {\n' +
  '              const _fazmOverlayScript = _fazmFs.readFileSync(_fazmOverlayPath, "utf-8");\n' +
  '              const _injectOverlay = async (p) => { try { await p.evaluate(_fazmOverlayScript); } catch (e) {} };\n' +
  '              const _setupPage = (p) => {\n' +
  '                p.on("load", () => _injectOverlay(p));\n' +
  '                p.on("domcontentloaded", () => _injectOverlay(p));\n' +
  '                _injectOverlay(p);\n' +
  '              };\n' +
  '              for (const p of browserContext.pages()) _setupPage(p);\n' +
  '              browserContext.on("page", (p) => _setupPage(p));\n' +
  '            }\n' +
  '          } catch (e) { /* overlay is optional, never break Playwright */ }\n' +
  '          return new BrowserBackend(config, browserContext, tools);\n' +
  '        },';

if (!code.includes(OLD_BLOCK)) {
  console.error("[patch-overlay] FATAL: extension-mode create() block not found in coreBundle.js.");
  console.error("[patch-overlay] Playwright MCP internals likely changed. See comments at top of this file.");
  if (process.env.FAZM_ALLOW_MISSING_OVERLAY === "1") {
    console.error("[patch-overlay] FAZM_ALLOW_MISSING_OVERLAY=1 set — continuing without patch.");
    process.exit(0);
  }
  process.exit(1);
}

code = code.replace(OLD_BLOCK, NEW_BLOCK);

if (!code.includes("_fazmOverlayScript")) {
  console.error("[patch-overlay] FATAL: replacement did not insert sentinel. Refusing to write file.");
  process.exit(1);
}

fs.writeFileSync(targetFile, code);
console.log("[patch-overlay] Successfully patched coreBundle.js");
