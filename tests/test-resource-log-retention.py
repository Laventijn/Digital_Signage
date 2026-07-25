#!/usr/bin/env python3
"""Controleert resource-logretentie met tijdelijke bestanden."""

from __future__ import annotations

import importlib.util
import tempfile
from datetime import datetime, timedelta
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT_DIR / "scripts" / "log-resources.py"


def load_module():
    spec = importlib.util.spec_from_file_location("log_resources", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("Kan log-resources.py niet laden")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    module = load_module()
    now = datetime.now().astimezone()
    recent_old_style = (now - timedelta(days=1)).isoformat(timespec="seconds")
    expired_old_style = (now - timedelta(days=4)).isoformat(timespec="seconds")

    assert "swap.log" not in (ROOT_DIR / "scripts" / "refresh-presentation.py").read_text(encoding="utf-8")
    assert "resource=ok" in MODULE_PATH.read_text(encoding="utf-8")

    with tempfile.TemporaryDirectory() as temp_dir:
        log_file = Path(temp_dir) / "swap.log"
        log_file.write_text(
            "\n".join([
                f"{recent_old_style} refresh=ok ram_used_mib=1 ram_available_mib=2 swap_used_mib=0 swap_free_mib=0",
                f"{expired_old_style} refresh=ok ram_used_mib=9 ram_available_mib=2 swap_used_mib=0 swap_free_mib=0",
            ])
            + "\n",
            encoding="utf-8",
        )
        module.prune_old_lines(log_file, retention_days=3)
        result = log_file.read_text(encoding="utf-8")
        assert recent_old_style in result
        assert expired_old_style not in result

    print("Resource-logretentie OK.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
