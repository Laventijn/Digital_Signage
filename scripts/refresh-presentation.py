#!/usr/bin/env python3
"""Vernieuwt het bestaande Google Slides-tabblad via Chrome DevTools Protocol."""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
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
    try:
        navigate_presentation(config)
    except RefreshError as exc:
        print(f"Fout: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
