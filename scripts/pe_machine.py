#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""
读 PE 头里的 Machine 字段，判定 DLL/EXE 的真实目标架构。

  python scripts/pe_machine.py <file>            # 打印 x64 / arm64 / x86 / 其他
  python scripts/pe_machine.py <file> <expect>   # 与期望不符则退出码 1

为什么要它：目录名（Contents/arm_64-win）和文件名都可能骗人 —— 交叉编译时若
`vcvars64.bat` 用错（而不是 `vcvarsamd64_arm64.bat`），cargo 会"成功"产出一个
x64 的 DLL 放进 arm_64-win 目录里，直到用户在 ARM 机器上加载才炸。
"""
from __future__ import annotations

import struct
import sys

MACHINES = {
    0x014C: "x86",
    0x8664: "x64",
    0xAA64: "arm64",
    0xA641: "arm64ec",
    0x01C4: "armv7",
}


def machine(path: str) -> int | None:
    with open(path, "rb") as f:
        if f.read(2) != b"MZ":
            return None
        f.seek(0x3C)
        pe_offset = struct.unpack("<I", f.read(4))[0]
        f.seek(pe_offset)
        if f.read(4) != b"PE\0\0":
            return None
        return struct.unpack("<H", f.read(2))[0]


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    expect = sys.argv[2] if len(sys.argv) > 2 else None
    m = machine(path)
    if m is None:
        print(f"✗ {path}: 不是 PE 文件（MZ/PE 签名不符）", file=sys.stderr)
        return 1
    name = MACHINES.get(m, f"unknown(0x{m:04X})")
    if expect is not None:
        if name != expect:
            print(f"✗ {path}: PE 架构是 {name}，期望 {expect}", file=sys.stderr)
            return 1
        print(f"  ✓ {path.rsplit('/', 1)[-1]} ← PE {name}", file=sys.stderr)
        return 0
    print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
