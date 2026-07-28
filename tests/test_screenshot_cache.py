#!/usr/bin/env python3
"""Unit tests voor de lokale screenshotcache zonder echte Chromium-sessie."""

from __future__ import annotations

import importlib.util
import base64
import errno
import json
import os
import struct
import sys
import tempfile
import unittest
import time
import zlib
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
    transition_wait_ms = 750
    change_poll_ms = 500
    image_difference_percent = 2
    single_slide_confirm_seconds = 1
    max_slides = 10
    capture_width = 1920
    capture_height = 1080
    stability_debug_enabled = False


class StableGap400Config(DummyConfig):
    stable_gap_ms = 400


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return len(payload).to_bytes(4, "big") + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)


def png_solid(width: int, height: int, rgb: tuple[int, int, int], compresslevel: int = 6) -> bytes:
    row = bytes(rgb) * width
    raw = b"".join(b"\x00" + row for _ in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(raw, compresslevel))
        + png_chunk(b"IEND", b"")
    )


def png_one_pixel_changed(width: int, height: int) -> bytes:
    rows = []
    for y in range(height):
        pixels = bytearray(bytes((0, 0, 0)) * width)
        if y == 0:
            pixels[0:3] = bytes((255, 255, 255))
        rows.append(b"\x00" + bytes(pixels))
    return (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(b"".join(rows), 6))
        + png_chunk(b"IEND", b"")
    )


def png_dark_varied(width: int, height: int) -> bytes:
    rows = []
    for y in range(height):
        row = bytearray()
        for x in range(width):
            value = 6 if (x + y) % 2 == 0 else 52
            row.extend((value, value, value))
        rows.append(b"\x00" + bytes(row))
    return (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(b"".join(rows), 6))
        + png_chunk(b"IEND", b"")
    )


def png_bytes(marker: bytes) -> bytes:
    palette = {
        b"A": (20, 40, 80),
        b"B": (210, 80, 30),
        b"C": (60, 190, 120),
    }
    return png_solid(64, 36, palette.get(marker, (120, 120, 120)))


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
        self.assertFalse(config.stability_debug_enabled)

    def test_pixel_difference_uses_decoded_png_pixels(self):
        black_fast = png_solid(8, 8, (0, 0, 0), compresslevel=1)
        black_slow = png_solid(8, 8, (0, 0, 0), compresslevel=9)
        white = png_solid(8, 8, (255, 255, 255), compresslevel=6)
        small_change = png_one_pixel_changed(8, 8)
        self.assertEqual(capture.image_difference_percent(black_fast, black_slow), 0.0)
        self.assertEqual(capture.image_difference_percent(black_fast, black_fast), 0.0)
        self.assertAlmostEqual(capture.image_difference_percent(black_fast, white), 100.0)
        self.assertGreater(capture.image_difference_percent(black_fast, small_change), 0.0)
        self.assertLess(capture.image_difference_percent(black_fast, small_change), 2.0)

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
        self.assertEqual(stats.stop_reason, "technical_failures")

    def test_screenshot_timer_resets_old_intervals(self):
        install_text = (ROOT_DIR / "install" / "install.sh").read_text(encoding="utf-8")
        upgrade_text = (ROOT_DIR / "install" / "upgrade.sh").read_text(encoding="utf-8")
        for text in (install_text, upgrade_text):
            self.assertIn("write_screenshot_timer_dropin()", text)
            self.assertIn("OnBootSec=\nOnActiveSec=\nOnUnitActiveSec=\nOnUnitInactiveSec=", text)
            self.assertIn("OnUnitInactiveSec=${interval}s", text)

    def test_screenshot_timer_default_is_fifteen_minutes(self):
        timer_text = (ROOT_DIR / "services" / "digitalsignage-screenshot-cache.timer").read_text(encoding="utf-8")
        install_text = (ROOT_DIR / "install" / "install.sh").read_text(encoding="utf-8")
        upgrade_text = (ROOT_DIR / "install" / "upgrade.sh").read_text(encoding="utf-8")
        self.assertIn("OnBootSec=900s", timer_text)
        self.assertIn("OnUnitInactiveSec=900s", timer_text)
        self.assertIn("SCREENSHOT_CACHE_REFRESH_SECONDS=900", install_text)
        self.assertIn("SCREENSHOT_CACHE_REFRESH_SECONDS=900", upgrade_text)

    def test_slide_id_change_waits_until_raw_frame_changes(self):
        first = capture.StableCandidate(png_bytes(b"A"), capture.image_hash(png_bytes(b"A")), "id.A", 0)
        stats = capture.CaptureStats()
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(capture, "deadline_sleep"), \
                    mock.patch.object(capture, "wait_for_paint_cycles"), \
                    mock.patch.object(capture, "runtime_diagnostics", return_value={"url": "https://x/present?slide=id.B", "readyState": "complete", "visibilityState": "visible", "now": 100}), \
                    mock.patch.object(capture, "capture_png", side_effect=[png_bytes(b"A"), png_bytes(b"A"), png_bytes(b"A"), png_bytes(b"B"), png_bytes(b"B")]), \
                    mock.patch.object(capture, "current_url", return_value="https://x/present?slide=id.B"):
                candidate = capture.wait_for_visual_change(
                    object(),
                    DummyConfig(),
                    first,
                    capture.Deadline(30),
                    time.monotonic(),
                    stats,
                    Path(tmp) / "capture.log",
                    5000,
                )
        self.assertEqual(candidate.raw_hash, capture.image_hash(png_bytes(b"B")))
        self.assertEqual(candidate.slide_id, "id.B")
        self.assertIn("id.A", stats.observed_slide_ids)
        self.assertIn("id.B", stats.observed_slide_ids)
        self.assertTrue(stats.slide_id_changed)

    def test_transition_between_stability_pair_is_not_unstable(self):
        first = capture.StableCandidate(png_bytes(b"A"), capture.image_hash(png_bytes(b"A")), "id.A", 0)
        stats = capture.CaptureStats()
        events: list[str] = []

        def fake_sleep(seconds, _deadline):
            events.append(f"sleep:{round(seconds, 1)}")

        def fake_capture(_devtools, _config, **_kwargs):
            events.append("capture")
            return captures.pop(0)

        captures = [png_bytes(b"B"), png_bytes(b"B"), png_bytes(b"C"), png_bytes(b"B"), png_bytes(b"B")]
        urls = [
            "https://x/present?slide=id.B",
            "https://x/present?slide=id.B",
            "https://x/present?slide=id.C",
            "https://x/present?slide=id.B",
            "https://x/present?slide=id.B",
        ]

        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(capture, "deadline_sleep", side_effect=fake_sleep), \
                    mock.patch.object(capture, "wait_for_paint_cycles"), \
                    mock.patch.object(capture, "runtime_diagnostics", return_value={"url": "https://x/present?slide=id.B"}), \
                    mock.patch.object(capture, "capture_png", side_effect=fake_capture), \
                    mock.patch.object(capture, "current_url", side_effect=urls):
                candidate = capture.wait_for_visual_change(
                    object(),
                    DummyConfig(),
                    first,
                    capture.Deadline(30),
                    time.monotonic(),
                    stats,
                    Path(tmp) / "capture.log",
                    5000,
                )

        self.assertEqual(candidate.slide_id, "id.B")
        self.assertEqual(candidate.raw_hash, capture.image_hash(png_bytes(b"B")))
        self.assertEqual(stats.transition_crossed_attempts, 1)
        self.assertEqual(stats.unstable_candidate_attempts, 0)
        self.assertIn("sleep:1.0", events)

    def test_stability_pair_uses_only_configured_gap_between_a_and_b(self):
        events: list[str] = []

        def fake_sleep(seconds, _deadline):
            events.append(f"sleep:{round(seconds, 1)}")

        def fake_capture(_devtools, _config, **_kwargs):
            events.append("capture")
            return png_bytes(b"B")

        def fake_read(_devtools):
            events.append("read_id")
            return "id.B"

        with mock.patch.object(capture, "deadline_sleep", side_effect=fake_sleep), \
                mock.patch.object(capture, "capture_png", side_effect=fake_capture), \
                mock.patch.object(capture, "read_slide_id_now", side_effect=fake_read):
            candidate = capture.stable_raw_capture(
                object(),
                StableGap400Config(),
                capture.Deadline(30),
                5000,
            )

        self.assertEqual(candidate.slide_id, "id.B")
        self.assertEqual(events, ["sleep:0.8", "read_id", "capture", "sleep:0.4", "read_id", "capture"])

    def test_read_slide_id_timeout_is_unknown_and_capture_continues(self):
        class FakeDevTools:
            def call(self, _method, _params=None, timeout=10):
                raise TimeoutError("Connection timed out")

        self.assertEqual(capture.read_slide_id_now(FakeDevTools()), "")

        with mock.patch.object(capture, "deadline_sleep"), \
                mock.patch.object(capture, "capture_png", side_effect=[png_bytes(b"B"), png_bytes(b"B")]):
            candidate = capture.stable_raw_capture(
                FakeDevTools(),
                StableGap400Config(),
                capture.Deadline(30),
                5000,
            )

        self.assertEqual(candidate.slide_id, "")
        self.assertEqual(candidate.difference_percent, 0)

    def test_dark_transition_frame_is_rejected_before_stability_acceptance(self):
        stats = capture.CaptureStats(attempts=1)

        with mock.patch.object(capture, "deadline_sleep"), \
                mock.patch.object(capture, "read_slide_id_now", return_value="id.B"), \
                mock.patch.object(capture, "capture_png", side_effect=[png_solid(64, 36, (0, 0, 0)), png_bytes(b"B")]):
            with self.assertRaises(capture.TransitionOrBlankFrame):
                capture.stable_raw_capture(
                    object(),
                    StableGap400Config(),
                    capture.Deadline(30),
                    5000,
                    stats=stats,
                )

    def test_legitimate_dark_varied_slide_can_be_accepted(self):
        dark_slide = png_dark_varied(64, 36)

        with mock.patch.object(capture, "deadline_sleep"), \
                mock.patch.object(capture, "read_slide_id_now", return_value="id.dark"), \
                mock.patch.object(capture, "capture_png", side_effect=[dark_slide, dark_slide]):
            candidate = capture.stable_raw_capture(
                object(),
                StableGap400Config(),
                capture.Deadline(30),
                5000,
            )

        self.assertEqual(candidate.slide_id, "id.dark")
        self.assertEqual(candidate.difference_percent, 0)

    def test_capture_png_records_cdp_and_decode_timing(self):
        encoded = base64.b64encode(png_solid(DummyConfig.capture_width, DummyConfig.capture_height, (10, 20, 30))).decode("ascii")

        class FakeDevTools:
            def call(self, _method, _params=None, timeout=10):
                return {"data": encoded}

        devtools = FakeDevTools()
        png = capture.capture_png(devtools, DummyConfig())

        self.assertTrue(png.startswith(b"\x89PNG"))
        timing = getattr(devtools, "last_capture_timing")
        self.assertIn("cdp_capture_wait_ms", timing)
        self.assertIn("base64_decode_ms", timing)
        self.assertIn("png_decode_ms", timing)
        self.assertIn("total_capture_ms", timing)
        self.assertIn("cdp_received_at", timing)

    def test_remove_work_root_retries_directory_not_empty_without_warning(self):
        with tempfile.TemporaryDirectory() as tmp:
            work_root = Path(tmp) / "work"
            work_root.mkdir()
            config = DummyConfig()
            log_file = Path(tmp) / "capture.log"
            calls = []

            def fake_rmtree(path, ignore_errors=False):
                calls.append((path, ignore_errors))
                if len(calls) == 1:
                    raise OSError(errno.ENOTEMPTY, "Directory not empty")

            with mock.patch.object(capture.shutil, "rmtree", side_effect=fake_rmtree), \
                    mock.patch.object(capture.time, "sleep"), \
                    mock.patch.object(capture, "log_cleanup_warning") as warn:
                capture.remove_work_root(work_root, log_file, config)

        self.assertEqual(len(calls), 2)
        warn.assert_not_called()

    def test_presentation_round_accepts_three_delayed_slide_changes(self):
        first = capture.StableCandidate(png_bytes(b"A"), capture.image_hash(png_bytes(b"A")), "id.A", 0)
        second = capture.StableCandidate(png_bytes(b"B"), capture.image_hash(png_bytes(b"B")), "id.B", 80)
        third = capture.StableCandidate(png_bytes(b"C"), capture.image_hash(png_bytes(b"C")), "id.C", 80)
        back_to_first = capture.StableCandidate(png_bytes(b"A"), capture.image_hash(png_bytes(b"A")), "id.A", 80)

        def fake_save(_devtools, _config, _version_dir, candidate, images, stored_hashes):
            stored_hash = f"stored-{candidate.slide_id}"
            stored_hashes.append(stored_hash)
            images.append({
                "file": f"images/{candidate.slide_id}.png",
                "raw_hash": candidate.raw_hash,
                "stored_hash": stored_hash,
                "slide_id": candidate.slide_id,
            })

        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(capture, "wait_ready"), \
                    mock.patch.object(capture, "first_stable_raw_capture", return_value=first), \
                    mock.patch.object(capture, "wait_for_visual_change", side_effect=[second, third, back_to_first]), \
                    mock.patch.object(capture, "save_candidate", side_effect=fake_save), \
                    mock.patch.object(capture, "write_player_files"):
                manifest, stored_hashes, stats = capture.capture_presentation(
                    object(),
                    DummyConfig(),
                    Path(tmp),
                    capture.Deadline(30),
                    Path(tmp) / "capture.log",
                    time.monotonic(),
                )

        self.assertEqual(stats.stop_reason, "round_complete")
        self.assertEqual(stats.stable, 3)
        self.assertEqual(len(stored_hashes), 3)
        self.assertEqual(len(manifest["images"]), 3)
        self.assertEqual(manifest["stop_reason"], "round_complete")

    def test_distinct_slide_ids_forbid_single_slide_success(self):
        first = capture.StableCandidate(png_bytes(b"A"), capture.image_hash(png_bytes(b"A")), "id.A", 0)

        def fake_wait(_devtools, _config, _previous, _deadline, _started, stats, _log_file, _delay_ms, max_seconds=None, debug_dir=None):
            stats.observed_slide_ids.update({"id.A", "id.B"})
            stats.visual_change_seen = True
            if max_seconds is not None:
                return None
            raise capture.CaptureError("maximum captureduur bereikt")

        def fake_save(_devtools, _config, _version_dir, candidate, images, stored_hashes):
            stored_hashes.append("stored-A")
            images.append({"file": "images/id.A.png", "raw_hash": candidate.raw_hash, "stored_hash": "stored-A", "slide_id": candidate.slide_id})

        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(capture, "wait_ready"), \
                    mock.patch.object(capture, "first_stable_raw_capture", return_value=first), \
                    mock.patch.object(capture, "wait_for_visual_change", side_effect=fake_wait), \
                    mock.patch.object(capture, "save_candidate", side_effect=fake_save), \
                    mock.patch.object(capture, "write_player_files"):
                with self.assertRaises(capture.CaptureError):
                    capture.capture_presentation(
                        object(),
                        DummyConfig(),
                        Path(tmp),
                        capture.Deadline(30),
                        Path(tmp) / "capture.log",
                        time.monotonic(),
                    )

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

    def test_controlled_capture_error_preserves_cache_without_failed_exit(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = DummyConfig()
            config.warnings = []
            config.screenshot_cache_enabled = True
            config.max_capture_seconds = 30
            config.capture_debug_port = 9333
            args = mock.Mock(
                config_file=Path(tmp) / "config",
                home="",
                cache_root=str(Path(tmp) / "cache"),
                state_dir=str(Path(tmp) / "state"),
            )
            work_root = Path(tmp) / "cache" / "work" / "capture-demo"

            with mock.patch.object(capture, "read_config", return_value={}), \
                    mock.patch.object(capture, "build_content_config", return_value=config), \
                    mock.patch.object(capture, "acquire_lock", return_value=(None, False)), \
                    mock.patch.object(capture, "safe_work_dir", return_value=work_root), \
                    mock.patch.object(capture, "cleanup_stale_work", return_value=0), \
                    mock.patch.object(capture, "start_chromium", return_value=object()), \
                    mock.patch.object(capture, "wait_for_target", return_value={"webSocketDebuggerUrl": "ws://example", "id": "target"}), \
                    mock.patch.object(capture, "DevTools", return_value=mock.Mock()), \
                    mock.patch.object(capture, "set_viewport"), \
                    mock.patch.object(capture, "capture_presentation", side_effect=capture.CaptureError("maximum captureduur bereikt")), \
                    mock.patch.object(capture, "stop_chromium"), \
                    mock.patch.object(capture, "remove_work_root"), \
                    mock.patch.object(capture, "release_lock"):
                exit_code = capture.run_capture(args)

            self.assertEqual(exit_code, 0)

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
