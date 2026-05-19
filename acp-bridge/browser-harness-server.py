#!/usr/bin/env python3
"""
browser-harness MCP server (Fazm-bundled edition).

Wraps the browser-harness Python package behind an MCP stdio server so the Fazm
agent (or any Claude session) can drive direct CDP browser control via a
managed Chrome instance with a persistent profile.

Bundle layout (paths are resolved relative to this file at runtime):
  Fazm.app/Contents/Resources/
    browser-harness/
      server.py            <- this file
      .venv/bin/browser-harness   <- the harness CLI
      .venv/bin/python3
      browser-harness-src/        <- source copy used at bundle time
    ai-browser-profile/
      .venv/bin/python3           <- used by bh_seed_cookies / bh_seed_localstorage
      ai_browser_profile/         <- cookies.py / localstorage.py live here

User-writable data lives under ~/.fazm/browser-harness/ (profile, pid, logs).
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

from mcp.server.fastmcp import FastMCP

# --- Bundle / data paths ---

SERVER_DIR = Path(__file__).resolve().parent
BUNDLE_RESOURCES_DIR = SERVER_DIR.parent  # .../Fazm.app/Contents/Resources

FAZM_DATA = Path.home() / ".fazm" / "browser-harness"
PROFILE_DIR = FAZM_DATA / "profile"
PID_FILE = FAZM_DATA / "chrome.pid"
LOG_FILE = FAZM_DATA / "chrome.log"
MCP_LOG_FILE = FAZM_DATA / "mcp.log"

# Port for our managed Chrome's remote debugging endpoint. 9655 to avoid
# collision with playwright-extension (9222), the user's own Chrome, and the
# Claude-Code-side browser-harness MCP which also defaults to 9555.
PORT = int(os.environ.get("FAZM_BH_PORT", "9655"))
CDP_URL = f"http://127.0.0.1:{PORT}"

CHROME_BIN = os.environ.get(
    "FAZM_BH_CHROME_BIN",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
)

# browser-harness CLI inside our bundled venv
BROWSER_HARNESS_BIN = str(SERVER_DIR / ".venv" / "bin" / "browser-harness")

# ai-browser-profile bundled sibling (used by bh_seed_cookies/localstorage)
ABP_DIR = BUNDLE_RESOURCES_DIR / "ai-browser-profile"
ABP_PYTHON = ABP_DIR / ".venv" / "bin" / "python3"

# Default exec timeout for a single tool call (seconds).
EXEC_TIMEOUT_SEC = int(os.environ.get("FAZM_BH_EXEC_TIMEOUT", "300"))

# --- Logging ---

def _log(msg: str) -> None:
    try:
        MCP_LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with MCP_LOG_FILE.open("a") as f:
            f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}\n")
    except Exception:
        pass


# --- Chrome lifecycle ---

def _port_open(port: int) -> bool:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(0.5)
    try:
        s.connect(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def _cdp_alive() -> bool:
    if not _port_open(PORT):
        return False
    try:
        with urllib.request.urlopen(f"{CDP_URL}/json/version", timeout=1.5) as r:
            return r.status == 200
    except (urllib.error.URLError, TimeoutError, OSError):
        return False


def _read_pid() -> int | None:
    try:
        return int(PID_FILE.read_text().strip())
    except (FileNotFoundError, ValueError):
        return None


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def ensure_chrome() -> dict:
    """Make sure our managed Chrome is running on PORT. Idempotent."""
    if _cdp_alive():
        return {"status": "already_running", "pid": _read_pid(), "cdp": CDP_URL}

    if not Path(CHROME_BIN).exists():
        return {
            "status": "chrome_missing",
            "error": (
                f"Google Chrome not found at {CHROME_BIN}. Install Chrome "
                "from https://www.google.com/chrome/ to use Fazm's managed browser."
            ),
        }

    PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)

    # Clean up stale daemon socket so first browser-harness call doesn't
    # try to talk to a dead daemon from a previous Chrome instance.
    for stale in ("/tmp/bu-default.sock", "/tmp/bu-default.pid"):
        try:
            os.unlink(stale)
        except FileNotFoundError:
            pass

    pid = _read_pid()
    if pid and _pid_alive(pid):
        _log(f"stale pid {pid} alive but CDP dead; killing")
        try:
            os.kill(pid, 9)
        except OSError:
            pass
        time.sleep(0.5)

    cmd = [
        CHROME_BIN,
        f"--remote-debugging-port={PORT}",
        f"--user-data-dir={PROFILE_DIR}",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-features=ChromeWhatsNewUI",
        # Open a real tab so CDP has something to attach to immediately.
        "about:blank",
    ]
    # Optional window placement overrides
    if "FAZM_BH_WINDOW_POS" in os.environ:
        cmd.insert(-1, f"--window-position={os.environ['FAZM_BH_WINDOW_POS']}")
    if "FAZM_BH_WINDOW_SIZE" in os.environ:
        cmd.insert(-1, f"--window-size={os.environ['FAZM_BH_WINDOW_SIZE']}")

    log_fh = LOG_FILE.open("ab")
    proc = subprocess.Popen(
        cmd,
        stdout=log_fh,
        stderr=log_fh,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )
    PID_FILE.write_text(str(proc.pid))
    _log(f"launched Chrome pid={proc.pid} port={PORT} profile={PROFILE_DIR}")

    deadline = time.time() + 15
    while time.time() < deadline:
        if _cdp_alive():
            return {"status": "started", "pid": proc.pid, "cdp": CDP_URL}
        time.sleep(0.3)

    return {
        "status": "launch_timeout",
        "pid": proc.pid,
        "cdp": CDP_URL,
        "log": str(LOG_FILE),
    }


def stop_chrome() -> dict:
    """Kill the managed Chrome instance, if any."""
    pid = _read_pid()
    if pid and _pid_alive(pid):
        try:
            os.kill(pid, 15)
            time.sleep(0.6)
            if _pid_alive(pid):
                os.kill(pid, 9)
        except OSError as e:
            return {"status": "error", "error": str(e), "pid": pid}
    try:
        PID_FILE.unlink()
    except FileNotFoundError:
        pass
    for stale in ("/tmp/bu-default.sock", "/tmp/bu-default.pid"):
        try:
            os.unlink(stale)
        except FileNotFoundError:
            pass
    return {"status": "stopped", "pid": pid}


# --- browser-harness exec wrapper ---

def _run_harness(script: str, timeout: int = EXEC_TIMEOUT_SEC) -> dict:
    if not Path(BROWSER_HARNESS_BIN).exists():
        return {
            "ok": False,
            "error": (
                f"browser-harness CLI not found at {BROWSER_HARNESS_BIN}. "
                "The Fazm bundle is missing browser-harness; reinstall the app."
            ),
        }

    chrome_result = ensure_chrome()
    if chrome_result.get("status") == "chrome_missing":
        return {"ok": False, "error": chrome_result.get("error")}

    env = os.environ.copy()
    env["BU_CDP_URL"] = CDP_URL
    # Make sure our bundled venv's bin dir is first on PATH.
    env["PATH"] = f"{SERVER_DIR / '.venv' / 'bin'}:" + env.get("PATH", "")

    try:
        proc = subprocess.run(
            [BROWSER_HARNESS_BIN, "-c", script],
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as e:
        return {
            "ok": False,
            "error": f"browser-harness timed out after {timeout}s",
            "stdout": (e.stdout or "") if isinstance(e.stdout, str) else "",
            "stderr": (e.stderr or "") if isinstance(e.stderr, str) else "",
        }

    return {
        "ok": proc.returncode == 0,
        "returncode": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
    }


# --- MCP server ---

mcp = FastMCP(
    "browser-harness",
    instructions=(
        "Direct CDP browser control via a Fazm-managed Chrome instance with a "
        "persistent profile at ~/.fazm/browser-harness/profile (cookies and "
        "sessions persist across Fazm restarts). Separate from the user's "
        "normal Chrome. "
        "Primary tool: bh_run(script) — runs arbitrary Python with the harness "
        "helpers pre-imported (new_tab, goto_url, page_info, capture_screenshot, "
        "click_at_xy, js, type_text, press_key, fill_input, scroll, "
        "wait_for_load, wait_for_element, ensure_real_tab, list_tabs, "
        "switch_tab, http_get, cdp, etc.). "
        "Workflow: capture_screenshot -> click_at_xy(x,y) -> re-screenshot. "
        "Use bh_seed_cookies / bh_seed_localstorage to import sessions from "
        "the user's real Chrome/Arc/Brave/Edge profiles."
    ),
)


@mcp.tool()
def bh_run(script: str, timeout: int = EXEC_TIMEOUT_SEC) -> str:
    """Execute a Python script inside browser-harness.

    The script runs with all browser-harness helpers pre-imported (new_tab,
    goto_url, page_info, capture_screenshot, click_at_xy, js, type_text,
    press_key, fill_input, scroll, wait_for_load, wait_for_element,
    ensure_real_tab, list_tabs, switch_tab, http_get, cdp, etc.).

    The first navigation in a fresh tab should be new_tab(url), not
    goto_url(url) — goto runs in the user's currently-focused tab and
    clobbers whatever is loaded there.

    Returns a JSON string with: ok, returncode, stdout, stderr.
    """
    result = _run_harness(script, timeout=timeout)
    return json.dumps(result, indent=2)


@mcp.tool()
def bh_status() -> str:
    """Report whether the managed Chrome is alive and where it lives."""
    pid = _read_pid()
    return json.dumps(
        {
            "cdp_url": CDP_URL,
            "cdp_alive": _cdp_alive(),
            "chrome_pid": pid,
            "chrome_alive": pid is not None and _pid_alive(pid),
            "profile_dir": str(PROFILE_DIR),
            "log_file": str(LOG_FILE),
            "harness_bin": BROWSER_HARNESS_BIN,
            "abp_python": str(ABP_PYTHON),
            "abp_available": ABP_PYTHON.exists(),
        },
        indent=2,
    )


@mcp.tool()
def bh_start() -> str:
    """Start the managed Chrome (idempotent). Normally bh_run handles this."""
    return json.dumps(ensure_chrome(), indent=2)


@mcp.tool()
def bh_stop() -> str:
    """Kill the managed Chrome instance. Cookies/profile data persist on disk."""
    return json.dumps(stop_chrome(), indent=2)


@mcp.tool()
def bh_seed_cookies(source: str = "chrome:Default", domains: str | None = None) -> str:
    """Import cookies from a local browser profile into the managed Chrome.

    Shells out to ai_browser_profile.cookies in the bundled ai-browser-profile
    venv. Reads cookies from the source profile via macOS Keychain + AES-CBC
    decrypt, then injects via CDP Storage.setCookies.

    Args:
        source: 'browser:profile' spec, e.g. 'chrome:Profile 1', 'arc:Default'.
                Browsers: chrome, arc, brave, edge.
        domains: comma-separated host_key substrings to filter
                 (e.g. 'github.com,linear.app'). None = ALL cookies.
                 Highly recommended to filter — cookies are auth secrets.

    Returns JSON with ok, returncode, stdout (counts only), stderr.
    """
    if not ABP_PYTHON.exists():
        return json.dumps(
            {"ok": False, "error": f"ai-browser-profile not bundled at {ABP_PYTHON}"},
            indent=2,
        )

    chrome_result = ensure_chrome()
    if chrome_result.get("status") == "chrome_missing":
        return json.dumps({"ok": False, "error": chrome_result.get("error")}, indent=2)

    cmd = [
        str(ABP_PYTHON),
        "-m",
        "ai_browser_profile.cookies",
        "copy",
        "--from",
        source,
        "--to",
        CDP_URL,
    ]
    if domains:
        cmd += ["--domains", domains]

    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=60,
            cwd=str(ABP_DIR),
        )
    except subprocess.TimeoutExpired:
        return json.dumps({"ok": False, "error": "seed timed out after 60s"}, indent=2)

    return json.dumps(
        {
            "ok": proc.returncode == 0,
            "returncode": proc.returncode,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
        },
        indent=2,
    )


@mcp.tool()
def bh_seed_indexeddb(source: str = "chrome:Default", origins: str | None = None) -> str:
    """Import IndexedDB databases from a local browser profile into the managed Chrome.

    Sister to bh_seed_cookies and bh_seed_localstorage. For each origin: opens
    a new tab to that origin, lets the page bootstrap its own IDB schema, then
    replays records via CDP Runtime.evaluate. Use for sites that store
    auth/session/sync state in IndexedDB (Linear, Figma, Slack web,
    Excalidraw, Notion offline mode).

    Args:
        source: 'browser:profile' spec, e.g. 'arc:Default'.
        origins: comma-separated host substrings (e.g. 'linear.app,figma.com').
                 None = ALL origins with IDB data. Highly recommended to filter.

    Returns JSON with ok, returncode, stdout (counts only), stderr.
    """
    if not ABP_PYTHON.exists():
        return json.dumps(
            {"ok": False, "error": f"ai-browser-profile not bundled at {ABP_PYTHON}"},
            indent=2,
        )

    chrome_result = ensure_chrome()
    if chrome_result.get("status") == "chrome_missing":
        return json.dumps({"ok": False, "error": chrome_result.get("error")}, indent=2)

    cmd = [
        str(ABP_PYTHON),
        "-m",
        "ai_browser_profile.indexeddb",
        "copy",
        "--from",
        source,
        "--to",
        CDP_URL,
    ]
    if origins:
        cmd += ["--origins", origins]

    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=300,  # IDB has more data than cookies/localstorage
            cwd=str(ABP_DIR),
        )
    except subprocess.TimeoutExpired:
        return json.dumps({"ok": False, "error": "seed timed out after 300s"}, indent=2)

    return json.dumps(
        {
            "ok": proc.returncode == 0,
            "returncode": proc.returncode,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
        },
        indent=2,
    )


@mcp.tool()
def bh_seed_localstorage(source: str = "chrome:Default", origins: str | None = None) -> str:
    """Import localStorage from a local browser profile into the managed Chrome.

    Sister to bh_seed_cookies. For each origin: opens a new tab in the managed
    Chrome to that origin, waits ~4s for load, runs localStorage.setItem(...)
    via CDP, then closes the tab. Use for sites that store auth/state in
    localStorage (ChatGPT, Notion, Linear, X.com web).

    Args:
        source: 'browser:profile' spec, e.g. 'chrome:Profile 1'.
        origins: comma-separated host substrings (e.g. 'chatgpt.com,notion.so').
                 None = ALL origins. Highly recommended to filter.

    Returns JSON with ok, returncode, stdout (counts only), stderr.
    """
    if not ABP_PYTHON.exists():
        return json.dumps(
            {"ok": False, "error": f"ai-browser-profile not bundled at {ABP_PYTHON}"},
            indent=2,
        )

    chrome_result = ensure_chrome()
    if chrome_result.get("status") == "chrome_missing":
        return json.dumps({"ok": False, "error": chrome_result.get("error")}, indent=2)

    cmd = [
        str(ABP_PYTHON),
        "-m",
        "ai_browser_profile.localstorage",
        "copy",
        "--from",
        source,
        "--to",
        CDP_URL,
    ]
    if origins:
        cmd += ["--origins", origins]

    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=180,  # tab-per-origin can take a while
            cwd=str(ABP_DIR),
        )
    except subprocess.TimeoutExpired:
        return json.dumps({"ok": False, "error": "seed timed out after 180s"}, indent=2)

    return json.dumps(
        {
            "ok": proc.returncode == 0,
            "returncode": proc.returncode,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
        },
        indent=2,
    )


@mcp.tool()
def bh_screenshot(max_dim: int | None = None) -> str:
    """Capture a screenshot of the current tab and write it to a temp file.

    max_dim (optional): downscale longest edge to this many pixels (saves tokens).
    """
    md_arg = "None" if max_dim is None else str(int(max_dim))
    script = (
        "import json, time, os\n"
        "ensure_real_tab()\n"
        "info = page_info()\n"
        f"path = capture_screenshot(max_dim={md_arg})\n"
        "print(json.dumps({\"screenshot\": str(path), \"page\": info}))\n"
    )
    result = _run_harness(script)
    if not result.get("ok"):
        return json.dumps(result, indent=2)
    out = (result.get("stdout") or "").strip().splitlines()
    payload = out[-1] if out else "{}"
    return payload


@mcp.tool()
def bh_navigate(url: str, new_tab: bool = True) -> str:
    """Open a URL. By default opens in a fresh tab (recommended)."""
    if new_tab:
        nav = f"new_tab({url!r})"
    else:
        nav = f"ensure_real_tab(); goto_url({url!r})"
    script = (
        "import json\n"
        f"{nav}\n"
        "wait_for_load()\n"
        "info = page_info()\n"
        "print(json.dumps(info))\n"
    )
    result = _run_harness(script)
    if not result.get("ok"):
        return json.dumps(result, indent=2)
    out = (result.get("stdout") or "").strip().splitlines()
    return out[-1] if out else "{}"


if __name__ == "__main__":
    _log(f"server starting; bundle={SERVER_DIR} abp={ABP_DIR}")
    try:
        mcp.run()
    except Exception as e:
        _log(f"server crashed: {e!r}")
        raise
