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
            "OFFLINE_URL": "file:///opt/digitalsignage/web/offline/index.html",
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
            health.is_valid_kiosk_url(config.offline_url, config.presentation_url, config.offline_url),
            "offline",
        )
        self.assertIsNone(health.is_valid_kiosk_url("https://example.org", config.presentation_url, config.offline_url))

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


if __name__ == "__main__":
    unittest.main()
