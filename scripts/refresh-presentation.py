#!/usr/bin/env python3
"""Vernieuwt het bestaande Google Slides-tabblad via Chrome DevTools Protocol."""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

try:
    import websocket
except ImportError as exc:  # pragma: no cover - afhankelijk van het Pi-pakket
    websocket = None
    WEBSOCKET_IMPORT_ERROR = exc
else:
    WEBSOCKET_IMPORT_ERROR = None


CONFIG_FILE = Path(os.environ.get("CONFIG_FILE", "/etc/digitalsignage/digitalsignage.conf"))
DEFAULT_REMOTE_DEBUG_HOST = "127.0.0.1"
DEFAULT_REMOTE_DEBUG_PORT = 9222
DEFAULT_SWAP_LOG_MAX_BYTES = 5 * 1024 * 1024
HTTP_TIMEOUT_SECONDS = 5
WEBSOCKET_TIMEOUT_SECONDS = 5


class RefreshError(RuntimeError):
    """Fout die veilig aan een ICT-medewerker getoond mag worden."""


def read_config(path: Path) -> dict[str, str]:
    """Lees eenvoudige KEY=VALUE-regels zonder shell-evaluatie."""
    config: dict[str, str] = {}
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


def int_config(config: dict[str, str], key: str, default: int) -> int:
    try:
        value = int(config.get(key, str(default)))
    except ValueError:
        return default
    return value if value > 0 else default


def read_meminfo() -> dict[str, int]:
    values: dict[str, int] = {}
    with Path("/proc/meminfo").open("r", encoding="utf-8") as handle:
        for line in handle:
            name, rest = line.split(":", 1)
            values[name] = int(rest.strip().split()[0])
    return values


def memory_fields() -> dict[str, int]:
    meminfo = read_meminfo()
    mem_total = meminfo.get("MemTotal", 0)
    mem_available = meminfo.get("MemAvailable", 0)
    swap_total = meminfo.get("SwapTotal", 0)
    swap_free = meminfo.get("SwapFree", 0)
    return {
        "ram_used_mib": max(mem_total - mem_available, 0) // 1024,
        "ram_available_mib": mem_available // 1024,
        "swap_used_mib": max(swap_total - swap_free, 0) // 1024,
        "swap_free_mib": swap_free // 1024,
    }


def compact_error(message: str) -> str:
    cleaned = " ".join(message.replace("\n", " ").split())
    return cleaned[:160].replace(" ", "_")


def rotate_log_if_needed(log_file: Path, max_bytes: int) -> None:
    if not log_file.exists() or log_file.stat().st_size < max_bytes:
        return
    rotated = log_file.with_name("swap.log.1")
    if rotated.exists():
        rotated.unlink()
    log_file.rename(rotated)


def write_swap_log(success: bool, error: str | None, max_bytes: int) -> None:
    log_dir = Path.home() / ".local" / "state" / "digitalsignage"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "swap.log"
    rotate_log_if_needed(log_file, max_bytes)

    fields = memory_fields()
    parts = [
        datetime.now().astimezone().isoformat(timespec="seconds"),
        f"refresh={'ok' if success else 'error'}",
        f"ram_used_mib={fields['ram_used_mib']}",
        f"ram_available_mib={fields['ram_available_mib']}",
        f"swap_used_mib={fields['swap_used_mib']}",
        f"swap_free_mib={fields['swap_free_mib']}",
    ]
    if error:
        parts.append(f"error={compact_error(error)}")
    with log_file.open("a", encoding="utf-8") as handle:
        handle.write(" ".join(parts) + "\n")


def fetch_targets(host: str, port: int) -> list[dict[str, object]]:
    url = f"http://{host}:{port}/json"
    try:
        with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT_SECONDS) as response:
            return json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise RefreshError(f"Kan Chromium-tabbladen niet ophalen via {url}: {exc}") from exc


def find_presentation_target(targets: list[dict[str, object]]) -> dict[str, object]:
    for target in targets:
        if target.get("type") != "page":
            continue
        url = str(target.get("url", ""))
        if "docs.google.com/presentation/" in url:
            return target
    raise RefreshError("Geen bestaand Google Slides-tabblad gevonden.")


def navigate_presentation(config: dict[str, str]) -> None:
    presentation_url = config.get("PRESENTATION_URL", "").strip()
    if not presentation_url:
        raise RefreshError("PRESENTATION_URL ontbreekt in de configuratie.")
    if websocket is None:
        raise RefreshError(f"Pythonpakket websocket ontbreekt: {WEBSOCKET_IMPORT_ERROR}")

    host = config.get("REMOTE_DEBUG_HOST", DEFAULT_REMOTE_DEBUG_HOST)
    port = int_config(config, "REMOTE_DEBUG_PORT", DEFAULT_REMOTE_DEBUG_PORT)
    target = find_presentation_target(fetch_targets(host, port))
    ws_url = str(target.get("webSocketDebuggerUrl", ""))
    if not ws_url:
        raise RefreshError("Google Slides-tabblad heeft geen webSocketDebuggerUrl.")

    ws = None
    try:
        ws = websocket.create_connection(ws_url, timeout=WEBSOCKET_TIMEOUT_SECONDS)
        ws.send(json.dumps({
            "id": 1,
            "method": "Page.navigate",
            "params": {"url": presentation_url},
        }))
        response = json.loads(ws.recv())
        if response.get("id") != 1:
            raise RefreshError("Onverwachte response van Chromium DevTools.")
        if "error" in response:
            raise RefreshError(f"Chromium DevTools gaf een fout: {response['error']}")
    except (OSError, websocket.WebSocketException, json.JSONDecodeError) as exc:
        raise RefreshError(f"Navigatie via Chromium DevTools mislukt: {exc}") from exc
    finally:
        if ws is not None:
            ws.close()


def main() -> int:
    config = read_config(CONFIG_FILE)
    max_bytes = int_config(config, "SWAP_LOG_MAX_BYTES", DEFAULT_SWAP_LOG_MAX_BYTES)
    error = None
    success = False
    try:
        navigate_presentation(config)
        success = True
    except RefreshError as exc:
        error = str(exc)
        print(f"Fout: {error}", file=sys.stderr)
    finally:
        try:
            write_swap_log(success, error, max_bytes)
        except Exception as exc:  # pragma: no cover - laatste redmiddel voor logging
            print(f"Fout: swaplog kon niet geschreven worden: {exc}", file=sys.stderr)
            if success:
                return 1
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
