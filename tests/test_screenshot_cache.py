#!/usr/bin/env python3
"""Unit tests voor de lokale screenshotcache zonder echte Chromium-sessie."""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
import time
from pathlib import Path
from unittest import mock


ROOT_DIR = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT_DIR / "scripts" / "digitalsignage_config.py"


def load_module():
    spec = importlib.util.spec_from_file_location("digitalsignage_config", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("Kan digitalsignage_config.py niet laden")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


cfg = load_module()


CAPTURE_PATH = ROOT_DIR / "scripts" / "capture-content-cache.py"


def load_capture_module():
    spec = importlib.util.spec_from_file_location("capture_content_cache", CAPTURE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("Kan capture-content-cache.py niet laden")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


capture = load_capture_module()


class DummyConfig:
    mode = "presentation"
    effective_url = "https://slides.example/present?delayms=5000"
    keep_versions = 2
    log_retention_days = 3
    log_max_bytes = 5242880
    max_consecutive_failures = 2
    stable_gap_ms = 3000


class ScreenshotCacheTests(unittest.TestCase):
    def test_effective_url_prefers_content_url(self):
        raw = {"CONTENT_URL": "https://example.org/dashboard", "PRESENTATION_URL": "https://slides.example"}
        self.assertEqual(cfg.effective_content_url(raw), "https://example.org/dashboard")

    def test_effective_url_falls_back_to_presentation_url(self):
        raw = {"CONTENT_URL": "", "PRESENTATION_URL": "https://slides.example"}
        self.assertEqual(cfg.effective_content_url(raw), "https://slides.example")

    def test_content_mode_validation_warns(self):
        config = cfg.build_content_config({"CONTENT_MODE": "anders"})
        self.assertEqual(config.mode, "anders")
        self.assertTrue(any("CONTENT_MODE" in warning for warning in config.warnings))

    def test_parse_delayms(self):
        self.assertEqual(cfg.parse_delayms("https://x/present?delayms=7000"), 7000)
        self.assertEqual(cfg.parse_delayms("https://x/present?delayms=abc"), 5000)
        self.assertEqual(cfg.parse_delayms("https://x/present"), 5000)

    def test_slide_id_from_url(self):
        self.assertEqual(cfg.slide_id_from_url("https://x/present?slide=id.p2"), "id.p2")
        self.assertEqual(cfg.slide_id_from_url("https://x/present#slide=id.p3"), "id.p3")
        self.assertIsNone(cfg.slide_id_from_url("https://x/present"))

    def test_byte_difference_percent(self):
        self.assertEqual(cfg.byte_difference_percent(b"abc", b"abc"), 0.0)
        self.assertGreater(cfg.byte_difference_percent(b"abc", b"axc"), 0.0)

    def test_manifest_validation_presentation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "images").mkdir()
            (root / "images" / "slide-001.png").write_bytes(b"png")
            for name in ("index.html", "player.css", "player.js"):
                (root / name).write_text(name, encoding="utf-8")
            (root / "manifest.json").write_text(json.dumps({
                "mode": "presentation",
                "slide_seconds": 5,
                "images": [{"file": "images/slide-001.png"}],
            }), encoding="utf-8")
            ok, reason, manifest = cfg.validate_cache_version(root)
        self.assertTrue(ok, reason)
        self.assertEqual(manifest["mode"], "presentation")

    def test_manifest_validation_rejects_website_slideshow(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "images").mkdir()
            (root / "images" / "a.png").write_bytes(b"png")
            (root / "images" / "b.png").write_bytes(b"png")
            for name in ("index.html", "player.css", "player.js"):
                (root / name).write_text(name, encoding="utf-8")
            (root / "manifest.json").write_text(json.dumps({
                "mode": "website",
                "slide_seconds": 5,
                "images": [{"file": "images/a.png"}, {"file": "images/b.png"}],
            }), encoding="utf-8")
            ok, reason, _manifest = cfg.validate_cache_version(root)
        self.assertFalse(ok)
        self.assertIn("websitemodus", reason)

    def test_watermark_id_is_project_specific(self):
        self.assertEqual(cfg.WATERMARK_ELEMENT_ID, "digitalsignage-offline-watermark-capture-overlay")

    def test_config_contains_sampling_safety_defaults(self):
        config = cfg.build_content_config({})
        self.assertEqual(config.change_poll_ms, 500)
        self.assertEqual(config.max_consecutive_failures, 10)

    def test_effective_stable_gap_is_bounded_below_slide_delay(self):
        self.assertEqual(capture.effective_stable_gap_seconds(DummyConfig(), 5000), 1.0)
        self.assertLessEqual(capture.effective_stable_gap_seconds(DummyConfig(), 3000), 1.0)

    def test_unstable_candidate_does_not_increment_technical_failures(self):
        with tempfile.TemporaryDirectory() as tmp:
            stats = capture.CaptureStats()
            candidate = capture.StableCandidate(b"", "", "id.p2", 76.64)
            capture.log_rejected(Path(tmp) / "capture.log", DummyConfig(), stats, "unstable_candidate", candidate, None, time.monotonic())
        self.assertEqual(stats.rejected, 1)
        self.assertEqual(stats.unstable_candidate_attempts, 0)
        self.assertEqual(stats.consecutive_failures, 0)

    def test_technical_failures_are_bounded(self):
        with tempfile.TemporaryDirectory() as tmp:
            stats = capture.CaptureStats()
            log_file = Path(tmp) / "capture.log"
            capture.log_rejected(log_file, DummyConfig(), stats, "DevTools fout", None, None, time.monotonic(), technical_failure=True)
            with self.assertRaises(capture.CaptureError):
                capture.log_rejected(log_file, DummyConfig(), stats, "DevTools fout", None, None, time.monotonic(), technical_failure=True)
        self.assertEqual(stats.consecutive_failures, 2)
        self.assertEqual(stats.stop_reason, "consecutive_failures")

    def test_screenshot_timer_resets_old_intervals(self):
        install_text = (ROOT_DIR / "install" / "install.sh").read_text(encoding="utf-8")
        upgrade_text = (ROOT_DIR / "install" / "upgrade.sh").read_text(encoding="utf-8")
        for text in (install_text, upgrade_text):
            self.assertIn("write_screenshot_timer_dropin()", text)
            self.assertIn("OnBootSec=\nOnActiveSec=\nOnUnitActiveSec=\nOnUnitInactiveSec=", text)
            self.assertIn("OnUnitInactiveSec=${interval}s", text)

    def test_png_dimensions_from_header(self):
        png = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + (800).to_bytes(4, "big") + (450).to_bytes(4, "big") + b"\x08\x02\x00\x00\x00"
        self.assertEqual(capture.png_dimensions(png), (800, 450))

    def test_validate_png_size_rejects_wrong_resolution(self):
        png = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + (800).to_bytes(4, "big") + (449).to_bytes(4, "big") + b"\x08\x02\x00\x00\x00"
        with self.assertRaises(capture.CaptureError):
            capture.validate_png_size(png, 800, 450)

    def test_deadline_sleep_respects_deadline(self):
        deadline = capture.Deadline(1)
        start = time.monotonic()
        capture.deadline_sleep(0.1, deadline)
        self.assertLess(time.monotonic() - start, 0.5)

    def test_validate_cache_version_rejects_browser_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "images").mkdir()
            (root / "profile").mkdir()
            (root / "images" / "slide-001.png").write_bytes(b"png")
            for name in ("index.html", "player.css", "player.js"):
                (root / name).write_text(name, encoding="utf-8")
            (root / "manifest.json").write_text(json.dumps({
                "mode": "presentation",
                "slide_seconds": 5,
                "images": [{"file": "images/slide-001.png"}],
            }), encoding="utf-8")
            ok, reason, _manifest = cfg.validate_cache_version(root)
        self.assertFalse(ok)
        self.assertIn("onverwachte", reason)

    def test_publish_uses_only_version_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache_root = Path(tmp) / "cache"
            work = cache_root / "work" / "capture-demo"
            version = work / "version"
            browser = work / "browser"
            (version / "images").mkdir(parents=True)
            browser.mkdir(parents=True)
            (browser / "profile").mkdir()
            (browser / "cache").mkdir()
            (version / "images" / "slide-001.png").write_bytes(b"png")
            for name in ("index.html", "player.css", "player.js"):
                (version / name).write_text(name, encoding="utf-8")
            manifest = {
                "mode": "presentation",
                "slide_seconds": 5,
                "images": [{"file": "images/slide-001.png", "stored_hash": "abc"}],
            }
            (version / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            with mock.patch.object(capture, "atomic_activate_version"):
                state = capture.publish_version(cache_root, version, DummyConfig(), manifest, ["abc"])
            published = cache_root / "versions" / "capture-demo"
            self.assertEqual(state, "updated")
            self.assertTrue((published / "images" / "slide-001.png").is_file())
            self.assertFalse((published / "browser").exists())
            self.assertFalse((published / "profile").exists())
            self.assertFalse((published / "cache").exists())

    def test_invalid_version_preserves_current_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache_root = Path(tmp) / "cache"
            current_version = cache_root / "versions" / "old"
            (current_version / "images").mkdir(parents=True)
            (current_version / "images" / "slide-001.png").write_bytes(b"old")
            for name in ("index.html", "player.css", "player.js"):
                (current_version / name).write_text(name, encoding="utf-8")
            (current_version / "manifest.json").write_text(json.dumps({
                "mode": "presentation",
                "slide_seconds": 5,
                "images": [{"file": "images/slide-001.png", "stored_hash": "old"}],
            }), encoding="utf-8")
            bad_version = cache_root / "work" / "capture-bad" / "version"
            bad_version.mkdir(parents=True)
            with self.assertRaises(capture.CaptureError):
                capture.publish_version(cache_root, bad_version, DummyConfig(), {}, ["bad"])
            self.assertEqual((current_version / "images" / "slide-001.png").read_bytes(), b"old")

    @unittest.skipIf(os.name == "nt", "POSIX-lockcleanup wordt op de Pi getest")
    def test_lock_active_stale_and_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp)
            fd, stale_removed = capture.acquire_lock(state_dir)
            self.assertFalse(stale_removed)
            with mock.patch.object(capture, "process_is_capture_script", return_value=True):
                with self.assertRaises(capture.CaptureError):
                    capture.acquire_lock(state_dir)
            capture.release_lock(fd, state_dir)
            self.assertFalse((state_dir / "screenshot-cache.lock").exists())

            (state_dir / "screenshot-cache.lock").write_text(json.dumps({"pid": 999999, "script": "capture-content-cache.py"}), encoding="utf-8")
            fd, stale_removed = capture.acquire_lock(state_dir)
            self.assertTrue(stale_removed)
            capture.release_lock(fd, state_dir)

            (state_dir / "screenshot-cache.lock").write_text("", encoding="utf-8")
            fd, stale_removed = capture.acquire_lock(state_dir)
            self.assertTrue(stale_removed)
            capture.release_lock(fd, state_dir)


if __name__ == "__main__":
    unittest.main()
