#!/usr/bin/env python3
"""Controleert de Chromium-kiosk en beheert betrouwbaar offline gedrag."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

try:
    import pwd
except ImportError:  # pragma: no cover - alleen relevant voor lokale Windows-tests
    pwd = None  # type: ignore[assignment]

try:
    import websocket
except ImportError as exc:  # pragma: no cover - afhankelijk van het Pi-pakket
    websocket = None
    WEBSOCKET_IMPORT_ERROR = exc
else:
    WEBSOCKET_IMPORT_ERROR = None

from digitalsignage_config import (
    build_content_config,
    screenshot_cache_index_url,
    validate_current_cache,
)


CONFIG_FILE = Path(os.environ.get("CONFIG_FILE", "/etc/digitalsignage/digitalsignage.conf"))
KIOSK_SERVICE = "digitalsignage-kiosk.service"

DEFAULTS: dict[str, str] = {
    "CONTENT_MODE": "presentation",
    "CONTENT_URL": "",
    "PRESENTATION_URL": "",
    "SCREENSHOT_CACHE_ENABLED": "true",
    "OFFLINE_URL": "file:///opt/digitalsignage/web/offline/index.html",
    "OFFLINE_PAGE_URL": "file:///opt/digitalsignage/offline/index.html",
    "OFFLINE_PAGE_ENABLED": "true",
    "OFFLINE_AFTER_SECONDS": "45",
    "ONLINE_CONFIRM_SECONDS": "30",
    "CONNECTIVITY_CHECK_URL": "https://clients3.google.com/generate_204",
    "CONNECTIVITY_TIMEOUT_SECONDS": "5",
    "REMOTE_DEBUG_HOST": "127.0.0.1",
    "REMOTE_DEBUG_PORT": "9222",
    "KIOSK_USER": "",
    "HEALTH_FAILURE_THRESHOLD": "3",
    "HEALTH_RESTART_COOLDOWN_SECONDS": "600",
    "HEALTH_HTTP_TIMEOUT_SECONDS": "5",
    "HEALTH_STARTUP_GRACE_SECONDS": "90",
    "HEALTH_LOG_RETENTION_DAYS": "3",
    "HEALTH_LOG_MAX_BYTES": str(5 * 1024 * 1024),
}

DEFAULT_STATE: dict[str, Any] = {
    "consecutive_failures": 0,
    "last_check": None,
    "last_success": None,
    "last_failure": None,
    "last_restart": None,
    "last_restart_reason": None,
}

DEFAULT_CONNECTIVITY_STATE: dict[str, Any] = {
    "STATUS": "online",
    "OFFLINE_SINCE": 0,
    "ONLINE_SINCE": 0,
    "OFFLINE_PAGE_SHOWN": False,
}


@dataclass
class HealthConfig:
    presentation_url: str
    content_mode: str
    content_url: str
    effective_url: str
    screenshot_cache_enabled: bool
    offline_url: str
    offline_page_url: str
    offline_page_enabled: bool
    offline_after_seconds: int
    online_confirm_seconds: int
    connectivity_check_url: str
    connectivity_timeout_seconds: int
    remote_debug_host: str
    remote_debug_port: int
    kiosk_user: str
    failure_threshold: int
    restart_cooldown_seconds: int
    http_timeout_seconds: int
    startup_grace_seconds: int
    log_retention_days: int
    log_max_bytes: int
    warnings: list[str] = field(default_factory=list)


@dataclass
class CheckResult:
    ok: bool
    health: str
    service: str = "unknown"
    pid: int = 0
    debug_port: str = "unknown"
    page: str = "unknown"
    page_url: str = ""
    websocket_url: str = ""
    reason: str = "none"
    startup_grace: bool = False


@dataclass
class ConnectivityResult:
    online: bool
    status: str
    nm: str
    http: str
    reason: str


@dataclass
class ConnectivityAction:
    state: dict[str, Any]
    action: str
    reason: str


def now() -> datetime:
    return datetime.now().astimezone()


def read_config(path: Path) -> dict[str, str]:
    """Lees KEY=VALUE-regels zonder shell-evaluatie of expansion."""
    config = dict(DEFAULTS)
    if not path.exists():
        return config

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key.replace("_", "").isalnum():
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        config[key] = value
    return config


def int_config(config: dict[str, str], key: str, default: int, minimum: int = 1, warnings: list[str] | None = None) -> int:
    try:
        value = int(str(config.get(key, default)).strip())
    except (TypeError, ValueError):
        if warnings is not None:
            warnings.append(f"ongeldige configuratiewaarde voor {key}; standaardwaarde {default} wordt gebruikt")
        return default
    if value < minimum:
        if warnings is not None:
            warnings.append(f"ongeldige configuratiewaarde voor {key}; standaardwaarde {default} wordt gebruikt")
        return default
    return value


def bool_config(config: dict[str, str], key: str, default: bool, warnings: list[str] | None = None) -> bool:
    value = str(config.get(key, str(default))).strip().lower()
    if value in {"1", "true", "yes", "ja", "on"}:
        return True
    if value in {"0", "false", "no", "nee", "off"}:
        return False
    if warnings is not None:
        warnings.append(f"ongeldige configuratiewaarde voor {key}; standaardwaarde {str(default).lower()} wordt gebruikt")
    return default


def build_config(raw: dict[str, str]) -> HealthConfig:
    warnings: list[str] = []
    content = build_content_config(raw)
    warnings.extend(content.warnings)
    return HealthConfig(
        presentation_url=raw.get("PRESENTATION_URL", "").strip(),
        content_mode=content.mode,
        content_url=content.content_url,
        effective_url=content.effective_url,
        screenshot_cache_enabled=content.screenshot_cache_enabled,
        offline_url=raw.get("OFFLINE_URL", DEFAULTS["OFFLINE_URL"]).strip(),
        offline_page_url=raw.get("OFFLINE_PAGE_URL", DEFAULTS["OFFLINE_PAGE_URL"]).strip() or DEFAULTS["OFFLINE_PAGE_URL"],
        offline_page_enabled=bool_config(raw, "OFFLINE_PAGE_ENABLED", True, warnings),
        offline_after_seconds=int_config(raw, "OFFLINE_AFTER_SECONDS", 45, minimum=1, warnings=warnings),
        online_confirm_seconds=int_config(raw, "ONLINE_CONFIRM_SECONDS", 30, minimum=0, warnings=warnings),
        connectivity_check_url=raw.get("CONNECTIVITY_CHECK_URL", DEFAULTS["CONNECTIVITY_CHECK_URL"]).strip() or DEFAULTS["CONNECTIVITY_CHECK_URL"],
        connectivity_timeout_seconds=int_config(raw, "CONNECTIVITY_TIMEOUT_SECONDS", 5, minimum=1, warnings=warnings),
        remote_debug_host=raw.get("REMOTE_DEBUG_HOST", DEFAULTS["REMOTE_DEBUG_HOST"]).strip() or DEFAULTS["REMOTE_DEBUG_HOST"],
        remote_debug_port=int_config(raw, "REMOTE_DEBUG_PORT", 9222, warnings=warnings),
        kiosk_user=raw.get("KIOSK_USER", "").strip() or current_user_name(),
        failure_threshold=int_config(raw, "HEALTH_FAILURE_THRESHOLD", 3, warnings=warnings),
        restart_cooldown_seconds=int_config(raw, "HEALTH_RESTART_COOLDOWN_SECONDS", 600, warnings=warnings),
        http_timeout_seconds=int_config(raw, "HEALTH_HTTP_TIMEOUT_SECONDS", 5, warnings=warnings),
        startup_grace_seconds=int_config(raw, "HEALTH_STARTUP_GRACE_SECONDS", 90, minimum=0, warnings=warnings),
        log_retention_days=int_config(raw, "HEALTH_LOG_RETENTION_DAYS", 3, warnings=warnings),
        log_max_bytes=int_config(raw, "HEALTH_LOG_MAX_BYTES", 5 * 1024 * 1024, warnings=warnings),
        warnings=warnings,
    )


def kiosk_home(kiosk_user: str) -> Path:
    """Bepaal de homefolder via de systeemaccountdatabase, nooit via vaste paden."""
    if pwd is None:
        raise RuntimeError("pwd-module ontbreekt; kiosk-homefolder kan alleen op Linux bepaald worden")
    try:
        return Path(pwd.getpwnam(kiosk_user).pw_dir)
    except KeyError as exc:
        raise RuntimeError(f"Kioskgebruiker bestaat niet: {kiosk_user}") from exc


def current_user_name() -> str:
    if pwd is not None:
        return pwd.getpwuid(os.getuid()).pw_name
    return os.environ.get("USERNAME") or os.environ.get("USER") or "unknown"


def state_dir_for(config: HealthConfig) -> Path:
    return kiosk_home(config.kiosk_user) / ".local" / "state" / "digitalsignage"


def load_state(path: Path) -> tuple[dict[str, Any], str | None]:
    if not path.exists():
        return dict(DEFAULT_STATE), None
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(loaded, dict):
            raise ValueError("statebestand bevat geen JSON-object")
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        return dict(DEFAULT_STATE), f"statebestand is ongeldig en wordt hersteld: {exc}"

    state = dict(DEFAULT_STATE)
    state.update(loaded)
    try:
        state["consecutive_failures"] = int(state.get("consecutive_failures", 0))
    except (TypeError, ValueError):
        state["consecutive_failures"] = 0
    if state["consecutive_failures"] < 0:
        state["consecutive_failures"] = 0
    return state, None


def atomic_write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, path)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def valid_unix_timestamp(value: Any, reference_timestamp: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return 0
    if parsed < 0 or parsed > reference_timestamp + 60:
        return 0
    return parsed


def parse_bool_state(value: str) -> bool | None:
    normalized = value.strip().lower()
    if normalized == "true":
        return True
    if normalized == "false":
        return False
    return None


def load_connectivity_state(path: Path, reference_timestamp: int | None = None) -> tuple[dict[str, Any], str | None]:
    reference = int(time.time()) if reference_timestamp is None else reference_timestamp
    state = dict(DEFAULT_CONNECTIVITY_STATE)
    warning = None
    if not path.exists():
        return state, None
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        return state, f"connectiviteitsstate is onleesbaar en wordt hersteld: {exc}"

    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if key == "STATUS" and value in {"online", "offline"}:
            state[key] = value
        elif key in {"OFFLINE_SINCE", "ONLINE_SINCE"}:
            state[key] = valid_unix_timestamp(value, reference)
        elif key == "OFFLINE_PAGE_SHOWN":
            parsed_bool = parse_bool_state(value)
            if parsed_bool is not None:
                state[key] = parsed_bool
    return state, warning


def atomic_write_connectivity_state(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    lines = [
        f"STATUS={data.get('STATUS', 'online') if data.get('STATUS') in {'online', 'offline'} else 'online'}",
        f"OFFLINE_SINCE={int(data.get('OFFLINE_SINCE', 0) or 0)}",
        f"ONLINE_SINCE={int(data.get('ONLINE_SINCE', 0) or 0)}",
        f"OFFLINE_PAGE_SHOWN={'true' if bool(data.get('OFFLINE_PAGE_SHOWN', False)) else 'false'}",
    ]
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, path)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def parse_timestamp(value: object) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed


def parse_google_slides_id(url: str) -> str | None:
    parsed = urllib.parse.urlparse(url)
    match = re.search(r"/presentation/d/([^/]+)", parsed.path)
    return match.group(1) if match else None


def normalized_url(url: str) -> tuple[str, str, str, str]:
    parsed = urllib.parse.urlparse(url)
    return (
        parsed.scheme.lower(),
        parsed.netloc.lower(),
        parsed.path.rstrip("/"),
        parsed.query,
    )


def same_url(left: str, right: str) -> bool:
    return bool(left and right and normalized_url(left) == normalized_url(right))


def is_valid_kiosk_url(target_url: str, presentation_url: str, offline_url: str, effective_url: str = "", screenshot_cache_url: str = "") -> str | None:
    if not target_url:
        return None
    if offline_url and same_url(target_url, offline_url):
        return "offline"
    if screenshot_cache_url and same_url(target_url, screenshot_cache_url):
        return "screenshot_cache"
    if effective_url and same_url(target_url, effective_url):
        return "content"
    if presentation_url and same_url(target_url, presentation_url):
        return "presentation"

    target_slides_id = parse_google_slides_id(target_url)
    config_slides_id = parse_google_slides_id(presentation_url)
    if target_slides_id and config_slides_id and target_slides_id == config_slides_id:
        return "google_slides"
    return None


def run_systemctl_show() -> dict[str, str]:
    result = subprocess.run(
        [
            "systemctl",
            "--user",
            "show",
            KIOSK_SERVICE,
            "--property=LoadState",
            "--property=ActiveState",
            "--property=SubState",
            "--property=MainPID",
            "--property=ExecMainStatus",
            "--property=ActiveEnterTimestampMonotonic",
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=8,
    )
    if result.returncode != 0:
        raise RuntimeError(f"systemctl --user show faalt: {result.stderr.strip() or result.stdout.strip()}")
    properties: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            properties[key] = value
    return properties


def current_uptime_seconds() -> float:
    try:
        return float(Path("/proc/uptime").read_text(encoding="utf-8").split()[0])
    except (OSError, ValueError, IndexError):
        return time.monotonic()


def service_in_startup_grace(properties: dict[str, str], startup_grace_seconds: int) -> bool:
    if startup_grace_seconds <= 0:
        return False
    try:
        active_usec = int(properties.get("ActiveEnterTimestampMonotonic", "0"))
    except ValueError:
        active_usec = 0
    if active_usec <= 0:
        return False
    active_seconds = active_usec / 1_000_000
    return 0 <= current_uptime_seconds() - active_seconds < startup_grace_seconds


def process_is_chromium(pid: int) -> bool:
    cmdline_path = Path("/proc") / str(pid) / "cmdline"
    try:
        cmdline = cmdline_path.read_bytes().replace(b"\x00", b" ").decode("utf-8", errors="replace").lower()
    except OSError:
        return False
    return "chromium" in cmdline


def fetch_targets(config: HealthConfig) -> list[dict[str, Any]]:
    url = f"http://{config.remote_debug_host}:{config.remote_debug_port}/json"
    try:
        with urllib.request.urlopen(url, timeout=config.http_timeout_seconds) as response:
            data = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as exc:
        raise RuntimeError(f"debugpoort onbereikbaar of ongeldig: {exc}") from exc
    if not isinstance(data, list):
        raise RuntimeError("debugpoort gaf geen JSON-lijst terug")
    return data


def find_valid_page(targets: list[dict[str, Any]], config: HealthConfig) -> tuple[str | None, str, str]:
    saw_page = False
    first_page_url = ""
    first_websocket_url = ""
    for target in targets:
        if target.get("type") != "page":
            continue
        saw_page = True
        target_url = str(target.get("url", "")).strip()
        websocket_url = str(target.get("webSocketDebuggerUrl", "")).strip()
        if not first_page_url:
            first_page_url = target_url
            first_websocket_url = websocket_url
        if not target_url or not websocket_url:
            continue
        try:
            cache_url = screenshot_cache_index_url(kiosk_home(config.kiosk_user))
        except RuntimeError:
            cache_url = ""
        page_type = is_valid_kiosk_url(target_url, config.presentation_url, config.offline_page_url, config.effective_url, cache_url)
        if page_type:
            return page_type, target_url, websocket_url
    if not saw_page:
        raise RuntimeError("geen Chromium page-target gevonden")
    return None, first_page_url, first_websocket_url


def evaluate_health(config: HealthConfig, simulate_debug_failure: bool = False) -> CheckResult:
    try:
        properties = run_systemctl_show()
    except (subprocess.TimeoutExpired, RuntimeError) as exc:
        return CheckResult(False, "failed", service="unknown", reason=f"service_check_failed:{exc}")

    service_state = properties.get("ActiveState", "unknown")
    try:
        pid = int(properties.get("MainPID", "0"))
    except ValueError:
        pid = 0

    if properties.get("LoadState") != "loaded" or service_state != "active" or pid <= 0:
        return CheckResult(False, "failed", service=service_state, pid=pid, reason="service_unhealthy")

    startup_grace = service_in_startup_grace(properties, config.startup_grace_seconds)

    if not Path("/proc", str(pid)).exists():
        return CheckResult(False, "warning" if startup_grace else "failed", service=service_state, pid=pid, reason="mainpid_missing", startup_grace=startup_grace)
    if not process_is_chromium(pid):
        return CheckResult(False, "failed", service=service_state, pid=pid, reason="mainpid_not_chromium", startup_grace=startup_grace)

    if simulate_debug_failure:
        return CheckResult(False, "warning", service=service_state, pid=pid, debug_port="failed", reason="simulated_debug_failure")

    try:
        targets = fetch_targets(config)
    except RuntimeError as exc:
        return CheckResult(False, "warning" if startup_grace else "failed", service=service_state, pid=pid, debug_port="failed", reason="debug_port_unreachable", startup_grace=startup_grace)

    try:
        page, page_url, websocket_url = find_valid_page(targets, config)
    except RuntimeError as exc:
        return CheckResult(False, "warning" if startup_grace else "failed", service=service_state, pid=pid, debug_port="ok", reason=str(exc).replace(" ", "_"), startup_grace=startup_grace)
    if page is None:
        return CheckResult(False, "warning" if startup_grace else "failed", service=service_state, pid=pid, debug_port="ok", page_url=page_url, websocket_url=websocket_url, reason="no_valid_kiosk_page", startup_grace=startup_grace)

    return CheckResult(True, "ok", service=service_state, pid=pid, debug_port="ok", page=page, page_url=page_url, websocket_url=websocket_url)


def check_networkmanager() -> tuple[bool, str, str]:
    try:
        result = subprocess.run(
            ["nmcli", "-t", "-f", "CONNECTIVITY", "general"],
            check=False,
            capture_output=True,
            text=True,
            timeout=8,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False, "failed", "networkmanager_failed"
    if result.returncode != 0:
        return False, "failed", "networkmanager_failed"
    status = (result.stdout.splitlines()[0] if result.stdout.splitlines() else "unknown").strip().lower()
    if status == "full":
        return True, "full", "none"
    if status in {"limited", "portal", "none", "unknown"}:
        return False, status, f"networkmanager_{status}"
    return False, "unknown", "networkmanager_unknown"


def check_http(config: HealthConfig) -> tuple[bool, str, str]:
    try:
        result = subprocess.run(
            [
                "curl",
                "--silent",
                "--show-error",
                "--fail",
                "--max-time",
                str(config.connectivity_timeout_seconds),
                "--output",
                "/dev/null",
                config.connectivity_check_url,
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=config.connectivity_timeout_seconds + 2,
        )
    except subprocess.TimeoutExpired:
        return False, "timeout", "http_timeout"
    except OSError:
        return False, "failed", "http_failed"
    if result.returncode == 0:
        return True, "ok", "none"
    if result.returncode == 28:
        return False, "timeout", "http_timeout"
    return False, "failed", "http_failed"


def evaluate_connectivity(config: HealthConfig) -> ConnectivityResult:
    nm_ok, nm_status, nm_reason = check_networkmanager()
    http_ok, http_status, http_reason = check_http(config)
    online = nm_ok and http_ok
    reason = "none" if online else (nm_reason if not nm_ok else http_reason)
    return ConnectivityResult(online, "online" if online else "offline", nm_status, http_status, reason)


def can_restart(state: dict[str, Any], config: HealthConfig, reference_time: datetime) -> bool:
    last_restart = parse_timestamp(state.get("last_restart"))
    if last_restart is None:
        return True
    return reference_time - last_restart >= timedelta(seconds=config.restart_cooldown_seconds)


def restart_kiosk() -> tuple[bool, str]:
    try:
        result = subprocess.run(
            ["systemctl", "--user", "restart", KIOSK_SERVICE],
            check=False,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except subprocess.TimeoutExpired as exc:
        return False, f"restart-timeout: {exc}"
    message = " ".join(part.strip() for part in (result.stdout, result.stderr) if part.strip())
    if result.returncode == 0:
        return True, message
    return False, message or f"systemctl exitcode {result.returncode}"


def navigate_page(websocket_url: str, target_url: str) -> tuple[bool, str]:
    if not websocket_url:
        return False, "webSocketDebuggerUrl ontbreekt"
    if websocket is None:
        return False, f"Pythonpakket websocket ontbreekt: {WEBSOCKET_IMPORT_ERROR}"

    ws = None
    try:
        ws = websocket.create_connection(websocket_url, timeout=5)
        ws.send(json.dumps({"id": 1, "method": "Page.navigate", "params": {"url": target_url}}))
        response = json.loads(ws.recv())
        if response.get("id") != 1:
            return False, "onverwachte response van Chromium DevTools"
        if "error" in response:
            return False, f"Chromium DevTools gaf een fout: {response['error']}"
    except (OSError, websocket.WebSocketException, json.JSONDecodeError) as exc:
        return False, f"navigatie via Chromium DevTools mislukt: {exc}"
    finally:
        if ws is not None:
            ws.close()
    return True, "ok"


def navigate_if_needed(result: CheckResult, target_url: str) -> tuple[bool, str]:
    if same_url(result.page_url, target_url):
        return True, "already_visible"
    return navigate_page(result.websocket_url, target_url)


def valid_screenshot_cache_url(config: HealthConfig) -> tuple[str, str]:
    if not config.screenshot_cache_enabled:
        return "", "screenshot_cache_disabled"
    try:
        home = kiosk_home(config.kiosk_user)
    except RuntimeError:
        return "", "screenshot_cache_unavailable"
    ok, reason, manifest = validate_current_cache(home)
    if not ok:
        return "", "screenshot_cache_unavailable"
    cache_mode = str(manifest.get("mode", "")) if manifest else ""
    if cache_mode not in {"presentation", "website"}:
        return "", "screenshot_cache_unavailable"
    return screenshot_cache_index_url(home), "ok"


def process_connectivity(
    state: dict[str, Any],
    connectivity: ConnectivityResult,
    browser: CheckResult,
    config: HealthConfig,
    reference_timestamp: int,
    allow_navigation: bool,
) -> ConnectivityAction:
    state = dict(state)
    offline_since = valid_unix_timestamp(state.get("OFFLINE_SINCE", 0), reference_timestamp)
    online_since = valid_unix_timestamp(state.get("ONLINE_SINCE", 0), reference_timestamp)

    if not connectivity.online:
        if offline_since == 0:
            offline_since = reference_timestamp
        state.update({
            "STATUS": "offline",
            "OFFLINE_SINCE": offline_since,
            "ONLINE_SINCE": 0,
            "OFFLINE_PAGE_SHOWN": bool(state.get("OFFLINE_PAGE_SHOWN", False)),
        })
        if not config.offline_page_enabled:
            return ConnectivityAction(state, "keep_current_page", "offline_page_disabled")
        offline_duration = max(0, reference_timestamp - offline_since)
        if offline_duration < config.offline_after_seconds:
            return ConnectivityAction(state, "keep_current_page", "offline_grace_period")
        cache_url, cache_reason = valid_screenshot_cache_url(config)
        offline_target_url = cache_url or config.offline_page_url
        offline_action = "show_screenshot_cache" if cache_url else "show_offline_page"
        if bool(state.get("OFFLINE_PAGE_SHOWN", False)) and same_url(browser.page_url, offline_target_url):
            return ConnectivityAction(state, "none", "offline_page_already_visible")
        if not allow_navigation or not browser.ok:
            return ConnectivityAction(state, offline_action, "offline_threshold_reached" if cache_url else cache_reason)
        navigation_ok, navigation_reason = navigate_if_needed(browser, offline_target_url)
        if navigation_ok:
            state["OFFLINE_PAGE_SHOWN"] = True
            if navigation_reason == "already_visible":
                return ConnectivityAction(state, "none", "offline_page_already_visible")
            return ConnectivityAction(state, offline_action, "offline_threshold_reached" if cache_url else cache_reason)
        return ConnectivityAction(state, "navigation_failed", "offline_navigation_failed")

    if offline_since == 0 and not bool(state.get("OFFLINE_PAGE_SHOWN", False)) and online_since == 0:
        state.update({
            "STATUS": "online",
            "OFFLINE_SINCE": 0,
            "ONLINE_SINCE": 0,
            "OFFLINE_PAGE_SHOWN": False,
        })
        return ConnectivityAction(state, "none", "none")

    if online_since == 0:
        online_since = reference_timestamp
        state.update({
            "STATUS": "offline",
            "OFFLINE_SINCE": offline_since,
            "ONLINE_SINCE": online_since,
            "OFFLINE_PAGE_SHOWN": bool(state.get("OFFLINE_PAGE_SHOWN", False)),
        })
        return ConnectivityAction(state, "wait_online_confirmation", "connectivity_recovering")

    online_duration = max(0, reference_timestamp - online_since)
    if online_duration < config.online_confirm_seconds:
        state.update({
            "STATUS": "offline",
            "OFFLINE_SINCE": offline_since,
            "ONLINE_SINCE": online_since,
            "OFFLINE_PAGE_SHOWN": bool(state.get("OFFLINE_PAGE_SHOWN", False)),
        })
        return ConnectivityAction(state, "wait_online_confirmation", "connectivity_recovering")

    reset_state = {
        "STATUS": "online",
        "OFFLINE_SINCE": 0,
        "ONLINE_SINCE": 0,
        "OFFLINE_PAGE_SHOWN": False,
    }
    if same_url(browser.page_url, config.effective_url):
        return ConnectivityAction(reset_state, "none", "kiosk_page_already_visible")
    if not allow_navigation or not browser.ok:
        return ConnectivityAction(state, "show_kiosk_page", "connectivity_restored")
    navigation_ok, navigation_reason = navigate_if_needed(browser, config.effective_url)
    if navigation_ok:
        if navigation_reason == "already_visible":
            return ConnectivityAction(reset_state, "none", "kiosk_page_already_visible")
        return ConnectivityAction(reset_state, "show_kiosk_page", "connectivity_restored")
    return ConnectivityAction(state, "navigation_failed", "kiosk_navigation_failed")


def parse_log_time(line: str) -> datetime | None:
    first = line.split(maxsplit=1)[0] if line.strip() else ""
    if not first:
        return None
    return parse_timestamp(first)


def prune_old_lines(log_file: Path, retention_days: int, reference_time: datetime) -> None:
    if not log_file.exists():
        return
    cutoff = reference_time - timedelta(days=retention_days)
    kept: list[str] = []
    for line in log_file.read_text(encoding="utf-8").splitlines():
        logged_at = parse_log_time(line)
        if logged_at is None or logged_at >= cutoff:
            kept.append(line)
    log_file.write_text("\n".join(kept) + ("\n" if kept else ""), encoding="utf-8")


def rotate_log_if_needed(log_file: Path, max_bytes: int) -> None:
    if not log_file.exists() or log_file.stat().st_size < max_bytes:
        return
    rotated = log_file.with_name("health.log.1")
    if rotated.exists():
        rotated.unlink()
    log_file.rename(rotated)


def write_log_line(log_file: Path, config: HealthConfig, line: str, reference_time: datetime) -> None:
    log_file.parent.mkdir(parents=True, exist_ok=True)
    prune_old_lines(log_file, config.log_retention_days, reference_time)
    rotate_log_if_needed(log_file, config.log_max_bytes)
    with log_file.open("a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def apply_result(
    state: dict[str, Any],
    result: CheckResult,
    config: HealthConfig,
    check_only: bool,
    reference_time: datetime,
) -> tuple[dict[str, Any], str, str | None, int]:
    state = dict(state)
    state["last_check"] = reference_time.isoformat(timespec="seconds")
    action = "none"
    restart_skipped: str | None = None
    exitcode = 0 if result.ok else 1

    if result.ok:
        state["consecutive_failures"] = 0
        state["last_success"] = state["last_check"]
        return state, action, restart_skipped, exitcode

    state["last_failure"] = state["last_check"]
    if result.startup_grace:
        state["consecutive_failures"] = 0
        return state, action, restart_skipped, exitcode

    state["consecutive_failures"] = int(state.get("consecutive_failures", 0)) + 1
    if state["consecutive_failures"] < config.failure_threshold:
        return state, action, restart_skipped, exitcode

    if check_only:
        restart_skipped = "check_only"
        return state, action, restart_skipped, exitcode

    if not can_restart(state, config, reference_time):
        restart_skipped = "cooldown"
        return state, action, restart_skipped, exitcode

    restart_ok, message = restart_kiosk()
    if not restart_ok:
        print(f"Fout: herstelactie mislukt: {message}", file=sys.stderr)
        return state, "restart_failed", None, 3

    action = "restart"
    state["last_restart"] = state["last_check"]
    state["last_restart_reason"] = result.reason
    state["consecutive_failures"] = 0
    return state, action, restart_skipped, exitcode


def log_line(
    reference_time: datetime,
    result: CheckResult,
    connectivity: ConnectivityResult,
    failures: int,
    action: str,
    restart_skipped: str | None,
    reason: str,
    cache_mode: str = "",
) -> str:
    health_value = result.health
    if result.ok and not connectivity.online:
        health_value = "warning"
    parts = [
        reference_time.isoformat(timespec="seconds"),
        f"health={health_value}",
    ]
    if result.startup_grace:
        parts.append("startup_grace=true")
    parts.extend([
        f"service={result.service}",
        f"pid={result.pid}",
        f"debug_port={result.debug_port}",
        f"page={result.page}",
        f"content_mode={cache_mode}",
        f"network={connectivity.status}",
        f"nm={connectivity.nm}",
        f"http={connectivity.http}",
        f"failures={failures}",
        f"action={action if action != 'restart_failed' else 'restart'}",
        f"reason={reason}",
    ])
    if connectivity.reason != "none" and connectivity.reason != reason:
        parts.append(f"network_reason={connectivity.reason}")
    if restart_skipped:
        parts.append(f"restart_skipped={restart_skipped}")
    if action == "show_screenshot_cache":
        parts.append(f"cache_mode={cache_mode}")
    return " ".join(parts)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Controleer de Digital Signage-kiosk.")
    parser.add_argument("--check-only", action="store_true", help="Controleer zonder herstelactie uit te voeren.")
    parser.add_argument("--simulate-debug-failure", action="store_true", help="Simuleer een debugpoortfout zonder restart.")
    parser.add_argument("--state-dir", type=Path, default=None, help="Alternatieve statusmap voor tests.")
    parser.add_argument("--connectivity-only", action="store_true", help="Alleen connectiviteit verwerken, zonder browsernavigatie.")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    raw_config = read_config(CONFIG_FILE)
    config = build_config(raw_config)

    try:
        state_dir = args.state_dir if args.state_dir is not None else state_dir_for(config)
    except RuntimeError as exc:
        print(f"Fout: {exc}", file=sys.stderr)
        return 2

    if args.simulate_debug_failure and args.state_dir is None:
        state_dir = Path(tempfile.mkdtemp(prefix="digitalsignage-health-test-"))
        print(f"Waarschuwing: simulatie gebruikt tijdelijke statusmap: {state_dir}", file=sys.stderr)

    state_dir.mkdir(parents=True, exist_ok=True)
    state_file = state_dir / "health-state.json"
    connectivity_file = state_dir / "connectivity.state"
    log_file = state_dir / "health.log"
    state, warning = load_state(state_file)
    if warning:
        print(f"Waarschuwing: {warning}", file=sys.stderr)
    reference_time = now()
    reference_timestamp = int(reference_time.timestamp())
    connectivity_state, connectivity_warning = load_connectivity_state(connectivity_file, reference_timestamp)
    if connectivity_warning:
        print(f"Waarschuwing: {connectivity_warning}", file=sys.stderr)
    for config_warning in config.warnings:
        print(f"Waarschuwing: {config_warning}", file=sys.stderr)

    result = evaluate_health(config, simulate_debug_failure=args.simulate_debug_failure)
    connectivity = evaluate_connectivity(config)
    if result.startup_grace and not result.ok:
        print(f"Waarschuwing: kiosk zit in startup-grace; geen herstelactie voor {result.reason}", file=sys.stderr)
    elif not result.ok:
        print(f"Fout: health-check faalt: {result.reason}", file=sys.stderr)

    connectivity_action = process_connectivity(
        connectivity_state,
        connectivity,
        result,
        config,
        reference_timestamp,
        allow_navigation=not (args.check_only or args.simulate_debug_failure or args.connectivity_only),
    )

    new_state, browser_action, restart_skipped, exitcode = apply_result(
        state,
        result,
        config,
        check_only=args.check_only or args.simulate_debug_failure,
        reference_time=reference_time,
    )
    atomic_write_json(state_file, new_state)
    atomic_write_connectivity_state(connectivity_file, connectivity_action.state)

    action = browser_action if browser_action != "none" else connectivity_action.action
    reason = result.reason if browser_action != "none" or not result.ok else connectivity_action.reason
    line = log_line(reference_time, result, connectivity, int(new_state.get("consecutive_failures", 0)), action, restart_skipped, reason, config.content_mode)
    write_log_line(log_file, config, line, reference_time)
    print(line)
    return exitcode


if __name__ == "__main__":
    raise SystemExit(main())
