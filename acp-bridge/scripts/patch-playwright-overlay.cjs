#!/usr/bin/env node
/**
 * Patches playwright-core's coreBundle.js for two Fazm features:
 *   1. Injects the Fazm browser overlay on every page load (extension mode).
 *   2. Wraps BrowserBackend.callTool() so every tool call pings the overlay
 *      (window.__fazmPing()) — resets its 5s hide timer / fades it back in.
 *
 * WHY THIS PATCH EXISTS:
 * Playwright's addInitScript() does NOT work on CDP-connected contexts
 * (which is what extension mode uses via connectOverCDP). So we can't use
 * the built-in --init-script flag. Instead, this patch hooks into the
 * extension-mode `create()` callback to register page 'load'/'domcontentloaded'
 * event listeners that call page.evaluate() with the overlay script, plus
 * immediate injection for already-loaded pages (the common case at CDP attach).
 *
 * VERSION HISTORY:
 * - v1 (sentinel `_fazmOverlayScript`): overlay injection only, no auto-hide.
 * - v2 (sentinel `_fazmPingHook`): adds callTool wrap → pings overlay so it
 *   auto-fades after 5s of no tool activity and reappears on the next call.
 *
 * The patch is upgrade-aware: if a v1 patch is already applied, it rewrites
 * the v1 NEW_BLOCK with the v2 version. If no patch is applied, it transforms
 * the original OLD_BLOCK.
 *
 * WHEN PLAYWRIGHT UPDATES:
 * If the `browserContext` assignment or `return new BrowserBackend(...)` line
 * changes shape, the string match below will fail. To fix:
 * 1. Open node_modules/playwright-core/lib/coreBundle.js
 * 2. Find the CLI factory `create:` callback (search for "browserContext = config.browser.isolated")
 * 3. Update OLD_BLOCK below to match the new code
 * 4. Re-run: node scripts/patch-playwright-overlay.cjs
 * 5. Verify with: grep _fazmPingHook node_modules/playwright-core/lib/coreBundle.js
 *
 * RELATED FILES:
 * - acp-bridge/browser-overlay-init.js — the overlay UI + ping handler
 * - acp-bridge/package.json — "postinstall" hook
 * - codemagic.yaml — hard-checks `_fazmPingHook` is present in coreBundle.js
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

// Already at v2 — nothing to do.
if (code.includes("_fazmPingHook")) {
  console.log("[patch-overlay] Already patched (v2), skipping");
  process.exit(0);
}

// Original Playwright CLI factory create() block (unpatched state).
const OLD_BLOCK =
  '        const browserContext = config.browser.isolated ? await browser.newContext(config.browser.contextOptions) : browser.contexts()[0];\n' +
  '        return new BrowserBackend(config, browserContext, tools);\n' +
  '      },';

// v1 patched block — overlay injection only, used to detect a stale v1 patch
// and upgrade it in place to v2.
const V1_NEW_BLOCK =
  '        const browserContext = config.browser.isolated ? await browser.newContext(config.browser.contextOptions) : browser.contexts()[0];\n' +
  '        // Fazm: inject overlay on every page in extension mode.\n' +
  '        // addInitScript does NOT work on CDP-connected contexts (extension mode\n' +
  '        // uses connectOverCDP), so we hook page load events + inject immediately\n' +
  '        // into already-loaded pages. Guard with config.extension so this is a\n' +
  '        // no-op in isolated/persistent/CDP modes.\n' +
  '        if (config.extension) {\n' +
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
  '        }\n' +
  '        return new BrowserBackend(config, browserContext, tools);\n' +
  '      },';

// v2 patched block — overlay injection + tool-call ping hook (_fazmPingHook).
// After every BrowserBackend.callTool() invocation, we ping each page so the
// overlay resets its 5s auto-hide timer / fades back in if currently faded out.
const V2_NEW_BLOCK =
  '        const browserContext = config.browser.isolated ? await browser.newContext(config.browser.contextOptions) : browser.contexts()[0];\n' +
  '        // Fazm: extension-mode overlay + tool-call ping hook (_fazmPingHook).\n' +
  '        // addInitScript does NOT work on CDP-connected contexts (extension mode\n' +
  '        // uses connectOverCDP), so we hook page load events + inject immediately\n' +
  '        // into already-loaded pages. We then wrap BrowserBackend.callTool so each\n' +
  '        // tool execution calls window.__fazmPing() on every page (resets the 5s\n' +
  '        // overlay-hide timer and fades it back in if currently faded out).\n' +
  '        // Guard with config.extension so this is a no-op in isolated/persistent modes.\n' +
  '        let _fazmPingAllPages = () => {};\n' +
  '        if (config.extension) {\n' +
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
  '              _fazmPingAllPages = () => {\n' +
  '                try {\n' +
  '                  for (const p of browserContext.pages()) {\n' +
  '                    p.evaluate(() => { try { if (typeof window.__fazmPing === "function") window.__fazmPing(); } catch (e) {} }).catch(() => {});\n' +
  '                  }\n' +
  '                } catch (e) {}\n' +
  '              };\n' +
  '            }\n' +
  '          } catch (e) { /* overlay is optional, never break Playwright */ }\n' +
  '        }\n' +
  '        const _fazmBackend = new BrowserBackend(config, browserContext, tools);\n' +
  '        try {\n' +
  '          const _fazmOrigCallTool = _fazmBackend.callTool.bind(_fazmBackend);\n' +
  '          _fazmBackend.callTool = async function (name, rawArguments, signal) {\n' +
  '            try {\n' +
  '              return await _fazmOrigCallTool(name, rawArguments, signal);\n' +
  '            } finally {\n' +
  '              _fazmPingAllPages();\n' +
  '            }\n' +
  '          };\n' +
  '        } catch (e) { /* _fazmPingHook is optional, never break Playwright */ }\n' +
  '        return _fazmBackend;\n' +
  '      },';

let patchedFrom;
if (code.includes("_fazmOverlayScript") && code.includes(V1_NEW_BLOCK)) {
  // Upgrade v1 → v2 in place.
  code = code.replace(V1_NEW_BLOCK, V2_NEW_BLOCK);
  patchedFrom = "v1 (upgrade)";
} else if (code.includes(OLD_BLOCK)) {
  // Fresh install.
  code = code.replace(OLD_BLOCK, V2_NEW_BLOCK);
  patchedFrom = "unpatched";
} else {
  console.error("[patch-overlay] FATAL: neither OLD_BLOCK nor V1_NEW_BLOCK matched coreBundle.js.");
  console.error("[patch-overlay] Playwright MCP internals likely changed. See comments at top of this file.");
  if (process.env.FAZM_ALLOW_MISSING_OVERLAY === "1") {
    console.error("[patch-overlay] FAZM_ALLOW_MISSING_OVERLAY=1 set — continuing without patch.");
    process.exit(0);
  }
  process.exit(1);
}

if (!code.includes("_fazmPingHook")) {
  console.error("[patch-overlay] FATAL: replacement did not insert v2 sentinel. Refusing to write file.");
  process.exit(1);
}

fs.writeFileSync(targetFile, code);
console.log("[patch-overlay] Successfully patched coreBundle.js (from " + patchedFrom + " → v2)");
