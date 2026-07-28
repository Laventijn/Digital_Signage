#!/usr/bin/env python3
"""Maakt een accountvrije lokale screenshotcache met aparte headless Chromium."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

try:
    import pwd
except ImportError:  # pragma: no cover - Windows-unit-tests
    pwd = None  # type: ignore[assignment]

try:
    import websocket
except ImportError as exc:  # pragma: no cover - afhankelijk van Pi-pakket
    websocket = None
    WEBSOCKET_IMPORT_ERROR = exc
else:
    WEBSOCKET_IMPORT_ERROR = None

from digitalsignage_config import (
    DEFAULT_PRESENTATION_DELAY_MS,
    SUPPORTED_CONTENT_MODES,
    WATERMARK_ELEMENT_ID,
    atomic_activate_version,
    build_content_config,
    byte_difference_percent,
    parse_delayms,
    prune_old_log_lines,
    read_config,
    rotate_log_if_needed,
    safe_work_dir,
    sanitize_url_for_log,
    screenshot_cache_root,
    screenshot_state_dir,
    slide_id_from_url,
    validate_cache_version,
)


CONFIG_FILE = Path(os.environ.get("CONFIG_FILE", "/etc/digitalsignage/digitalsignage.conf"))
DEFAULT_CHROMIUM_BIN = "/usr/bin/chromium"
CANCEL_EXIT_CODE = 75


class CaptureError(RuntimeError):
    """Fout die veilig gelogd en aan de beheerder getoond mag worden."""


class CaptureCancelled(CaptureError):
    """Gecontroleerde annulering via SIGTERM of SIGINT."""


class UnstableCandidate(CaptureError):
    """Een mogelijke dia is nog in overgang; dit is geen technische fout."""

    def __init__(self, difference_percent: float) -> None:
        super().__init__(f"beeld is nog niet stabiel: verschil={difference_percent:.2f}%")
        self.difference_percent = difference_percent


class ActiveCaptureLock(CaptureError):
    """Er loopt al een opname; dit is een normale timer-uitkomst."""


STOP_REQUESTED = False


def request_stop(_signum: int, _frame: Any) -> None:
    global STOP_REQUESTED
    STOP_REQUESTED = True


def install_signal_handlers() -> None:
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)


@dataclass
class CaptureStats:
    attempts: int = 0
    change_poll_attempts: int = 0
    unstable_candidate_attempts: int = 0
    stable: int = 0
    rejected: int = 0
    consecutive_failures: int = 0
    stop_reason: str = ""
    slide_id_changed: bool = False
    slide_id_reliable: bool = False
    slide_id_state: str = "unknown"
    visual_change_seen: bool = False
    observed_slide_ids: set[str] = field(default_factory=set)
    stale_work_removed: int = 0
    stale_lock_removed: bool = False


@dataclass
class StableCandidate:
    raw_png: bytes
    raw_hash: str
    slide_id: str
    difference_percent: float


class Deadline:
    def __init__(self, seconds: int) -> None:
        self.end = time.monotonic() + seconds

    def remaining(self) -> float:
        return max(0.0, self.end - time.monotonic())

    def ensure(self) -> None:
        check_cancelled()
        if self.remaining() <= 0:
            raise CaptureError("maximum captureduur bereikt")

    def sleep(self, seconds: float) -> None:
        self.ensure()
        end = time.monotonic() + min(seconds, self.remaining())
        while time.monotonic() < end:
            check_cancelled()
            time.sleep(min(0.2, end - time.monotonic()))
        self.ensure()


class DevTools:
    def __init__(self, websocket_url: str) -> None:
        if websocket is None:
            raise CaptureError(f"Pythonpakket websocket ontbreekt: {WEBSOCKET_IMPORT_ERROR}")
        self.connection = websocket.create_connection(websocket_url, timeout=10)
        self.next_id = 1

    def close(self) -> None:
        self.connection.close()

    def call(self, method: str, params: dict[str, Any] | None = None, timeout: int = 10) -> dict[str, Any]:
        check_cancelled()
        call_id = self.next_id
        self.next_id += 1
        self.connection.settimeout(timeout)
        self.connection.send(json.dumps({"id": call_id, "method": method, "params": params or {}}))
        while True:
            check_cancelled()
            response = json.loads(self.connection.recv())
            if response.get("id") != call_id:
                continue
            if "error" in response:
                raise CaptureError(f"Chromium DevTools fout bij {method}: {response['error']}")
            result = response.get("result", {})
            return result if isinstance(result, dict) else {}


def check_cancelled() -> None:
    if STOP_REQUESTED:
        raise CaptureCancelled("capture_cancelled")


def current_home() -> Path:
    if pwd is not None:
        return Path(pwd.getpwuid(os.getuid()).pw_dir)
    return Path.home()


def process_exists(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name == "nt":
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False
    return Path("/proc", str(pid)).exists()


def process_is_capture_script(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name == "nt":
        return process_exists(pid)
    try:
        cmdline = Path("/proc", str(pid), "cmdline").read_bytes().replace(b"\x00", b" ").decode("utf-8", errors="replace")
    except OSError:
        return False
    return "capture-content-cache.py" in cmdline


def read_lock_pid(lock_file: Path) -> int:
    try:
        raw = lock_file.read_text(encoding="utf-8").strip()
        data = json.loads(raw)
        if isinstance(data, dict):
            return int(data.get("pid", 0))
        return int(raw)
    except (OSError, ValueError, json.JSONDecodeError, TypeError):
        return 0


def acquire_lock(state_dir: Path) -> tuple[int, bool]:
    state_dir.mkdir(parents=True, exist_ok=True)
    lock_file = state_dir / "screenshot-cache.lock"
    stale_removed = False
    while True:
        try:
            fd = os.open(str(lock_file), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            payload = {
                "pid": os.getpid(),
                "started_at": datetime.now().astimezone().isoformat(timespec="seconds"),
                "script": "capture-content-cache.py",
            }
            os.write(fd, json.dumps(payload, sort_keys=True).encode("utf-8"))
            return fd, stale_removed
        except FileExistsError as exc:
            if lock_file.is_symlink():
                raise CaptureError("lockbestand is een symlink; opname wordt geweigerd") from exc
            pid = read_lock_pid(lock_file)
            if pid > 0 and process_exists(pid) and process_is_capture_script(pid):
                raise ActiveCaptureLock("er loopt al een screenshotopname") from exc
            lock_file.unlink(missing_ok=True)
            stale_removed = True


def release_lock(fd: int | None, state_dir: Path) -> None:
    if fd is not None:
        try:
            os.close(fd)
        except OSError:
            pass
    lock_file = state_dir / "screenshot-cache.lock"
    try:
        if not lock_file.is_symlink():
            lock_file.unlink()
    except OSError:
        pass


def cleanup_stale_work(cache_root: Path, current_work: Path) -> int:
    work_root = cache_root / "work"
    if not work_root.is_dir():
        return 0
    removed = 0
    for path in work_root.iterdir():
        if path == current_work or not path.name.startswith("capture-") or path.is_symlink() or not path.is_dir():
            continue
        shutil.rmtree(path, ignore_errors=True)
        removed += 1
    return removed


def log_line(log_file: Path, config: Any, line: str) -> None:
    now = datetime.now().astimezone()
    log_file.parent.mkdir(parents=True, exist_ok=True)
    prune_old_log_lines(log_file, config.log_retention_days, now)
    rotate_log_if_needed(log_file, config.log_max_bytes, "screenshot-cache.log.1")
    with log_file.open("a", encoding="utf-8") as handle:
        handle.write(f"{now.isoformat(timespec='seconds')} {line}\n")


def log_cleanup_warning(log_file: Path, config: Any, line: str) -> None:
    try:
        log_line(log_file, config, line)
    except Exception:
        pass


def chromium_command(raw_config: dict[str, str], config: Any, browser_dir: Path) -> list[str]:
    chromium_bin = raw_config.get("CHROMIUM_BIN", DEFAULT_CHROMIUM_BIN).strip() or DEFAULT_CHROMIUM_BIN
    if not Path(chromium_bin).is_file():
        raise CaptureError(f"Chromium-binary ontbreekt: {chromium_bin}")
    return [
        chromium_bin,
        "--headless=new",
        "--disable-gpu",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-session-crashed-bubble",
        "--autoplay-policy=no-user-gesture-required",
        "--password-store=basic",
        "--hide-scrollbars",
        "--force-device-scale-factor=1",
        "--remote-debugging-address=127.0.0.1",
        f"--remote-debugging-port={config.capture_debug_port}",
        f"--remote-allow-origins=http://127.0.0.1:{config.capture_debug_port}",
        f"--user-data-dir={browser_dir / 'profile'}",
        f"--disk-cache-dir={browser_dir / 'cache'}",
        f"--window-size={config.capture_width},{config.capture_height}",
        config.effective_url,
    ]


def start_chromium(raw_config: dict[str, str], config: Any, browser_dir: Path) -> subprocess.Popen[bytes]:
    return subprocess.Popen(
        chromium_command(raw_config, config, browser_dir),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )


def stop_chromium(process: subprocess.Popen[bytes]) -> None:
    try:
        if process.poll() is not None:
            return
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    except Exception:
        return


def deadline_sleep(seconds: float, deadline: Deadline) -> None:
    deadline.sleep(seconds)


def wait_for_target(port: int, deadline: Deadline) -> dict[str, Any]:
    last_error = ""
    while deadline.remaining() > 0:
        check_cancelled()
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=min(3, max(1, deadline.remaining()))) as response:
                targets = json.loads(response.read().decode("utf-8"))
            for target in targets:
                if target.get("type") == "page" and target.get("webSocketDebuggerUrl"):
                    return target
        except (OSError, urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            last_error = str(exc)
        deadline_sleep(0.25, deadline)
    raise CaptureError(f"DevTools-endpoint werd niet beschikbaar: {last_error}")


def js_string(value: str) -> str:
    return json.dumps(value)


def watermark_script(text: str) -> str:
    return f"""
(() => {{
  const existing = document.getElementById({js_string(WATERMARK_ELEMENT_ID)});
  if (existing) existing.remove();
  const element = document.createElement('div');
  element.id = {js_string(WATERMARK_ELEMENT_ID)};
  element.textContent = {js_string(text)};
  Object.assign(element.style, {{
    position: 'fixed',
    right: '2.4vw',
    bottom: '2.4vh',
    zIndex: '2147483647',
    padding: '0.45em 0.75em',
    borderRadius: '0.35em',
    background: 'rgba(0, 0, 0, 0.58)',
    color: '#fff',
    fontFamily: 'Arial, sans-serif',
    fontSize: 'clamp(18px, 2vw, 42px)',
    lineHeight: '1.2',
    pointerEvents: 'none',
    textShadow: '0 1px 2px rgba(0,0,0,0.65)'
  }});
  document.documentElement.appendChild(element);
}})();
"""


def remove_watermark_script() -> str:
    return f"(() => {{ const e = document.getElementById({js_string(WATERMARK_ELEMENT_ID)}); if (e) e.remove(); }})();"


def evaluate(devtools: DevTools, expression: str, timeout: int = 10) -> Any:
    result = devtools.call(
        "Runtime.evaluate",
        {"expression": expression, "returnByValue": True, "awaitPromise": True},
        timeout=timeout,
    )
    return result.get("result", {}).get("value")


def wait_ready(devtools: DevTools, deadline: Deadline) -> None:
    while deadline.remaining() > 0:
        state = evaluate(devtools, "document.readyState", timeout=min(5, max(1, int(deadline.remaining()))))
        if state in {"interactive", "complete"}:
            return
        deadline_sleep(0.25, deadline)
    raise CaptureError("pagina werd niet tijdig geladen")


def current_url(devtools: DevTools) -> str:
    return str(evaluate(devtools, "location.href", timeout=5) or "")


def runtime_diagnostics(devtools: DevTools) -> dict[str, Any]:
    try:
        value = evaluate(devtools, """(() => ({
  readyState: document.readyState,
  visibilityState: document.visibilityState,
  now: Math.round(performance.now()),
  url: location.href
}))()""", timeout=5)
    except Exception:
        return {}
    return value if isinstance(value, dict) else {}


def wait_for_paint_cycles(devtools: DevTools) -> None:
    try:
        devtools.call("Page.bringToFront", timeout=5)
    except Exception:
        pass
    try:
        evaluate(devtools, """new Promise((resolve) => {
  requestAnimationFrame(() => requestAnimationFrame(() => resolve(true)));
})""", timeout=5)
    except Exception:
        pass
    try:
        devtools.call("Page.getLayoutMetrics", timeout=5)
    except Exception:
        pass


def image_hash(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def png_dimensions(data: bytes) -> tuple[int, int]:
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise CaptureError("screenshot is geen geldige PNG")
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


def validate_png_size(data: bytes, width: int, height: int) -> None:
    actual_width, actual_height = png_dimensions(data)
    if actual_width != width or actual_height != height:
        raise CaptureError(f"screenshotresolutie wijkt af: verwacht={width}x{height} werkelijk={actual_width}x{actual_height}")


def set_viewport(devtools: DevTools, config: Any) -> None:
    devtools.call(
        "Emulation.setDeviceMetricsOverride",
        {
            "width": config.capture_width,
            "height": config.capture_height,
            "deviceScaleFactor": 1,
            "mobile": False,
            "screenWidth": config.capture_width,
            "screenHeight": config.capture_height,
        },
        timeout=10,
    )
    metrics = devtools.call("Page.getLayoutMetrics", timeout=10)
    viewport = metrics.get("cssVisualViewport") or metrics.get("layoutViewport") or {}
    width = round(float(viewport.get("clientWidth", 0) or 0))
    height = round(float(viewport.get("clientHeight", 0) or 0))
    if width != config.capture_width or height != config.capture_height:
        raise CaptureError(f"Chromium viewport wijkt af: verwacht={config.capture_width}x{config.capture_height} werkelijk={width}x{height}")


def capture_png(devtools: DevTools, config: Any, watermark_text: str = "") -> bytes:
    if watermark_text:
        evaluate(devtools, watermark_script(watermark_text), timeout=5)
    try:
        result = devtools.call(
            "Page.captureScreenshot",
            {
                "format": "png",
                "fromSurface": True,
                "clip": {
                    "x": 0,
                    "y": 0,
                    "width": config.capture_width,
                    "height": config.capture_height,
                    "scale": 1,
                },
            },
            timeout=30,
        )
    finally:
        if watermark_text:
            evaluate(devtools, remove_watermark_script(), timeout=5)
    data = result.get("data")
    if not isinstance(data, str) or not data:
        raise CaptureError("Chromium gaf geen screenshotdata terug")
    png = base64.b64decode(data)
    validate_png_size(png, config.capture_width, config.capture_height)
    return png


def effective_stable_gap_seconds(config: Any, delay_ms: int) -> float:
    max_gap_ms = max(250, min(1000, max(250, delay_ms // 5)))
    return min(config.stable_gap_ms, max_gap_ms) / 1000


def stable_raw_capture(devtools: DevTools, config: Any, deadline: Deadline, delay_ms: int) -> StableCandidate:
    deadline_sleep(config.transition_wait_ms / 1000, deadline)
    first = capture_png(devtools, config)
    first_url = current_url(devtools)
    deadline_sleep(effective_stable_gap_seconds(config, delay_ms), deadline)
    second = capture_png(devtools, config)
    second_url = current_url(devtools)
    diff = byte_difference_percent(first, second)
    if diff > config.image_difference_percent:
        raise UnstableCandidate(diff)
    return StableCandidate(second, image_hash(second), slide_id_from_url(second_url or first_url) or "", diff)


def final_watermarked_capture(devtools: DevTools, config: Any) -> tuple[bytes, str]:
    image = capture_png(devtools, config, config.offline_watermark_text)
    return image, image_hash(image)


def write_player_files(version_dir: Path, manifest: dict[str, Any]) -> None:
    (version_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (version_dir / "index.html").write_text("""<!doctype html>
<html lang="nl">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Digital Signage offline cache</title>
  <link rel="stylesheet" href="player.css">
</head>
<body>
  <main id="stage" aria-live="polite">
    <img id="screen" alt="">
    <div id="error" hidden>Offlinebeeld kon niet worden geladen.</div>
  </main>
  <script src="player.js"></script>
</body>
</html>
""", encoding="utf-8")
    (version_dir / "player.css").write_text("""html, body {
  width: 100%;
  height: 100%;
  margin: 0;
  overflow: hidden;
  background: #050505;
}

#stage {
  width: 100vw;
  height: 100vh;
  display: grid;
  place-items: center;
  background: #050505;
}

#screen {
  width: 100vw;
  height: 100vh;
  object-fit: contain;
  background: #050505;
}

#error {
  color: #fff;
  font: 24px/1.4 Arial, sans-serif;
}
""", encoding="utf-8")
    (version_dir / "player.js").write_text("""(() => {
  const image = document.getElementById('screen');
  const error = document.getElementById('error');
  let manifest = null;
  let index = 0;

  function showError() {
    image.hidden = true;
    error.hidden = false;
  }

  function showCurrent() {
    const entries = Array.isArray(manifest.images) ? manifest.images : [];
    if (entries.length === 0) {
      showError();
      return;
    }
    image.hidden = false;
    error.hidden = true;
    image.src = entries[index].file;
  }

  image.addEventListener('error', showError);

  fetch('manifest.json', { cache: 'no-store' })
    .then((response) => response.json())
    .then((data) => {
      manifest = data;
      showCurrent();
      if (manifest.mode === 'presentation' && manifest.images.length > 1) {
        const seconds = Math.max(1, Number(manifest.slide_seconds) || 5);
        window.setInterval(() => {
          index = (index + 1) % manifest.images.length;
          showCurrent();
        }, seconds * 1000);
      }
    })
    .catch(showError);
})();
""", encoding="utf-8")


def current_fingerprint(cache_root: Path) -> list[str]:
    manifest_file = cache_root / "current" / "manifest.json"
    if not manifest_file.exists():
        return []
    try:
        manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return []
    return [str(image.get("stored_hash") or image.get("hash", "")) for image in manifest.get("images", [])]


def publish_version(cache_root: Path, version_dir: Path, config: Any, manifest: dict[str, Any], stored_hashes: list[str]) -> str:
    if stored_hashes and stored_hashes == current_fingerprint(cache_root):
        shutil.rmtree(version_dir.parent, ignore_errors=True)
        return "unchanged"
    ok, reason, _loaded = validate_cache_version(version_dir)
    if not ok:
        raise CaptureError(f"nieuwe cacheversie is ongeldig: {reason}")
    versions_dir = cache_root / "versions"
    versions_dir.mkdir(parents=True, exist_ok=True)
    final_version = versions_dir / version_dir.parent.name
    if final_version.exists():
        shutil.rmtree(final_version)
    shutil.move(str(version_dir), str(final_version))
    shutil.rmtree(version_dir.parent, ignore_errors=True)
    atomic_activate_version(cache_root, final_version, config.keep_versions)
    return "updated"


def save_candidate(devtools: DevTools, config: Any, version_dir: Path, candidate: StableCandidate, images: list[dict[str, Any]], stored_hashes: list[str]) -> None:
    image, stored_hash = final_watermarked_capture(devtools, config)
    filename = f"images/slide-{len(images) + 1:03d}.png"
    (version_dir / filename).write_bytes(image)
    stored_hashes.append(stored_hash)
    images.append({
        "file": filename,
        "raw_hash": candidate.raw_hash,
        "stored_hash": stored_hash,
        "slide_id": candidate.slide_id,
        "stable_difference_percent": round(candidate.difference_percent, 2),
    })


def candidate_key(candidate: StableCandidate, slide_id_reliable: bool) -> str:
    return f"slide:{candidate.slide_id}" if slide_id_reliable and candidate.slide_id else f"raw:{candidate.raw_hash}"


def observe_slide_id_reliability(images: list[dict[str, Any]]) -> bool:
    ids = [str(image.get("slide_id", "")) for image in images if image.get("slide_id")]
    raw_hashes = [str(image.get("raw_hash", "")) for image in images]
    return len(ids) >= 2 and len(set(ids)) == len(set(raw_hashes))


def record_slide_id(stats: CaptureStats, slide_id: str) -> None:
    if slide_id:
        stats.observed_slide_ids.add(slide_id)


def observed_distinct_slide_ids(stats: CaptureStats) -> bool:
    return len(stats.observed_slide_ids) >= 2


def can_confirm_single_slide(stats: CaptureStats) -> bool:
    return not observed_distinct_slide_ids(stats) and not stats.visual_change_seen


def candidate_dimensions(candidate: StableCandidate | None) -> str:
    if candidate is None or not candidate.raw_png:
        return "-"
    width, height = png_dimensions(candidate.raw_png)
    return f"{width}x{height}" if width and height else "-"


def log_rejected(log_file: Path, config: Any, stats: CaptureStats, reason: str, candidate: StableCandidate | None, previous: StableCandidate | None, started: float, technical_failure: bool = False) -> None:
    stats.rejected += 1
    if technical_failure:
        stats.consecutive_failures += 1
    if stats.rejected <= 10 or stats.rejected % 10 == 0:
        slide_id = candidate.slide_id if candidate else ""
        previous_slide_id = previous.slide_id if previous else ""
        diff = candidate.difference_percent if candidate else -1
        phase = "technical_error" if technical_failure else reason
        log_line(
            log_file,
            config,
            " ".join([
                f"mode={config.mode}",
                f"attempt={stats.attempts}",
                f"elapsed={round(time.monotonic() - started, 1)}",
                f"url={sanitize_url_for_log(config.effective_url)}",
                f"slide_id={slide_id or '-'}",
                f"previous_slide_id={previous_slide_id or '-'}",
                f"raw_hash={(candidate.raw_hash[:12] if candidate and candidate.raw_hash else '-')}",
                f"previous_raw_hash={(previous.raw_hash[:12] if previous and previous.raw_hash else '-')}",
                f"raw_difference={round(diff, 2)}",
                f"stability_difference={round(diff, 2) if reason == 'unstable_candidate' else '-'}",
                f"dimensions={candidate_dimensions(candidate)}",
                f"phase={phase.replace(' ', '_')}",
                "candidate=unstable" if reason == "unstable_candidate" else "candidate=rejected",
                f"reason={reason.replace(' ', '_')}",
            ]),
        )
    if technical_failure and stats.consecutive_failures >= config.max_consecutive_failures:
        stats.stop_reason = "consecutive_failures"
        raise CaptureError("te veel opeenvolgende mislukte stable-capture-pogingen")


def log_changed_candidate(log_file: Path, config: Any, stats: CaptureStats, previous: StableCandidate, slide_id: str, raw_png: bytes, diff: float, started: float, phase: str, devtools: DevTools) -> None:
    if stats.change_poll_attempts > 10 and stats.change_poll_attempts % 10 != 0:
        return
    diagnostics = runtime_diagnostics(devtools)
    log_line(
        log_file,
        config,
        " ".join([
            f"mode={config.mode}",
            f"attempt={stats.attempts}",
            f"elapsed={round(time.monotonic() - started, 1)}",
            f"url={sanitize_url_for_log(str(diagnostics.get('url') or config.effective_url))}",
            f"page_url={sanitize_url_for_log(str(diagnostics.get('url') or ''))}",
            f"target_id={getattr(devtools, 'target_id', '-') or '-'}",
            f"slide_id={slide_id or '-'}",
            f"previous_slide_id={previous.slide_id or '-'}",
            f"raw_hash={image_hash(raw_png)[:12]}",
            f"previous_raw_hash={previous.raw_hash[:12]}",
            f"raw_difference={round(diff, 2)}",
            f"visibility={diagnostics.get('visibilityState', '-')}",
            f"ready={diagnostics.get('readyState', '-')}",
            f"paint_now={diagnostics.get('now', '-')}",
            f"phase={phase}",
            "candidate=changed",
        ]),
    )


def wait_for_rendered_slide_change(devtools: DevTools, config: Any, previous: StableCandidate, deadline: Deadline, started: float, stats: CaptureStats, log_file: Path, delay_ms: int, expected_slide_id: str) -> StableCandidate:
    deadline_sleep(config.transition_wait_ms / 1000, deadline)
    while deadline.remaining() > 0:
        wait_for_paint_cycles(devtools)
        stats.change_poll_attempts += 1
        stats.attempts += 1
        png = capture_png(devtools, config)
        url = current_url(devtools)
        slide_id = slide_id_from_url(url) or expected_slide_id
        record_slide_id(stats, slide_id)
        raw_diff = byte_difference_percent(previous.raw_png, png)
        if raw_diff <= config.image_difference_percent:
            log_changed_candidate(log_file, config, stats, previous, slide_id, png, raw_diff, started, "await_rendered_frame", devtools)
            deadline_sleep(config.change_poll_ms / 1000, deadline)
            continue

        deadline_sleep(effective_stable_gap_seconds(config, delay_ms), deadline)
        wait_for_paint_cycles(devtools)
        second = capture_png(devtools, config)
        second_url = current_url(devtools)
        second_slide_id = slide_id_from_url(second_url) or slide_id
        record_slide_id(stats, second_slide_id)
        stability_diff = byte_difference_percent(png, second)
        if stability_diff > config.image_difference_percent:
            stats.unstable_candidate_attempts += 1
            log_rejected(log_file, config, stats, "unstable_candidate", StableCandidate(second, image_hash(second), second_slide_id, stability_diff), previous, started)
            deadline_sleep(max(0.2, config.change_poll_ms / 1000), deadline)
            continue
        candidate = StableCandidate(second, image_hash(second), second_slide_id, raw_diff)
        log_changed_candidate(log_file, config, stats, previous, second_slide_id, second, raw_diff, started, "rendered_frame_stable", devtools)
        return candidate
    stats.stop_reason = "maximum_duration_reached"
    raise CaptureError("maximum captureduur bereikt")


def first_stable_raw_capture(devtools: DevTools, config: Any, deadline: Deadline, started: float, stats: CaptureStats, log_file: Path, delay_ms: int) -> StableCandidate:
    while deadline.remaining() > 0:
        stats.attempts += 1
        try:
            candidate = stable_raw_capture(devtools, config, deadline, delay_ms)
            stats.consecutive_failures = 0
            return candidate
        except UnstableCandidate as exc:
            stats.unstable_candidate_attempts += 1
            log_rejected(log_file, config, stats, "unstable_candidate", StableCandidate(b"", "", "", exc.difference_percent), None, started)
            deadline_sleep(config.change_poll_ms / 1000, deadline)
        except CaptureError as exc:
            if isinstance(exc, CaptureCancelled):
                raise
            log_rejected(log_file, config, stats, str(exc), None, None, started, technical_failure=True)
    stats.stop_reason = "maximum_duration_reached"
    raise CaptureError("maximum captureduur bereikt")


def wait_for_visual_change(devtools: DevTools, config: Any, previous: StableCandidate, deadline: Deadline, started: float, stats: CaptureStats, log_file: Path, delay_ms: int, max_seconds: float | None = None) -> StableCandidate | None:
    record_slide_id(stats, previous.slide_id)
    local_end = time.monotonic() + max_seconds if max_seconds is not None else None
    while deadline.remaining() > 0 and (local_end is None or time.monotonic() < local_end):
        deadline_sleep(config.change_poll_ms / 1000, deadline)
        stats.change_poll_attempts += 1
        stats.attempts += 1
        slide_id = ""
        try:
            png = capture_png(devtools, config)
            url = current_url(devtools)
            diff = byte_difference_percent(previous.raw_png, png)
            slide_id = slide_id_from_url(url) or ""
            record_slide_id(stats, slide_id)
            id_changed = bool(slide_id and previous.slide_id and slide_id != previous.slide_id)
            if id_changed:
                stats.slide_id_changed = True
                stats.visual_change_seen = True
                return wait_for_rendered_slide_change(devtools, config, previous, deadline, started, stats, log_file, delay_ms, slide_id)
            if diff <= config.image_difference_percent:
                continue
            stats.visual_change_seen = True
            candidate = stable_raw_capture(devtools, config, deadline, delay_ms)
            raw_diff = byte_difference_percent(previous.raw_png, candidate.raw_png)
            if raw_diff <= config.image_difference_percent:
                log_rejected(log_file, config, stats, "change_not_distinct", candidate, previous, started)
                continue
            candidate.difference_percent = raw_diff
            return candidate
        except UnstableCandidate as exc:
            stats.unstable_candidate_attempts += 1
            log_rejected(log_file, config, stats, "unstable_candidate", StableCandidate(b"", "", slide_id, exc.difference_percent), previous, started)
            deadline_sleep(max(0.2, config.change_poll_ms / 1000), deadline)
            continue
        except CaptureError as exc:
            if isinstance(exc, CaptureCancelled):
                raise
            log_rejected(log_file, config, stats, str(exc), None, previous, started, technical_failure=True)
    if local_end is not None:
        return None
    stats.stop_reason = "maximum_duration_reached"
    raise CaptureError("maximum captureduur bereikt")


def confirm_single_slide(devtools: DevTools, config: Any, first: StableCandidate, deadline: Deadline, delay_ms: int) -> bool:
    confirm_seconds = max(config.single_slide_confirm_seconds, int((2 * delay_ms + config.transition_wait_ms) / 1000))
    end = time.monotonic() + min(confirm_seconds, deadline.remaining())
    while time.monotonic() < end:
        deadline_sleep(config.change_poll_ms / 1000, deadline)
        png = capture_png(devtools, config)
        if byte_difference_percent(first.raw_png, png) > config.image_difference_percent:
            return False
    return True


def capture_website(devtools: DevTools, config: Any, version_dir: Path, deadline: Deadline) -> tuple[dict[str, Any], list[str], CaptureStats]:
    stats = CaptureStats()
    wait_ready(devtools, deadline)
    candidate = stable_raw_capture(devtools, config, deadline, DEFAULT_PRESENTATION_DELAY_MS)
    image, stored_hash = final_watermarked_capture(devtools, config)
    images_dir = version_dir / "images"
    images_dir.mkdir(parents=True, exist_ok=True)
    (images_dir / "latest.png").write_bytes(image)
    stats.stable = 1
    stats.stop_reason = "single_slide_confirmed"
    manifest = {
        "created_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "mode": "website",
        "source_url": sanitize_url_for_log(config.effective_url),
        "slide_seconds": max(1, DEFAULT_PRESENTATION_DELAY_MS // 1000),
        "capture_attempts": 1,
        "change_poll_attempts": stats.change_poll_attempts,
        "unstable_candidate_attempts": stats.unstable_candidate_attempts,
        "accepted_slides": stats.stable,
        "rejected_attempts": 0,
        "stop_reason": stats.stop_reason,
        "slide_id_reliable": False,
        "images": [{"file": "images/latest.png", "raw_hash": candidate.raw_hash, "stored_hash": stored_hash, "stable_difference_percent": round(candidate.difference_percent, 2)}],
    }
    write_player_files(version_dir, manifest)
    return manifest, [stored_hash], stats


def capture_presentation(devtools: DevTools, config: Any, version_dir: Path, deadline: Deadline, log_file: Path, started: float) -> tuple[dict[str, Any], list[str], CaptureStats]:
    stats = CaptureStats()
    wait_ready(devtools, deadline)
    delay_ms = parse_delayms(config.effective_url)
    slide_seconds = max(1, round(delay_ms / 1000))
    images_dir = version_dir / "images"
    images_dir.mkdir(parents=True, exist_ok=True)
    images: list[dict[str, Any]] = []
    stored_hashes: list[str] = []

    first = first_stable_raw_capture(devtools, config, deadline, started, stats, log_file, delay_ms)
    record_slide_id(stats, first.slide_id)
    save_candidate(devtools, config, version_dir, first, images, stored_hashes)
    stats.stable += 1
    stats.consecutive_failures = 0
    previous = first
    first_raw_hash = first.raw_hash
    single_confirm_seconds = max(config.single_slide_confirm_seconds, int((2 * delay_ms + config.transition_wait_ms) / 1000))
    log_line(log_file, config, f"mode=presentation attempt={stats.attempts} phase=first_slide candidate=stable slide=accepted found={len(images)} slide_id={first.slide_id or '-'} raw_hash={first.raw_hash[:12]} stability_difference={round(first.difference_percent, 2)} dimensions={candidate_dimensions(first)}")
    early_candidate = wait_for_visual_change(devtools, config, previous, deadline, started, stats, log_file, delay_ms, max_seconds=single_confirm_seconds)
    if early_candidate is None:
        if can_confirm_single_slide(stats):
            stats.stop_reason = "single_slide_confirmed"
    else:
        pending_candidate: StableCandidate | None = early_candidate

    while not stats.stop_reason and len(images) < config.max_slides:
        if "pending_candidate" in locals() and pending_candidate is not None:
            candidate = pending_candidate
            pending_candidate = None
        else:
            candidate = wait_for_visual_change(devtools, config, previous, deadline, started, stats, log_file, delay_ms)
        if candidate is None:
            continue
        stats.slide_id_reliable = observe_slide_id_reliability(images + [{"slide_id": candidate.slide_id, "raw_hash": candidate.raw_hash}])
        seen_keys = {candidate_key(StableCandidate(b"", str(image["raw_hash"]), str(image.get("slide_id", "")), 0), stats.slide_id_reliable) for image in images}
        key = candidate_key(candidate, stats.slide_id_reliable)
        if candidate.raw_hash == first_raw_hash and len(images) >= 2:
            stats.stop_reason = "round_complete"
            break
        if key in seen_keys and len(images) >= 2:
            stats.stop_reason = "round_complete"
            break
        if candidate.raw_hash in {str(image["raw_hash"]) for image in images}:
            if len(images) == 1 and confirm_single_slide(devtools, config, first, deadline, delay_ms):
                stats.stop_reason = "single_slide_confirmed"
                break
            log_rejected(log_file, config, stats, "duplicate_raw_hash", candidate, previous, started)
            continue
        record_slide_id(stats, candidate.slide_id)
        save_candidate(devtools, config, version_dir, candidate, images, stored_hashes)
        stats.stable += 1
        stats.consecutive_failures = 0
        previous = candidate
        stats.slide_id_reliable = observe_slide_id_reliability(images)
        stats.slide_id_state = "reliable" if stats.slide_id_reliable else "unknown"
        log_line(log_file, config, f"mode=presentation attempt={stats.attempts} phase=visual_change candidate=stable slide=accepted found={len(images)} slide_id={candidate.slide_id or '-'} raw_hash={candidate.raw_hash[:12]} raw_difference={round(candidate.difference_percent, 2)} dimensions={candidate_dimensions(candidate)}")

    if len(images) >= config.max_slides:
        stats.stop_reason = "max_slides_reached"
    if not stats.stop_reason and len(images) == 1:
        if can_confirm_single_slide(stats) and confirm_single_slide(devtools, config, first, deadline, delay_ms):
            stats.stop_reason = "single_slide_confirmed"
        else:
            stats.stop_reason = "incomplete_round"
            raise CaptureError("onvolledige presentatieronde: meerdere slide-ID's of veranderingen gezien maar te weinig stabiele dia's vastgelegd")
    if not images:
        raise CaptureError("geen stabiele presentatiedia gevonden")
    if len(images) == 1 and not can_confirm_single_slide(stats):
        stats.stop_reason = "incomplete_round"
        raise CaptureError("onvolledige presentatieronde: een 1-slidecache zou onbetrouwbaar zijn")
    manifest = {
        "created_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "mode": "presentation",
        "source_url": sanitize_url_for_log(config.effective_url),
        "slide_seconds": slide_seconds,
        "images": images,
        "capture_attempts": stats.attempts,
        "change_poll_attempts": stats.change_poll_attempts,
        "unstable_candidate_attempts": stats.unstable_candidate_attempts,
        "accepted_slides": stats.stable,
        "rejected_attempts": stats.rejected,
        "stop_reason": stats.stop_reason,
        "slide_id_reliable": stats.slide_id_reliable,
        "slide_id_state": stats.slide_id_state,
        "observed_slide_ids": sorted(stats.observed_slide_ids),
        "duration_seconds": round(time.monotonic() - started, 1),
    }
    write_player_files(version_dir, manifest)
    return manifest, stored_hashes, stats


def run_capture(args: argparse.Namespace) -> int:
    install_signal_handlers()
    started = time.monotonic()
    raw_config = read_config(args.config_file)
    config = build_content_config(raw_config)
    deadline = Deadline(config.max_capture_seconds)
    home = Path(args.home).resolve() if args.home else current_home()
    cache_root = Path(args.cache_root).resolve() if args.cache_root else screenshot_cache_root(home)
    state_dir = Path(args.state_dir).resolve() if args.state_dir else screenshot_state_dir(home)
    log_file = state_dir / "screenshot-cache.log"
    process: subprocess.Popen[bytes] | None = None
    devtools: DevTools | None = None
    lock_fd: int | None = None
    work_root: Path | None = None
    stats = CaptureStats()

    for warning in config.warnings:
        print(f"Waarschuwing: {warning}", file=sys.stderr)
    if config.mode not in SUPPORTED_CONTENT_MODES:
        log_line(log_file, config, f"mode={config.mode} cache=preserved reason=invalid_content_mode")
        raise CaptureError("CONTENT_MODE moet presentation of website zijn")
    if not config.screenshot_cache_enabled:
        log_line(log_file, config, f"mode={config.mode} cache=unchanged reason=cache_disabled")
        return 0
    if not config.effective_url:
        log_line(log_file, config, f"mode={config.mode} cache=preserved reason=content_url_missing")
        raise CaptureError("CONTENT_URL ontbreekt en PRESENTATION_URL is leeg")

    cache_root.mkdir(parents=True, exist_ok=True)
    state_dir.mkdir(parents=True, exist_ok=True)
    try:
        lock_fd, stats.stale_lock_removed = acquire_lock(state_dir)
        work_root = safe_work_dir(cache_root)
        stats.stale_work_removed = cleanup_stale_work(cache_root, work_root)
        browser_dir = work_root / "browser"
        version_dir = work_root / "version"
        browser_dir.mkdir(parents=True, exist_ok=True)
        version_dir.mkdir(parents=True, exist_ok=True)
        delay_ms = parse_delayms(config.effective_url)
        effective_gap_ms = round(effective_stable_gap_seconds(config, delay_ms) * 1000)
        stable_gap_note = f" stable_gap_effective_ms={effective_gap_ms}"
        if effective_gap_ms != config.stable_gap_ms:
            stable_gap_note += f" stable_gap_configured_ms={config.stable_gap_ms} stable_gap_warning=effective_gap_below_slide_delay"
        log_line(log_file, config, f"mode={config.mode} cache=running url={sanitize_url_for_log(config.effective_url)} stale_work_removed={stats.stale_work_removed} stale_lock_removed={str(stats.stale_lock_removed).lower()}{stable_gap_note}")
        process = start_chromium(raw_config, config, browser_dir)
        target = wait_for_target(config.capture_debug_port, deadline)
        devtools = DevTools(str(target["webSocketDebuggerUrl"]))
        setattr(devtools, "target_id", str(target.get("id", "")))
        set_viewport(devtools, config)
        if config.mode == "website":
            manifest, stored_hashes, stats = capture_website(devtools, config, version_dir, deadline)
        else:
            manifest, stored_hashes, stats = capture_presentation(devtools, config, version_dir, deadline, log_file, started)
        cache_state = publish_version(cache_root, version_dir, config, manifest, stored_hashes)
        duration = round(time.monotonic() - started, 1)
        log_line(
            log_file,
            config,
            " ".join([
                f"mode={config.mode}",
                f"attempts={stats.attempts}",
                f"change_poll_attempts={stats.change_poll_attempts}",
                f"unstable_candidate_attempts={stats.unstable_candidate_attempts}",
                f"accepted_slides={stats.stable}",
                f"stable={stats.stable}",
                f"rejected={stats.rejected}",
                f"found={len(stored_hashes)}",
                f"saved={len(stored_hashes)}",
                f"cache={cache_state}",
                f"stop_reason={stats.stop_reason}",
                f"slide_id_reliable={str(stats.slide_id_reliable).lower()}",
                f"duration={duration}",
            ]),
        )
        return 0
    except CaptureCancelled:
        stats.stop_reason = "capture_cancelled"
        log_line(log_file, config, f"mode={config.mode} cache=preserved reason=capture_cancelled stop_reason=capture_cancelled duration={round(time.monotonic() - started, 1)}")
        return CANCEL_EXIT_CODE
    except ActiveCaptureLock as exc:
        stats.stop_reason = "active_capture_lock"
        log_line(log_file, config, f"mode={config.mode} cache=unchanged reason=active_capture_lock stop_reason=active_capture_lock duration={round(time.monotonic() - started, 1)}")
        print(f"Info: {exc}", file=sys.stderr)
        return 0
    except CaptureError as exc:
        if stats.stop_reason == "":
            stats.stop_reason = "failed"
        reason = "maximum_duration_reached" if "maximum captureduur" in str(exc) else str(exc).replace(" ", "_")
        log_line(log_file, config, f"mode={config.mode} cache=preserved reason={reason} stop_reason={stats.stop_reason} duration={round(time.monotonic() - started, 1)}")
        print(f"Fout: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:
        if stats.stop_reason == "":
            stats.stop_reason = "failed"
        reason = str(exc).replace(" ", "_") or exc.__class__.__name__
        log_line(log_file, config, f"mode={config.mode} cache=preserved reason={reason} stop_reason={stats.stop_reason} duration={round(time.monotonic() - started, 1)}")
        print(f"Fout: {exc}", file=sys.stderr)
        return 1
    finally:
        if devtools is not None:
            try:
                devtools.close()
            except Exception as exc:
                log_cleanup_warning(log_file, config, f"mode={config.mode} cleanup_warning=devtools_close_failed reason={str(exc).replace(' ', '_')}")
        if process is not None:
            stop_chromium(process)
        if work_root is not None:
            try:
                shutil.rmtree(work_root, ignore_errors=False)
            except FileNotFoundError:
                pass
            except OSError as exc:
                log_cleanup_warning(log_file, config, f"mode={config.mode} cleanup_warning=workdir_remove_failed reason={str(exc).replace(' ', '_')}")
        release_lock(lock_fd, state_dir)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Maak een lokale screenshotcache.")
    parser.add_argument("--config-file", type=Path, default=CONFIG_FILE)
    parser.add_argument("--home", default="")
    parser.add_argument("--cache-root", default="")
    parser.add_argument("--state-dir", default="")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        return run_capture(args)
    except CaptureError as exc:
        print(f"Fout: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
