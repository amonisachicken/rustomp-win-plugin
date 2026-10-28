#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""
找出插件 crate 的版本号（MSI 的 ProductVersion 用它）。

  python scripts/plugin-version.py --ws <workspace 根> --package <包名>

规则：
  1. 在 workspace 根与它的直接子目录里找 `[package] name == <包名>` 的 Cargo.toml；
  2. 版本可能是 `version.workspace = true`（继承自 workspace），这时读
     `<ws>/Cargo.toml` 的 `[workspace.package] version`；
  3. 都找不到就退回 0.1.0（并在 stderr 上说一声）。
"""
from __future__ import annotations

import argparse
import sys
import tomllib
from pathlib import Path


def load(p: Path) -> dict | None:
    try:
        with open(p, "rb") as f:
            return tomllib.load(f)
    except Exception:
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ws", required=True)
    ap.add_argument("--package", required=True)
    a = ap.parse_args()

    ws = Path(a.ws)
    cands: list[Path] = [ws / "Cargo.toml"]
    cands += sorted(p for p in ws.glob("*/Cargo.toml"))

    ws_manifest = load(ws / "Cargo.toml") or {}
    ws_version = (ws_manifest.get("workspace", {}).get("package", {}) or {}).get("version")

    for c in cands:
        data = load(c)
        if not data:
            continue
        pkg = data.get("package", {})
        if pkg.get("name") != a.package:
            continue
        ver = pkg.get("version")
        if isinstance(ver, str) and ver:
            print(ver)
            return 0
        if isinstance(ver, dict) and ver.get("workspace") and ws_version:
            print(ws_version)
            return 0
        if ws_version:
            print(ws_version)
            return 0

    print("0.1.0")
    print(f"⚠ 找不到包 {a.package} 的版本，退回 0.1.0", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
