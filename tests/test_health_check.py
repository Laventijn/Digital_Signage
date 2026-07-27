#!/usr/bin/env python3
"""Unit tests voor health-check.py zonder echte kioskherstarts."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock


ROOT_DIR = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT_DIR / "scripts" / "health-check.py"


def load_module():
    spec = importlib.util.spec_from_file_location("health_check", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("Kan health-check.py niet laden")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


health = load_module()


class HealthCheckTests(unittest.TestCase):
    def make_config(self):
        raw = dict(health.DEFAULTS)
        raw.update({
            "PRESENTATION_URL": "https://docs.google.com/presentation/d/abc123/present?start=true&loop=true",
            "OFFLINE_PAGE_URL": "file:///opt/digitalsignage/offline/index.html",
            "KIOSK_USER": "kiosk",
        })
        return health.build_config(raw)

    def test_config_parser_strips_quotes_and_ignores_comments(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "digitalsignage.conf"
            path.write_text(
                "# comment\nHEALTH_FAILURE_THRESHOLD=\"4\"\nONGELDIG\nBAD-KEY=1\n",
                encoding="utf-8",
            )
            config = health.read_config(path)
        self.assertEqual(config["HEALTH_FAILURE_THRESHOLD"], "4")
        self.assertNotIn("BAD-KEY", config)

    def test_invalid_numbers_use_defaults(self):
        config = health.build_config({"HEALTH_FAILURE_THRESHOLD": "x", "HEALTH_HTTP_TIMEOUT_SECONDS": "0"})
        self.assertEqual(config.failure_threshold, 3)
        self.assertEqual(config.http_timeout_seconds, 5)

    def test_google_slides_id_extraction(self):
        self.assertEqual(health.parse_google_slides_id("https://docs.google.com/presentation/d/abc123/present"), "abc123")
        self.assertIsNone(health.parse_google_slides_id("https://example.org"))

    def test_valid_urls(self):
        config = self.make_config()
        self.assertEqual(
            health.is_valid_kiosk_url(config.presentation_url, config.presentation_url, config.offline_url),
            "presentation",
        )
        self.assertEqual(
            health.is_valid_kiosk_url(
                "https://docs.google.com/presentation/d/abc123/present?slide=id.p1",
                config.presentation_url,
                config.offline_url,
            ),
            "google_slides",
        )
        self.assertEqual(
            health.is_valid_kiosk_url(config.offline_page_url, config.presentation_url, config.offline_page_url),
            "offline",
        )
        self.assertIsNone(health.is_valid_kiosk_url("https://example.org", config.presentation_url, config.offline_page_url))

    def test_corrupt_state_is_recovered(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "health-state.json"
            path.write_text("{", encoding="utf-8")
            state, warning = health.load_state(path)
        self.assertEqual(state["consecutive_failures"], 0)
        self.assertIsNotNone(warning)

    def test_atomic_state_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "health-state.json"
            health.atomic_write_json(path, {"consecutive_failures": 2})
            self.assertEqual(json.loads(path.read_text(encoding="utf-8"))["consecutive_failures"], 2)

    def test_failure_counter_increases_until_threshold(self):
        config = self.make_config()
        result = health.CheckResult(False, "failed", reason="debug_port_unreachable")
        reference = datetime(2026, 7, 26, 12, 0, tzinfo=timezone.utc)
        state, action, skipped, exitcode = health.apply_result(dict(health.DEFAULT_STATE), result, config, True, reference)
        self.assertEqual(state["consecutive_failures"], 1)
        self.assertEqual(action, "none")
        self.assertIsNone(skipped)
        self.assertEqual(exitcode, 1)

    def test_success_resets_failure_counter(self):
        config = self.make_config()
        state = dict(health.DEFAULT_STATE)
        state["consecutive_failures"] = 2
        result = health.CheckResult(True, "ok")
        new_state, _, _, exitcode = health.apply_result(state, result, config, False, datetime.now(timezone.utc))
        self.assertEqual(new_state["consecutive_failures"], 0)
        self.assertEqual(exitcode, 0)

    def test_threshold_requests_restart(self):
        config = self.make_config()
        state = dict(health.DEFAULT_STATE)
        state["consecutive_failures"] = config.failure_threshold - 1
        result = health.CheckResult(False, "failed", reason="debug_port_unreachable")
        with mock.patch.object(health, "restart_kiosk", return_value=(True, "")):
            new_state, action, skipped, exitcode = health.apply_result(
                state, result, config, False, datetime.now(timezone.utc)
            )
        self.assertEqual(action, "restart")
        self.assertIsNone(skipped)
        self.assertEqual(new_state["consecutive_failures"], 0)
        self.assertEqual(exitcode, 1)

    def test_cooldown_skips_restart(self):
        config = self.make_config()
        reference = datetime(2026, 7, 26, 12, 0, tzinfo=timezone.utc)
        state = dict(health.DEFAULT_STATE)
        state["consecutive_failures"] = config.failure_threshold - 1
        state["last_restart"] = (reference - timedelta(seconds=30)).isoformat()
        result = health.CheckResult(False, "failed", reason="debug_port_unreachable")
        new_state, action, skipped, _ = health.apply_result(state, result, config, False, reference)
        self.assertEqual(action, "none")
        self.assertEqual(skipped, "cooldown")
        self.assertGreaterEqual(new_state["consecutive_failures"], config.failure_threshold)

    def test_startup_grace_resets_failures(self):
        config = self.make_config()
        state = dict(health.DEFAULT_STATE)
        state["consecutive_failures"] = 2
        result = health.CheckResult(False, "warning", startup_grace=True, reason="debug_port_unreachable")
        new_state, action, skipped, _ = health.apply_result(state, result, config, False, datetime.now(timezone.utc))
        self.assertEqual(new_state["consecutive_failures"], 0)
        self.assertEqual(action, "none")
        self.assertIsNone(skipped)

    def test_log_retention_prunes_old_lines(self):
        config = self.make_config()
        reference = datetime(2026, 7, 26, 12, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            log_file = Path(tmp) / "health.log"
            log_file.write_text(
                "2026-07-20T12:00:00+00:00 health=ok\n"
                "2026-07-26T12:00:00+00:00 health=ok\n",
                encoding="utf-8",
            )
            health.write_log_line(log_file, config, "2026-07-26T12:01:00+00:00 health=ok", reference)
            lines = log_file.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 2)
        self.assertNotIn("2026-07-20", "\n".join(lines))

    def test_find_valid_page_requires_page_target(self):
        config = self.make_config()
        targets = [{"type": "worker", "url": config.presentation_url, "webSocketDebuggerUrl": "ws://x"}]
        with self.assertRaises(RuntimeError):
            health.find_valid_page(targets, config)

    def test_check_only_skips_restart_at_threshold(self):
        config = self.make_config()
        state = dict(health.DEFAULT_STATE)
        state["consecutive_failures"] = config.failure_threshold - 1
        result = health.CheckResult(False, "failed", reason="debug_port_unreachable")
        new_state, action, skipped, _ = health.apply_result(state, result, config, True, datetime.now(timezone.utc))
        self.assertEqual(action, "none")
        self.assertEqual(skipped, "check_only")
        self.assertGreaterEqual(new_state["consecutive_failures"], config.failure_threshold)

    def test_networkmanager_full_and_http_ok_is_online(self):
        config = self.make_config()
        with mock.patch.object(health, "check_networkmanager", return_value=(True, "full", "none")), \
             mock.patch.object(health, "check_http", return_value=(True, "ok", "none")):
            result = health.evaluate_connectivity(config)
        self.assertTrue(result.online)
        self.assertEqual(result.status, "online")

    def test_networkmanager_limited_is_offline(self):
        config = self.make_config()
        with mock.patch.object(health, "check_networkmanager", return_value=(False, "limited", "networkmanager_limited")), \
             mock.patch.object(health, "check_http", return_value=(True, "ok", "none")):
            result = health.evaluate_connectivity(config)
        self.assertFalse(result.online)
        self.assertEqual(result.reason, "networkmanager_limited")

    def test_networkmanager_failure_does_not_crash(self):
        with mock.patch.object(health.subprocess, "run", side_effect=OSError("nmcli ontbreekt")):
            ok, status, reason = health.check_networkmanager()
        self.assertFalse(ok)
        self.assertEqual(status, "failed")
        self.assertEqual(reason, "networkmanager_failed")

    def test_http_failure_is_offline(self):
        config = self.make_config()
        with mock.patch.object(health, "check_networkmanager", return_value=(True, "full", "none")), \
             mock.patch.object(health, "check_http", return_value=(False, "failed", "http_failed")):
            result = health.evaluate_connectivity(config)
        self.assertFalse(result.online)
        self.assertEqual(result.reason, "http_failed")

    def test_first_offline_check_sets_offline_since_and_keeps_page(self):
        config = self.make_config()
        browser = health.CheckResult(True, "ok", page_url=config.presentation_url, websocket_url="ws://x")
        connectivity = health.ConnectivityResult(False, "offline", "none", "failed", "networkmanager_none")
        action = health.process_connectivity(dict(health.DEFAULT_CONNECTIVITY_STATE), connectivity, browser, config, 1000, True)
        self.assertEqual(action.state["OFFLINE_SINCE"], 1000)
        self.assertEqual(action.action, "keep_current_page")

    def test_recovery_before_offline_threshold_never_shows_page(self):
        config = self.make_config()
        browser = health.CheckResult(True, "ok", page_url=config.presentation_url, websocket_url="ws://x")
        state = dict(health.DEFAULT_CONNECTIVITY_STATE)
        state["STATUS"] = "offline"
        state["OFFLINE_SINCE"] = 1000
        connectivity = health.ConnectivityResult(True, "online", "full", "ok", "none")
        action = health.process_connectivity(state, connectivity, browser, config, 1010, True)
        self.assertEqual(action.action, "wait_online_confirmation")
        self.assertFalse(action.state["OFFLINE_PAGE_SHOWN"])

    def test_offline_threshold_opens_offline_page_once(self):
        config = self.make_config()
        browser = health.CheckResult(True, "ok", page_url=config.presentation_url, websocket_url="ws://x")
        state = dict(health.DEFAULT_CONNECTIVITY_STATE)
        state["STATUS"] = "offline"
        state["OFFLINE_SINCE"] = 1000
        connectivity = health.ConnectivityResult(False, "offline", "none", "failed", "networkmanager_none")
        with mock.patch.object(health, "navigate_if_needed", return_value=(True, "ok")) as navigate:
            action = health.process_connectivity(state, connectivity, browser, config, 1300, True)
        self.assertEqual(action.action, "show_offline_page")
        self.assertEqual(action.reason, "screenshot_cache_unavailable")
        self.assertTrue(action.state["OFFLINE_PAGE_SHOWN"])
        navigate.assert_called_once()

    def test_offline_page_already_visible_is_not_reloaded(self):
        config = self.make_config()
        browser = health.CheckResult(True, "ok", page_url=config.offline_page_url, websocket_url="ws://x")
        state = dict(health.DEFAULT_CONNECTIVITY_STATE)
        state["STATUS"] = "offline"
        state["OFFLINE_SINCE"] = 1000
        state["OFFLINE_PAGE_SHOWN"] = True
        connectivity = health.ConnectivityResult(False, "offline", "none", "failed", "networkmanager_none")
        with mock.patch.object(health, "navigate_if_needed") as navigate:
            action = health.process_connectivity(state, connectivity, browser, config, 1300, True)
        self.assertEqual(action.action, "none")
        self.assertEqual(action.reason, "offline_page_already_visible")
        navigate.assert_not_called()

    def test_online_confirmation_waits_then_restores_kiosk(self):
        config = self.make_config()
        browser = health.CheckResult(True, "ok", page_url=config.offline_page_url, websocket_url="ws://x")
        state = dict(health.DEFAULT_CONNECTIVITY_STATE)
        state["STATUS"] = "offline"
        state["OFFLINE_SINCE"] = 1000
        state["ONLINE_SINCE"] = 1200
        state["OFFLINE_PAGE_SHOWN"] = True
        connectivity = health.ConnectivityResult(True, "online", "full", "ok", "none")
        with mock.patch.object(health, "navigate_if_needed", return_value=(True, "ok")) as navigate:
            action = health.process_connectivity(state, connectivity, browser, config, 1230, True)
        self.assertEqual(action.action, "show_kiosk_page")
        self.assertEqual(action.state["STATUS"], "online")
        self.assertFalse(action.state["OFFLINE_PAGE_SHOWN"])
        navigate.assert_called_once()

    def test_kiosk_page_already_visible_is_not_reopened(self):
        config = self.make_config()
        browser = health.CheckResult(True, "ok", page_url=config.presentation_url, websocket_url="ws://x")
        state = dict(health.DEFAULT_CONNECTIVITY_STATE)
        state["STATUS"] = "offline"
        state["OFFLINE_SINCE"] = 1000
        state["ONLINE_SINCE"] = 1200
        state["OFFLINE_PAGE_SHOWN"] = True
        connectivity = health.ConnectivityResult(True, "online", "full", "ok", "none")
        with mock.patch.object(health, "navigate_if_needed") as navigate:
            action = health.process_connectivity(state, connectivity, browser, config, 1230, True)
        self.assertEqual(action.action, "none")
        self.assertEqual(action.reason, "kiosk_page_already_visible")
        navigate.assert_not_called()

    def test_corrupt_connectivity_state_uses_safe_defaults(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "connectivity.state"
            path.write_text("STATUS=bad\nOFFLINE_SINCE=abc\nUNKNOWN=$(touch /tmp/nope)\nOFFLINE_PAGE_SHOWN=maybe\n", encoding="utf-8")
            state, warning = health.load_connectivity_state(path, 1000)
        self.assertEqual(state["STATUS"], "online")
        self.assertEqual(state["OFFLINE_SINCE"], 0)
        self.assertFalse(state["OFFLINE_PAGE_SHOWN"])
        self.assertIsNone(warning)

    def test_invalid_offline_config_values_warn_and_use_defaults(self):
        config = health.build_config({
            "OFFLINE_AFTER_SECONDS": "0",
            "ONLINE_CONFIRM_SECONDS": "-1",
            "CONNECTIVITY_TIMEOUT_SECONDS": "x",
            "OFFLINE_PAGE_ENABLED": "misschien",
        })
        self.assertEqual(config.offline_after_seconds, 45)
        self.assertEqual(config.online_confirm_seconds, 30)
        self.assertEqual(config.connectivity_timeout_seconds, 5)
        self.assertTrue(config.offline_page_enabled)
        self.assertGreaterEqual(len(config.warnings), 4)

    def test_offline_page_disabled_never_navigates(self):
        raw = dict(health.DEFAULTS)
        raw.update({"OFFLINE_PAGE_ENABLED": "false"})
        config = health.build_config(raw)
        browser = health.CheckResult(True, "ok", page_url=config.presentation_url, websocket_url="ws://x")
        state = dict(health.DEFAULT_CONNECTIVITY_STATE)
        state["OFFLINE_SINCE"] = 1000
        connectivity = health.ConnectivityResult(False, "offline", "none", "failed", "networkmanager_none")
        with mock.patch.object(health, "navigate_if_needed") as navigate:
            action = health.process_connectivity(state, connectivity, browser, config, 2000, True)
        self.assertEqual(action.action, "keep_current_page")
        self.assertEqual(action.reason, "offline_page_disabled")
        navigate.assert_not_called()

    def test_special_url_is_serialized_as_valid_json(self):
        browser = health.CheckResult(True, "ok", page_url="https://example.invalid", websocket_url="ws://x")
        target_url = 'https://example.org/present?x="waarde"&y=1 2'
        sent: list[str] = []

        class FakeWs:
            def send(self, payload):
                sent.append(payload)

            def recv(self):
                return '{"id": 1}'

            def close(self):
                return None

        with mock.patch.object(health, "websocket") as websocket_mock:
            websocket_mock.create_connection.return_value = FakeWs()
            websocket_mock.WebSocketException = Exception
            ok, message = health.navigate_if_needed(browser, target_url)
        self.assertTrue(ok, message)
        self.assertEqual(json.loads(sent[0])["params"]["url"], target_url)


if __name__ == "__main__":
    unittest.main()
