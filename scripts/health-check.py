#!/usr/bin/env python3
"""Controleert de Chromium-kiosk en herstelt gecontroleerd bij herhaalde fouten."""

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
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

try:
    import pwd
except ImportError:  # pragma: no cover - alleen relevant voor lokale Windows-tests
    pwd = None  # type: ignore[assignment]


CONFIG_FILE = Path(os.environ.get("CONFIG_FILE", "/etc/digitalsignage/digitalsignage.conf"))
KIOSK_SERVICE = "digitalsignage-kiosk.service"

DEFAULTS: dict[str, str] = {
    "PRESENTATION_URL": "",
    "OFFLINE_URL": "file:///opt/digitalsignage/web/offline/index.html",
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


@dataclass
class HealthConfig:
    presentation_url: str
    offline_url: str
    remote_debug_host: str
    remote_debug_port: int
    kiosk_user: str
    failure_threshold: int
    restart_cooldown_seconds: int
    http_timeout_seconds: int
    startup_grace_seconds: int
    log_retention_days: int
    log_max_bytes: int


@dataclass
class CheckResult:
    ok: bool
    health: str
    service: str = "unknown"
    pid: int = 0
    debug_port: str = "unknown"
    page: str = "unknown"
    reason: str = "none"
    startup_grace: bool = False


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


def int_config(config: dict[str, str], key: str, default: int, minimum: int = 1) -> int:
    try:
        value = int(str(config.get(key, default)).strip())
    except (TypeError, ValueError):
        return default
    return value if value >= minimum else default


def build_config(raw: dict[str, str]) -> HealthConfig:
    return HealthConfig(
        presentation_url=raw.get("PRESENTATION_URL", "").strip(),
        offline_url=raw.get("OFFLINE_URL", DEFAULTS["OFFLINE_URL"]).strip(),
        remote_debug_host=raw.get("REMOTE_DEBUG_HOST", DEFAULTS["REMOTE_DEBUG_HOST"]).strip() or DEFAULTS["REMOTE_DEBUG_HOST"],
        remote_debug_port=int_config(raw, "REMOTE_DEBUG_PORT", 9222),
        kiosk_user=raw.get("KIOSK_USER", "").strip() or current_user_name(),
        failure_threshold=int_config(raw, "HEALTH_FAILURE_THRESHOLD", 3),
        restart_cooldown_seconds=int_config(raw, "HEALTH_RESTART_COOLDOWN_SECONDS", 600),
        http_timeout_seconds=int_config(raw, "HEALTH_HTTP_TIMEOUT_SECONDS", 5),
        startup_grace_seconds=int_config(raw, "HEALTH_STARTUP_GRACE_SECONDS", 90, minimum=0),
        log_retention_days=int_config(raw, "HEALTH_LOG_RETENTION_DAYS", 3),
        log_max_bytes=int_config(raw, "HEALTH_LOG_MAX_BYTES", 5 * 1024 * 1024),
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


def is_valid_kiosk_url(target_url: str, presentation_url: str, offline_url: str) -> str | None:
    if not target_url:
        return None
    if offline_url and normalized_url(target_url) == normalized_url(offline_url):
        return "offline"
    if presentation_url and normalized_url(target_url) == normalized_url(presentation_url):
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


def find_valid_page(targets: list[dict[str, Any]], config: HealthConfig) -> str | None:
    saw_page = False
    for target in targets:
        if target.get("type") != "page":
            continue
        saw_page = True
        target_url = str(target.get("url", "")).strip()
        websocket_url = str(target.get("webSocketDebuggerUrl", "")).strip()
        if not target_url or not websocket_url:
            continue
        page_type = is_valid_kiosk_url(target_url, config.presentation_url, config.offline_url)
        if page_type:
            return page_type
    if not saw_page:
        raise RuntimeError("geen Chromium page-target gevonden")
    return None


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
        page = find_valid_page(targets, config)
    except RuntimeError as exc:
        return CheckResult(False, "warning" if startup_grace else "failed", service=service_state, pid=pid, debug_port="ok", reason=str(exc).replace(" ", "_"), startup_grace=startup_grace)
    if page is None:
        return CheckResult(False, "warning" if startup_grace else "failed", service=service_state, pid=pid, debug_port="ok", reason="no_valid_kiosk_page", startup_grace=startup_grace)

    return CheckResult(True, "ok", service=service_state, pid=pid, debug_port="ok", page=page)


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


def log_line(reference_time: datetime, result: CheckResult, failures: int, action: str, restart_skipped: str | None) -> str:
    parts = [
        reference_time.isoformat(timespec="seconds"),
        f"health={result.health}",
    ]
    if result.startup_grace:
        parts.append("startup_grace=true")
    parts.extend([
        f"service={result.service}",
        f"pid={result.pid}",
        f"debug_port={result.debug_port}",
        f"page={result.page}",
        f"failures={failures}",
        f"action={action if action != 'restart_failed' else 'restart'}",
        f"reason={result.reason}",
    ])
    if restart_skipped:
        parts.append(f"restart_skipped={restart_skipped}")
    return " ".join(parts)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Controleer de Digital Signage-kiosk.")
    parser.add_argument("--check-only", action="store_true", help="Controleer zonder herstelactie uit te voeren.")
    parser.add_argument("--simulate-debug-failure", action="store_true", help="Simuleer een debugpoortfout zonder restart.")
    parser.add_argument("--state-dir", type=Path, default=None, help="Alternatieve statusmap voor tests.")
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
    log_file = state_dir / "health.log"
    state, warning = load_state(state_file)
    if warning:
        print(f"Waarschuwing: {warning}", file=sys.stderr)

    reference_time = now()
    result = evaluate_health(config, simulate_debug_failure=args.simulate_debug_failure)
    if result.startup_grace and not result.ok:
        print(f"Waarschuwing: kiosk zit in startup-grace; geen herstelactie voor {result.reason}", file=sys.stderr)
    elif not result.ok:
        print(f"Fout: health-check faalt: {result.reason}", file=sys.stderr)

    new_state, action, restart_skipped, exitcode = apply_result(
        state,
        result,
        config,
        check_only=args.check_only or args.simulate_debug_failure,
        reference_time=reference_time,
    )
    atomic_write_json(state_file, new_state)
    line = log_line(reference_time, result, int(new_state.get("consecutive_failures", 0)), action, restart_skipped)
    write_log_line(log_file, config, line, reference_time)
    print(line)
    return exitcode


if __name__ == "__main__":
    raise SystemExit(main())
