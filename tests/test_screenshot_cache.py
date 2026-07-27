#!/usr/bin/env python3
"""Unit tests voor de lokale screenshotcache zonder echte Chromium-sessie."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


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


if __name__ == "__main__":
    unittest.main()
