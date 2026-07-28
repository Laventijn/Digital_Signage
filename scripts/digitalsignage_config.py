#!/usr/bin/env python3
"""Gedeelde configuratiehulpen voor de Digital Signage-scripts."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import tempfile
import urllib.parse
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


SUPPORTED_CONTENT_MODES = {"presentation", "website"}
DEFAULT_PRESENTATION_DELAY_MS = 5000
WATERMARK_ELEMENT_ID = "digitalsignage-offline-watermark-capture-overlay"

DEFAULTS: dict[str, str] = {
    "CONTENT_MODE": "presentation",
    "CONTENT_URL": "",
    "PRESENTATION_URL": "",
    "SCREENSHOT_CACHE_ENABLED": "true",
    "SCREENSHOT_CACHE_REFRESH_SECONDS": "900",
    "SCREENSHOT_CAPTURE_WIDTH": "1920",
    "SCREENSHOT_CAPTURE_HEIGHT": "1080",
    "SCREENSHOT_CAPTURE_DEBUG_PORT": "9333",
    "SCREENSHOT_STABLE_GAP_MS": "400",
    "SCREENSHOT_CHANGE_POLL_MS": "500",
    "SCREENSHOT_TRANSITION_WAIT_MS": "750",
    "SCREENSHOT_MAX_SLIDES": "100",
    "SCREENSHOT_MAX_CAPTURE_SECONDS": "900",
    "SCREENSHOT_MAX_CONSECUTIVE_FAILURES": "10",
    "SCREENSHOT_DEBUG_STABILITY": "false",
    "SCREENSHOT_SINGLE_SLIDE_CONFIRM_SECONDS": "15",
    "SCREENSHOT_IMAGE_DIFFERENCE_PERCENT": "2",
    "SCREENSHOT_CACHE_KEEP_VERSIONS": "2",
    "OFFLINE_WATERMARK_TEXT": "Offline modus",
    "WEBSITE_OFFLINE_CAPTURE_MODE": "latest",
    "SCREENSHOT_LOG_RETENTION_DAYS": "3",
    "SCREENSHOT_LOG_MAX_BYTES": str(5 * 1024 * 1024),
}


@dataclass
class ContentConfig:
    mode: str
    content_url: str
    presentation_url: str
    effective_url: str
    screenshot_cache_enabled: bool
    capture_width: int
    capture_height: int
    capture_debug_port: int
    stable_gap_ms: int
    change_poll_ms: int
    transition_wait_ms: int
    max_slides: int
    max_capture_seconds: int
    max_consecutive_failures: int
    stability_debug_enabled: bool
    single_slide_confirm_seconds: int
    image_difference_percent: int
    keep_versions: int
    offline_watermark_text: str
    website_offline_capture_mode: str
    log_retention_days: int
    log_max_bytes: int
    warnings: list[str] = field(default_factory=list)


def read_config(path: Path, defaults: dict[str, str] | None = None) -> dict[str, str]:
    """Lees KEY=VALUE-regels zonder shell-evaluatie of variabele-expansie."""
    config = dict(defaults or DEFAULTS)
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


def effective_content_url(raw: dict[str, str]) -> str:
    """CONTENT_URL heeft voorrang; PRESENTATION_URL blijft fallback voor upgrades."""
    return raw.get("CONTENT_URL", "").strip() or raw.get("PRESENTATION_URL", "").strip()


def build_content_config(raw: dict[str, str]) -> ContentConfig:
    warnings: list[str] = []
    mode = raw.get("CONTENT_MODE", DEFAULTS["CONTENT_MODE"]).strip().lower() or DEFAULTS["CONTENT_MODE"]
    if mode not in SUPPORTED_CONTENT_MODES:
        warnings.append("ongeldige CONTENT_MODE; gebruik presentation of website")
    website_mode = raw.get("WEBSITE_OFFLINE_CAPTURE_MODE", "latest").strip().lower() or "latest"
    if website_mode != "latest":
        warnings.append("ongeldige WEBSITE_OFFLINE_CAPTURE_MODE; latest wordt gebruikt")
        website_mode = "latest"
    return ContentConfig(
        mode=mode,
        content_url=raw.get("CONTENT_URL", "").strip(),
        presentation_url=raw.get("PRESENTATION_URL", "").strip(),
        effective_url=effective_content_url(raw),
        screenshot_cache_enabled=bool_config(raw, "SCREENSHOT_CACHE_ENABLED", True, warnings),
        capture_width=int_config(raw, "SCREENSHOT_CAPTURE_WIDTH", 1920, warnings=warnings),
        capture_height=int_config(raw, "SCREENSHOT_CAPTURE_HEIGHT", 1080, warnings=warnings),
        capture_debug_port=int_config(raw, "SCREENSHOT_CAPTURE_DEBUG_PORT", 9333, warnings=warnings),
        stable_gap_ms=int_config(raw, "SCREENSHOT_STABLE_GAP_MS", 400, minimum=50, warnings=warnings),
        change_poll_ms=int_config(raw, "SCREENSHOT_CHANGE_POLL_MS", 500, minimum=100, warnings=warnings),
        transition_wait_ms=int_config(raw, "SCREENSHOT_TRANSITION_WAIT_MS", 750, minimum=0, warnings=warnings),
        max_slides=int_config(raw, "SCREENSHOT_MAX_SLIDES", 100, warnings=warnings),
        max_capture_seconds=int_config(raw, "SCREENSHOT_MAX_CAPTURE_SECONDS", 900, warnings=warnings),
        max_consecutive_failures=int_config(raw, "SCREENSHOT_MAX_CONSECUTIVE_FAILURES", 10, warnings=warnings),
        stability_debug_enabled=bool_config(raw, "SCREENSHOT_DEBUG_STABILITY", False, warnings),
        single_slide_confirm_seconds=int_config(raw, "SCREENSHOT_SINGLE_SLIDE_CONFIRM_SECONDS", 15, warnings=warnings),
        image_difference_percent=int_config(raw, "SCREENSHOT_IMAGE_DIFFERENCE_PERCENT", 2, minimum=0, warnings=warnings),
        keep_versions=int_config(raw, "SCREENSHOT_CACHE_KEEP_VERSIONS", 2, minimum=1, warnings=warnings),
        offline_watermark_text=raw.get("OFFLINE_WATERMARK_TEXT", DEFAULTS["OFFLINE_WATERMARK_TEXT"]).strip() or DEFAULTS["OFFLINE_WATERMARK_TEXT"],
        website_offline_capture_mode=website_mode,
        log_retention_days=int_config(raw, "SCREENSHOT_LOG_RETENTION_DAYS", 3, warnings=warnings),
        log_max_bytes=int_config(raw, "SCREENSHOT_LOG_MAX_BYTES", 5 * 1024 * 1024, warnings=warnings),
        warnings=warnings,
    )


def parse_delayms(url: str, default_ms: int = DEFAULT_PRESENTATION_DELAY_MS) -> int:
    parsed = urllib.parse.urlparse(url)
    values = urllib.parse.parse_qs(parsed.query).get("delayms", [])
    if not values:
        return default_ms
    try:
        value = int(values[0])
    except (TypeError, ValueError):
        return default_ms
    return value if value > 0 else default_ms


def parse_google_slides_id(url: str) -> str | None:
    match = re.search(r"/presentation/d/([^/]+)", urllib.parse.urlparse(url).path)
    return match.group(1) if match else None


def slide_id_from_url(url: str) -> str | None:
    parsed = urllib.parse.urlparse(url)
    fragment = urllib.parse.parse_qs(parsed.fragment).get("slide", [])
    if fragment:
        return fragment[0]
    values = urllib.parse.parse_qs(parsed.query).get("slide", [])
    return values[0] if values else None


def normalized_url(url: str) -> tuple[str, str, str, str]:
    parsed = urllib.parse.urlparse(url)
    return (parsed.scheme.lower(), parsed.netloc.lower(), parsed.path.rstrip("/"), parsed.query)


def same_url(left: str, right: str) -> bool:
    return bool(left and right and normalized_url(left) == normalized_url(right))


def sanitize_url_for_log(url: str) -> str:
    """Log geen queryparameters; die kunnen tokens of trackingwaarden bevatten."""
    parsed = urllib.parse.urlparse(url)
    return urllib.parse.urlunparse((parsed.scheme, parsed.netloc, parsed.path, "", "", ""))


def byte_difference_percent(left: bytes, right: bytes) -> float:
    if left == right:
        return 0.0
    max_len = max(len(left), len(right), 1)
    min_len = min(len(left), len(right))
    diff = abs(len(left) - len(right))
    diff += sum(1 for index in range(min_len) if left[index] != right[index])
    return diff * 100.0 / max_len


def screenshot_cache_root(home: Path) -> Path:
    return home / ".local" / "share" / "digitalsignage" / "screenshot-cache"


def screenshot_state_dir(home: Path) -> Path:
    return home / ".local" / "state" / "digitalsignage"


def screenshot_cache_index_url(home: Path) -> str:
    return screenshot_cache_root(home).joinpath("current", "index.html").resolve().as_uri()


def validate_cache_version(version_dir: Path) -> tuple[bool, str, dict[str, Any] | None]:
    allowed_top_level = {"index.html", "player.css", "player.js", "manifest.json", "images"}
    try:
        top_level = {path.name for path in version_dir.iterdir()}
    except OSError as exc:
        return False, f"cacheversie is onleesbaar: {exc}", None
    unexpected = sorted(top_level - allowed_top_level)
    if unexpected:
        return False, f"cacheversie bevat onverwachte bestanden of mappen: {', '.join(unexpected)}", None
    images_dir = version_dir / "images"
    if not images_dir.is_dir():
        return False, "images-map ontbreekt", None
    manifest_file = version_dir / "manifest.json"
    try:
        manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return False, f"manifest ongeldig: {exc}", None
    if manifest.get("mode") not in SUPPORTED_CONTENT_MODES:
        return False, "manifest bevat ongeldige mode", None
    images = manifest.get("images")
    if not isinstance(images, list) or not images:
        return False, "manifest bevat geen afbeeldingen", None
    try:
        slide_seconds = int(manifest.get("slide_seconds", 0))
    except (TypeError, ValueError):
        return False, "manifest bevat ongeldige slide_seconds", None
    if slide_seconds <= 0:
        return False, "manifest bevat ongeldige slide_seconds", None
    for required in ("index.html", "player.css", "player.js"):
        path = version_dir / required
        if not path.is_file() or path.stat().st_size <= 0:
            return False, f"spelerbestand ontbreekt of is leeg: {required}", None
    for index, image in enumerate(images, start=1):
        if not isinstance(image, dict) or "file" not in image:
            return False, f"afbeelding {index} is ongeldig", None
        image_path = version_dir / str(image["file"])
        if not image_path.is_file() or image_path.stat().st_size <= 0:
            return False, f"afbeelding ontbreekt of is leeg: {image['file']}", None
    if manifest["mode"] == "website" and len(images) != 1:
        return False, "websitemodus mag exact een afbeelding bevatten", None
    return True, "ok", manifest


def validate_current_cache(home: Path) -> tuple[bool, str, dict[str, Any] | None]:
    current = screenshot_cache_root(home) / "current"
    if not current.exists():
        return False, "screenshotcache ontbreekt", None
    return validate_cache_version(current.resolve())


def active_image_hashes(home: Path) -> list[str]:
    ok, _reason, manifest = validate_current_cache(home)
    if not ok or manifest is None:
        return []
    current = screenshot_cache_root(home) / "current"
    hashes: list[str] = []
    for image in manifest.get("images", []):
        image_path = current / str(image["file"])
        hashes.append(hashlib.sha256(image_path.read_bytes()).hexdigest())
    return hashes


def atomic_activate_version(cache_root: Path, version_dir: Path, keep_versions: int) -> None:
    current = cache_root / "current"
    tmp_link = cache_root / f".current.{os.getpid()}.tmp"
    if tmp_link.exists() or tmp_link.is_symlink():
        tmp_link.unlink()
    os.symlink(Path("versions") / version_dir.name, tmp_link, target_is_directory=True)
    os.replace(tmp_link, current)
    prune_old_versions(cache_root, keep_versions)


def prune_old_versions(cache_root: Path, keep_versions: int) -> None:
    versions_dir = cache_root / "versions"
    current_target = None
    current = cache_root / "current"
    if current.is_symlink():
        current_target = (cache_root / os.readlink(current)).resolve()
    versions = sorted((p for p in versions_dir.iterdir() if p.is_dir()), key=lambda p: p.name, reverse=True)
    for version in versions[max(keep_versions, 1):]:
        if current_target is not None and version.resolve() == current_target:
            continue
        shutil.rmtree(version, ignore_errors=True)


def rotate_log_if_needed(log_file: Path, max_bytes: int, rotated_name: str) -> None:
    if not log_file.exists() or log_file.stat().st_size < max_bytes:
        return
    rotated = log_file.with_name(rotated_name)
    if rotated.exists():
        rotated.unlink()
    log_file.rename(rotated)


def prune_old_log_lines(log_file: Path, retention_days: int, reference_time: datetime) -> None:
    if not log_file.exists():
        return
    cutoff = reference_time - timedelta(days=retention_days)
    kept: list[str] = []
    for line in log_file.read_text(encoding="utf-8").splitlines():
        first = line.split(maxsplit=1)[0] if line.strip() else ""
        try:
            logged_at = datetime.fromisoformat(first)
        except ValueError:
            kept.append(line)
            continue
        if logged_at.tzinfo is None:
            logged_at = logged_at.replace(tzinfo=timezone.utc)
        if logged_at >= cutoff:
            kept.append(line)
    log_file.write_text("\n".join(kept) + ("\n" if kept else ""), encoding="utf-8")


def safe_work_dir(cache_root: Path) -> Path:
    work_root = cache_root / "work"
    work_root.mkdir(parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix="capture-", dir=work_root))
