#!/usr/bin/env python3
"""Logt RAM- en swapgebruik los van de Google Slides-refresh."""

from __future__ import annotations

import os
import sys
from datetime import datetime, timedelta
from pathlib import Path


CONFIG_FILE = Path(os.environ.get("CONFIG_FILE", "/etc/digitalsignage/digitalsignage.conf"))
DEFAULT_SWAP_LOG_MAX_BYTES = 5 * 1024 * 1024
DEFAULT_RETENTION_DAYS = 3


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


def rotate_log_if_needed(log_file: Path, max_bytes: int) -> None:
    if not log_file.exists() or log_file.stat().st_size < max_bytes:
        return
    rotated = log_file.with_name("swap.log.1")
    if rotated.exists():
        rotated.unlink()
    log_file.rename(rotated)


def parse_log_time(line: str) -> datetime | None:
    first_field = line.split(maxsplit=1)[0] if line.strip() else ""
    if not first_field:
        return None
    try:
        return datetime.fromisoformat(first_field)
    except ValueError:
        return None


def prune_old_lines(log_file: Path, retention_days: int) -> None:
    if not log_file.exists():
        return
    cutoff = datetime.now().astimezone() - timedelta(days=retention_days)
    kept_lines: list[str] = []
    for line in log_file.read_text(encoding="utf-8").splitlines():
        logged_at = parse_log_time(line)
        if logged_at is not None and logged_at.tzinfo is None:
            logged_at = logged_at.replace(tzinfo=cutoff.tzinfo)
        if logged_at is None or logged_at >= cutoff:
            kept_lines.append(line)
    log_file.write_text("\n".join(kept_lines) + ("\n" if kept_lines else ""), encoding="utf-8")


def write_resource_log(max_bytes: int, retention_days: int) -> None:
    log_dir = Path.home() / ".local" / "state" / "digitalsignage"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "swap.log"
    prune_old_lines(log_file, retention_days)
    rotate_log_if_needed(log_file, max_bytes)

    fields = memory_fields()
    parts = [
        datetime.now().astimezone().isoformat(timespec="seconds"),
        "resource=ok",
        f"ram_used_mib={fields['ram_used_mib']}",
        f"ram_available_mib={fields['ram_available_mib']}",
        f"swap_used_mib={fields['swap_used_mib']}",
        f"swap_free_mib={fields['swap_free_mib']}",
    ]
    with log_file.open("a", encoding="utf-8") as handle:
        handle.write(" ".join(parts) + "\n")


def main() -> int:
    config = read_config(CONFIG_FILE)
    max_bytes = int_config(config, "SWAP_LOG_MAX_BYTES", DEFAULT_SWAP_LOG_MAX_BYTES)
    retention_days = int_config(config, "RESOURCE_LOG_RETENTION_DAYS", DEFAULT_RETENTION_DAYS)
    try:
        write_resource_log(max_bytes, retention_days)
    except Exception as exc:
        print(f"Fout: resource-log kon niet geschreven worden: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
