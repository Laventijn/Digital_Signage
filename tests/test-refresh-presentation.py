#!/usr/bin/env python3
"""Unit tests voor refresh-presentation.py zonder echte Chromium-sessie."""

from __future__ import annotations

import importlib.util
import json
import urllib.error
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT_DIR / "scripts" / "refresh-presentation.py"


def load_module():
    spec = importlib.util.spec_from_file_location("refresh_presentation", MODULE_PATH)
    if spec is None or spec.loader is None:
      raise RuntimeError("Kan refresh-presentation.py niet laden")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def expect_refresh_error(func, expected_text: str) -> None:
    module = load_module()
    try:
        func(module)
    except module.RefreshError as exc:
        assert expected_text in str(exc), str(exc)
        return
    raise AssertionError("RefreshError werd niet opgegooid")


def test_devtools_not_reachable() -> None:
    def scenario(module):
        def fake_urlopen(_url, timeout):
            raise urllib.error.URLError("connection refused")

        module.urllib.request.urlopen = fake_urlopen
        module.fetch_targets("127.0.0.1", 9222)

    expect_refresh_error(scenario, "Kan Chromium-tabbladen niet ophalen")


def test_empty_target_list() -> None:
    def scenario(module):
        module.find_presentation_target([])

    expect_refresh_error(scenario, "Geen bestaand Google Slides-tabblad")


def test_no_page_target() -> None:
    def scenario(module):
        module.find_presentation_target([{"type": "service_worker", "url": "https://docs.google.com/presentation/"}])

    expect_refresh_error(scenario, "Geen bestaand Google Slides-tabblad")


def test_prefers_google_slides_target() -> None:
    module = load_module()
    target = module.find_presentation_target([
        {"type": "page", "url": "https://example.org", "webSocketDebuggerUrl": "ws://wrong"},
        {"type": "page", "url": "https://docs.google.com/presentation/d/demo/present?start=true&loop=true&slide=id.x", "webSocketDebuggerUrl": "ws://right"},
    ])
    assert target["webSocketDebuggerUrl"] == "ws://right"


def test_falls_back_to_first_page_target() -> None:
    module = load_module()
    target = module.find_presentation_target([
        {"type": "service_worker", "url": "https://docs.google.com/presentation/"},
        {"type": "page", "url": "https://example.org", "webSocketDebuggerUrl": "ws://page"},
    ])
    assert target["webSocketDebuggerUrl"] == "ws://page"


def test_successful_page_navigate() -> None:
    module = load_module()
    sent_messages: list[dict[str, object]] = []

    class FakeConnection:
        def send(self, payload: str) -> None:
            sent_messages.append(json.loads(payload))

        def recv(self) -> str:
            return json.dumps({"id": 1, "result": {}})

        def close(self) -> None:
            pass

    class FakeWebsocketModule:
        WebSocketException = OSError

        @staticmethod
        def create_connection(url: str, timeout: int):
            assert url == "ws://slides"
            assert timeout == module.WEBSOCKET_TIMEOUT_SECONDS
            return FakeConnection()

    module.websocket = FakeWebsocketModule
    module.fetch_targets = lambda host, port: [{
        "type": "page",
        "url": "https://docs.google.com/presentation/d/demo/present?slide=id.old",
        "webSocketDebuggerUrl": "ws://slides",
    }]

    presentation_url = "https://docs.google.com/presentation/d/demo/present?start=true&loop=true&delayms=5000"
    module.navigate_presentation({"PRESENTATION_URL": presentation_url})
    assert sent_messages == [{
        "id": 1,
        "method": "Page.navigate",
        "params": {"url": presentation_url},
    }]


def test_websocket_error_response() -> None:
    def scenario(module):
        class FakeConnection:
            def send(self, _payload: str) -> None:
                pass

            def recv(self) -> str:
                return json.dumps({"id": 1, "error": {"message": "navigation failed"}})

            def close(self) -> None:
                pass

        class FakeWebsocketModule:
            WebSocketException = OSError

            @staticmethod
            def create_connection(_url: str, timeout: int):
                return FakeConnection()

        module.websocket = FakeWebsocketModule
        module.fetch_targets = lambda host, port: [{
            "type": "page",
            "url": "https://docs.google.com/presentation/d/demo/present",
            "webSocketDebuggerUrl": "ws://slides",
        }]
        module.navigate_presentation({"PRESENTATION_URL": "https://docs.google.com/presentation/d/demo/present"})

    expect_refresh_error(scenario, "Chromium DevTools gaf een fout")


def test_custom_devtools_host_and_port() -> None:
    module = load_module()
    calls: list[tuple[str, int]] = []

    class FakeConnection:
        def send(self, _payload: str) -> None:
            pass

        def recv(self) -> str:
            return json.dumps({"id": 1, "result": {}})

        def close(self) -> None:
            pass

    class FakeWebsocketModule:
        WebSocketException = OSError

        @staticmethod
        def create_connection(_url: str, timeout: int):
            return FakeConnection()

    def fake_fetch_targets(host: str, port: int):
        calls.append((host, port))
        return [{
            "type": "page",
            "url": "https://docs.google.com/presentation/d/demo/present",
            "webSocketDebuggerUrl": "ws://slides",
        }]

    module.websocket = FakeWebsocketModule
    module.fetch_targets = fake_fetch_targets
    module.navigate_presentation({
        "PRESENTATION_URL": "https://docs.google.com/presentation/d/demo/present",
        "REMOTE_DEBUG_HOST": "127.0.0.2",
        "REMOTE_DEBUG_PORT": "9333",
    })
    assert calls == [("127.0.0.2", 9333)]


def main() -> int:
    test_devtools_not_reachable()
    test_empty_target_list()
    test_no_page_target()
    test_prefers_google_slides_target()
    test_falls_back_to_first_page_target()
    test_successful_page_navigate()
    test_websocket_error_response()
    test_custom_devtools_host_and_port()
    print("Refresh-presentatietests OK.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
