/**
 * Fazm Browser Overlay — Init Page Script (JS version)
 *
 * Used with Playwright MCP --init-page flag.
 * Registers addInitScript on the browser context so the overlay
 * persists across all page navigations, then injects on the current page.
 */
const { readFileSync } = require('fs');
const { join } = require('path');

const overlayScript = readFileSync(join(__dirname, 'browser-overlay-init.js'), 'utf-8');

module.exports = async function ({ page }) {
  console.error('[fazm-overlay] init-page script running, page URL:', page.url());
  // Register for all future navigations
  await page.context().addInitScript(overlayScript);
  console.error('[fazm-overlay] addInitScript registered');
  // Inject on current page immediately
  await page.evaluate(overlayScript).catch((e) => {
    console.error('[fazm-overlay] evaluate error:', e.message);
  });
  console.error('[fazm-overlay] evaluate completed');
};
