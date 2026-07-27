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
    bool_config,
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


class CaptureError(RuntimeError):
    """Fout die veilig gelogd en aan de beheerder getoond mag worden."""


class DevTools:
    def __init__(self, websocket_url: str) -> None:
        if websocket is None:
            raise CaptureError(f"Pythonpakket websocket ontbreekt: {WEBSOCKET_IMPORT_ERROR}")
        self.connection = websocket.create_connection(websocket_url, timeout=10)
        self.next_id = 1

    def close(self) -> None:
        self.connection.close()

    def call(self, method: str, params: dict[str, Any] | None = None, timeout: int = 10) -> dict[str, Any]:
        call_id = self.next_id
        self.next_id += 1
        self.connection.settimeout(timeout)
        self.connection.send(json.dumps({"id": call_id, "method": method, "params": params or {}}))
        while True:
            response = json.loads(self.connection.recv())
            if response.get("id") != call_id:
                continue
            if "error" in response:
                raise CaptureError(f"Chromium DevTools fout bij {method}: {response['error']}")
            result = response.get("result", {})
            return result if isinstance(result, dict) else {}


def current_home() -> Path:
    if pwd is not None:
        return Path(pwd.getpwuid(os.getuid()).pw_dir)
    return Path.home()


def acquire_lock(state_dir: Path) -> int:
    state_dir.mkdir(parents=True, exist_ok=True)
    lock_file = state_dir / "screenshot-cache.lock"
    try:
        fd = os.open(str(lock_file), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError as exc:
        raise CaptureError("er loopt al een screenshotopname") from exc
    os.write(fd, str(os.getpid()).encode("ascii"))
    return fd


def release_lock(fd: int, state_dir: Path) -> None:
    try:
        os.close(fd)
    finally:
        try:
            (state_dir / "screenshot-cache.lock").unlink()
        except FileNotFoundError:
            pass


def log_line(log_file: Path, config: Any, line: str) -> None:
    now = datetime.now().astimezone()
    log_file.parent.mkdir(parents=True, exist_ok=True)
    prune_old_log_lines(log_file, config.log_retention_days, now)
    rotate_log_if_needed(log_file, config.log_max_bytes, "screenshot-cache.log.1")
    with log_file.open("a", encoding="utf-8") as handle:
        handle.write(f"{now.isoformat(timespec='seconds')} {line}\n")


def chromium_command(raw_config: dict[str, str], config: Any, work_dir: Path) -> list[str]:
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
        f"--remote-debugging-address=127.0.0.1",
        f"--remote-debugging-port={config.capture_debug_port}",
        f"--remote-allow-origins=http://127.0.0.1:{config.capture_debug_port}",
        f"--user-data-dir={work_dir / 'profile'}",
        f"--disk-cache-dir={work_dir / 'cache'}",
        f"--window-size={config.capture_width},{config.capture_height}",
        config.effective_url,
    ]


def start_chromium(raw_config: dict[str, str], config: Any, work_dir: Path) -> subprocess.Popen[bytes]:
    # Dit proces is eigendom van het capturescript. Alleen deze PID wordt later gestopt.
    return subprocess.Popen(
        chromium_command(raw_config, config, work_dir),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )


def stop_chromium(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.kill(process.pid, signal.SIGTERM)
        process.wait(timeout=5)


def wait_for_target(port: int, timeout_seconds: int) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    last_error = ""
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=3) as response:
                targets = json.loads(response.read().decode("utf-8"))
            for target in targets:
                if target.get("type") == "page" and target.get("webSocketDebuggerUrl"):
                    return target
        except (OSError, urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            last_error = str(exc)
        time.sleep(0.25)
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


def wait_ready(devtools: DevTools, timeout_seconds: int) -> None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        state = evaluate(devtools, "document.readyState", timeout=5)
        if state in {"interactive", "complete"}:
            return
        time.sleep(0.25)
    raise CaptureError("pagina werd niet tijdig geladen")


def current_url(devtools: DevTools) -> str:
    return str(evaluate(devtools, "location.href", timeout=5) or "")


def capture_png(devtools: DevTools, watermark_text: str) -> bytes:
    evaluate(devtools, watermark_script(watermark_text), timeout=5)
    try:
        result = devtools.call("Page.captureScreenshot", {"format": "png", "fromSurface": True}, timeout=30)
    finally:
        evaluate(devtools, remove_watermark_script(), timeout=5)
    data = result.get("data")
    if not isinstance(data, str) or not data:
        raise CaptureError("Chromium gaf geen screenshotdata terug")
    return base64.b64decode(data)


def stable_capture(devtools: DevTools, config: Any) -> tuple[bytes, str | None, float]:
    time.sleep(config.transition_wait_ms / 1000)
    first = capture_png(devtools, config.offline_watermark_text)
    first_url = current_url(devtools)
    time.sleep(config.stable_gap_ms / 1000)
    second = capture_png(devtools, config.offline_watermark_text)
    second_url = current_url(devtools)
    diff = byte_difference_percent(first, second)
    if diff > config.image_difference_percent:
        raise CaptureError(f"beeld is nog niet stabiel: verschil={diff:.2f}%")
    return second, slide_id_from_url(second_url or first_url), diff


def image_hash(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_player_files(version_dir: Path, manifest: dict[str, Any]) -> None:
    (version_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (version_dir / "index.html").write_text(
        """<!doctype html>
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
""",
        encoding="utf-8",
    )
    (version_dir / "player.css").write_text(
        """html, body {
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
""",
        encoding="utf-8",
    )
    (version_dir / "player.js").write_text(
        """(() => {
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
""",
        encoding="utf-8",
    )


def current_hashes(cache_root: Path) -> list[str]:
    current = cache_root / "current"
    manifest_file = current / "manifest.json"
    if not manifest_file.exists():
        return []
    try:
        manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return []
    hashes = []
    for image in manifest.get("images", []):
        image_path = current / str(image.get("file", ""))
        if image_path.is_file():
            hashes.append(image_hash(image_path.read_bytes()))
    return hashes


def publish_version(cache_root: Path, work_dir: Path, config: Any, manifest: dict[str, Any], new_hashes: list[str]) -> str:
    if new_hashes and new_hashes == current_hashes(cache_root):
        shutil.rmtree(work_dir, ignore_errors=True)
        return "unchanged"
    versions_dir = cache_root / "versions"
    versions_dir.mkdir(parents=True, exist_ok=True)
    version_dir = versions_dir / work_dir.name
    if version_dir.exists():
        shutil.rmtree(version_dir)
    shutil.move(str(work_dir), str(version_dir))
    ok, reason, _loaded = validate_cache_version(version_dir)
    if not ok:
        shutil.rmtree(version_dir, ignore_errors=True)
        raise CaptureError(f"nieuwe cacheversie is ongeldig: {reason}")
    atomic_activate_version(cache_root, version_dir, config.keep_versions)
    return "updated"


def capture_website(devtools: DevTools, config: Any, work_dir: Path) -> tuple[dict[str, Any], list[str]]:
    wait_ready(devtools, min(config.max_capture_seconds, 60))
    image, _slide_id, diff = stable_capture(devtools, config)
    images_dir = work_dir / "images"
    images_dir.mkdir(parents=True, exist_ok=True)
    image_file = images_dir / "latest.png"
    image_file.write_bytes(image)
    digest = image_hash(image)
    manifest = {
        "created_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "mode": "website",
        "source_url": sanitize_url_for_log(config.effective_url),
        "slide_seconds": max(1, DEFAULT_PRESENTATION_DELAY_MS // 1000),
        "images": [{"file": "images/latest.png", "hash": digest, "stable_difference_percent": round(diff, 2)}],
    }
    write_player_files(work_dir, manifest)
    return manifest, [digest]


def capture_presentation(devtools: DevTools, config: Any, work_dir: Path) -> tuple[dict[str, Any], list[str]]:
    wait_ready(devtools, min(config.max_capture_seconds, 60))
    delay_ms = parse_delayms(config.effective_url)
    slide_seconds = max(1, round(delay_ms / 1000))
    deadline = time.monotonic() + config.max_capture_seconds
    images_dir = work_dir / "images"
    images_dir.mkdir(parents=True, exist_ok=True)
    seen_slide_ids: set[str] = set()
    seen_hashes: set[str] = set()
    images: list[dict[str, Any]] = []
    hashes: list[str] = []
    first_key: str | None = None
    attempts = 0

    while time.monotonic() < deadline and len(images) < config.max_slides:
        attempts += 1
        try:
            image, slide_id, diff = stable_capture(devtools, config)
        except CaptureError:
            time.sleep(max(1, delay_ms / 1000 / 2))
            continue
        digest = image_hash(image)
        key = slide_id or digest
        if first_key is None:
            first_key = key
        elif key == first_key and len(images) >= 2:
            break
        if slide_id and slide_id in seen_slide_ids:
            break
        if digest in seen_hashes:
            if len(images) == 1 and time.monotonic() < deadline:
                waited_until = time.monotonic() + config.single_slide_confirm_seconds
                while time.monotonic() < waited_until:
                    time.sleep(min(1.0, waited_until - time.monotonic()))
                break
            if len(images) >= 1:
                break
        filename = f"images/slide-{len(images) + 1:03d}.png"
        (work_dir / filename).write_bytes(image)
        seen_hashes.add(digest)
        if slide_id:
            seen_slide_ids.add(slide_id)
        hashes.append(digest)
        images.append({
            "file": filename,
            "hash": digest,
            "slide_id": slide_id or "",
            "stable_difference_percent": round(diff, 2),
        })
        time.sleep(max(1.0, delay_ms / 1000))

    if not images:
        raise CaptureError("geen stabiele presentatiedia gevonden")
    manifest = {
        "created_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "mode": "presentation",
        "source_url": sanitize_url_for_log(config.effective_url),
        "slide_seconds": slide_seconds,
        "images": images,
        "capture_attempts": attempts,
    }
    write_player_files(work_dir, manifest)
    return manifest, hashes


def run_capture(args: argparse.Namespace) -> int:
    start = time.monotonic()
    raw_config = read_config(args.config_file)
    config = build_content_config(raw_config)
    home = Path(args.home).resolve() if args.home else current_home()
    cache_root = Path(args.cache_root).resolve() if args.cache_root else screenshot_cache_root(home)
    state_dir = Path(args.state_dir).resolve() if args.state_dir else screenshot_state_dir(home)
    log_file = state_dir / "screenshot-cache.log"

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
    lock_fd = acquire_lock(state_dir)
    work_root = safe_work_dir(cache_root)
    process: subprocess.Popen[bytes] | None = None
    try:
        process = start_chromium(raw_config, config, work_root)
        target = wait_for_target(config.capture_debug_port, min(config.max_capture_seconds, 60))
        devtools = DevTools(str(target["webSocketDebuggerUrl"]))
        try:
            if config.mode == "website":
                manifest, hashes = capture_website(devtools, config, work_root)
            else:
                manifest, hashes = capture_presentation(devtools, config, work_root)
        finally:
            devtools.close()
        cache_state = publish_version(cache_root, work_root, config, manifest, hashes)
        duration = round(time.monotonic() - start, 1)
        log_line(
            log_file,
            config,
            " ".join([
                f"mode={config.mode}",
                f"url={sanitize_url_for_log(config.effective_url)}",
                f"found={len(hashes)}",
                f"saved={len(hashes)}",
                f"cache={cache_state}",
                f"duration={duration}",
            ]),
        )
        return 0
    except Exception:
        shutil.rmtree(work_root, ignore_errors=True)
        raise
    finally:
        if process is not None:
            stop_chromium(process)
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
        raw_config = read_config(args.config_file)
        config = build_content_config(raw_config)
        home = Path(args.home).resolve() if args.home else current_home()
        state_dir = Path(args.state_dir).resolve() if args.state_dir else screenshot_state_dir(home)
        duration = round(time.monotonic(), 1)
        log_line(state_dir / "screenshot-cache.log", config, f"mode={config.mode} cache=preserved reason={str(exc).replace(' ', '_')} duration={duration}")
        print(f"Fout: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
