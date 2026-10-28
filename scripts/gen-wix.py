#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""
由「产物清单」生成 WiX 源（.wxs），供 candle/light 编成 MSI。

    python scripts/gen-wix.py --spec build/msi/spec.json --out build/msi/product.wxs

spec.json（scripts/build-msi.sh 生成）：
  {
    "product_name": "Sparklin Drive",
    "manufacturer": "HONEYPIE EFFECTS",
    "version": "0.1.0",
    "url": "https://…",
    "arch": "x64",                        // x64 | arm64
    "scope": "machine",                   // machine（系统目录，需管理员）| user（用户目录，免 UAC）
    "items": [
      {"kind": "vst3", "source": "C:\\\\…\\\\Sparklin Drive Mono.vst3",
       "install_name": "Sparklin Drive Mono.vst3"},
      {"kind": "clap", "source": "C:\\\\…\\\\Sparklin Drive Mono.clap",
       "install_name": "Sparklin Drive Mono.clap"}
    ]
  }

**为什么按范围出两个 MSI**（而不是一个包里用向导选）：
实测过"单包 + ALLUSERS/MSIINSTALLPERUSER 切换 + 自定义向导页"的路子：
UI 序列按 per-user 定价、execute 序列又按 per-machine 重新定价，最终出现
**系统目录与用户目录同时被写入**的混合安装（见 docs/09-devlog.md E8）。
Windows Installer 对"同一个包既能装系统又能装用户"没有可靠的官方路径，
业界做法是两个固定范围的包（或一个 EXE 引导器去选包）。

其余设计要点：
  * GUID 全部**确定性推导**（uuid5）：同版本重复构建字节稳定；换版本自动换 ProductCode，
    `UpgradeCode` 保持稳定以便 MajorUpgrade 认亲。
  * 用户范围：组件**必须用 HKCU 注册表值做 KeyPath**（ICE38），且每层目录都要 RemoveFolder（ICE64）。
  * 系统范围：`CommonFiles64Folder`（= C:\\Program Files\\Common Files），组件 `Win64="yes"`。
  * UI 用 WixUI_Minimal（欢迎 → 确认 → 进度 → 完成），不再需要自定义对话框。
  * MSI 文本必须 ASCII：WiX 3.14 的 UI 扩展只带 en-US 资源，写中文会撞 LGHT0311。
"""
from __future__ import annotations

import argparse
import json
import uuid
from pathlib import Path
from xml.sax.saxutils import quoteattr

NS = uuid.UUID("6f3d1c9e-2a4b-5e6f-8a90-1b2c3d4e5f60")


def guid(*parts: str) -> str:
    return str(uuid.uuid5(NS, "|".join(parts))).upper()


def norm_version(v: str) -> str:
    nums: list[int] = []
    for chunk in (v or "").replace("-", ".").split("."):
        digits = "".join(ch for ch in chunk if ch.isdigit())
        nums.append(int(digits) if digits else 0)
    while len(nums) < 3:
        nums.append(0)
    return f"{nums[0]}.{nums[1]}.{nums[2]}"


class Gen:
    def __init__(self, arch: str, per_user: bool) -> None:
        self.arch = arch
        self.per_user = per_user
        self.o: list[str] = []
        self.uid = 0
        self.components: list[str] = []
        self.user_dirs: list[str] = []

    def w(self, line: str = "", ind: int = 0) -> None:
        self.o.append("  " * ind + line)

    def nid(self, prefix: str) -> str:
        self.uid += 1
        return f"{prefix}{self.uid}"

    # ------------------------------------------------------------------ 组件
    def component(self, *, seed: str, files: list[tuple[Path, str]], indent: int) -> None:
        comp_id = self.nid("C")
        comp_guid = guid(
            "component", seed, "U" if self.per_user else "M", self.arch,
            ",".join(n for _, n in files),
        )
        attrs = f'Id="{comp_id}" Guid="{comp_guid}"' + ("" if self.per_user else ' Win64="yes"')
        self.w(f"<Component {attrs}>", indent)
        for i, (path, fname) in enumerate(files):
            fid = self.nid("F")
            keypath = ' KeyPath="yes"' if (i == 0 and not self.per_user) else ""
            self.w(f'<File Id="{fid}" Name={quoteattr(fname)} Source={quoteattr(str(path))}{keypath}/>',
                   indent + 1)
        if self.per_user:
            self.w(f'<RegistryValue Root="HKCU" Key="Software\\rustomp-win-plugin" '
                   f'Name={quoteattr(comp_id)} Type="integer" Value="1" KeyPath="yes"/>', indent + 1)
            self.w(f'<RemoveFolder Id="{self.nid("RmDir")}" On="uninstall"/>', indent + 1)
        self.w("</Component>", indent)
        self.components.append(comp_id)

    # ------------------------------------------------------------------ 目录
    def directory(self, path: Path, indent: int) -> None:
        dir_id = self.nid("D")
        self.w(f'<Directory Id="{dir_id}" Name={quoteattr(path.name)}>', indent)
        files = [(p, p.name) for p in sorted(path.iterdir()) if p.is_file()]
        if files:
            self.component(seed=f"{path.name}", files=files, indent=indent + 1)
        for sub in sorted((p for p in path.iterdir() if p.is_dir()), key=lambda p: p.name):
            self.directory(sub, indent + 1)
        self.w("</Directory>", indent)
        if self.per_user:
            self.user_dirs.append(dir_id)

    def item_into(self, item: dict, indent: int) -> None:
        src = Path(item["source"])
        install_name = item["install_name"]
        if not src.is_dir():
            self.component(seed=install_name, files=[(src, install_name)], indent=indent)
            return
        top_id = self.nid("D")
        self.w(f'<Directory Id="{top_id}" Name={quoteattr(install_name)}>', indent)
        files = [(p, p.name) for p in sorted(src.iterdir()) if p.is_file()]
        if files:
            self.component(seed=f"{install_name}/.", files=files, indent=indent + 1)
        for sub in sorted((p for p in src.iterdir() if p.is_dir()), key=lambda p: p.name):
            self.directory(sub, indent + 1)
        self.w("</Directory>", indent)
        if self.per_user:
            self.user_dirs.append(top_id)


def build(spec: dict) -> str:
    name = spec["product_name"]
    manufacturer = spec.get("manufacturer", "")
    version = norm_version(spec.get("version", "0.1.0"))
    url = spec.get("url", "")
    arch = spec["arch"]
    scope = spec["scope"]
    items = spec["items"]
    per_user = scope == "user"

    # 两个范围是两个不同的产品身份（否则同一台机器上装两种范围会互相升级/覆盖）
    upgrade_code = guid("upgrade", name, scope)
    product_code = guid("product", name, scope, version, arch)
    g = Gen(arch, per_user)

    g.w('<?xml version="1.0" encoding="UTF-8"?>')
    g.w("<!-- generated by scripts/gen-wix.py - do not edit -->")
    g.w('<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">')
    g.w(f'<Product Id="{product_code}" Name={quoteattr(name)} Language="1033" Version="{version}"')
    g.w(f'         Manufacturer={quoteattr(manufacturer)} UpgradeCode="{upgrade_code}">', 1)
    if per_user:
        # 纯用户级包：不要求提升，装进 %LOCALAPPDATA%
        g.w('<Package InstallerVersion="500" Compressed="yes" InstallScope="perUser" '
            'InstallPrivileges="limited"/>', 1)
    else:
        g.w('<Package InstallerVersion="500" Compressed="yes" InstallScope="perMachine"/>', 1)
    g.w('<MediaTemplate EmbedCab="yes"/>', 1)
    g.w('<MajorUpgrade DowngradeErrorMessage="A newer version of [ProductName] is already installed." />', 1)
    if url:
        g.w(f'<Property Id="ARPHELPLINK" Value={quoteattr(url)}/>', 1)
    g.w("")

    # ---------------- 目录树 ----------------
    g.w('<Directory Id="TARGETDIR" Name="SourceDir">', 1)
    if per_user:
        g.w('<Directory Id="LocalAppDataFolder">', 2)
        g.w('<Directory Id="LAP_PROGRAMS" Name="Programs">', 3)
        g.w('<Directory Id="LAP_COMMON" Name="Common">', 4)
        g.w('<Directory Id="VST3ROOT" Name="VST3">', 5)
        for item in items:
            if item["kind"] == "vst3":
                g.item_into(item, 6)
        g.w("</Directory>", 5)
        g.w('<Directory Id="CLAPROOT" Name="CLAP">', 5)
        for item in items:
            if item["kind"] == "clap":
                g.item_into(item, 6)
        g.w("</Directory>", 5)

        dirs = list(dict.fromkeys(g.user_dirs + ["VST3ROOT", "CLAPROOT", "LAP_COMMON", "LAP_PROGRAMS"]))
        cid = g.nid("C")
        g.w(f'<Component Id="{cid}" Guid="{guid("component", "userdirs", arch)}">', 5)
        g.w('<RegistryValue Root="HKCU" Key="Software\\rustomp-win-plugin" '
            'Name="userdirs" Type="integer" Value="1" KeyPath="yes"/>', 6)
        for d in dirs:
            g.w(f'<RemoveFolder Id="{g.nid("Rm")}" Directory="{d}" On="uninstall"/>', 6)
        g.w("</Component>", 5)
        g.components.append(cid)
        g.w("</Directory>", 4)
        g.w("</Directory>", 3)
        g.w("</Directory>", 2)
    else:
        g.w('<Directory Id="CommonFiles64Folder">', 2)
        g.w('<Directory Id="VST3ROOT" Name="VST3">', 3)
        for item in items:
            if item["kind"] == "vst3":
                g.item_into(item, 4)
        g.w("</Directory>", 3)
        g.w('<Directory Id="CLAPROOT" Name="CLAP">', 3)
        for item in items:
            if item["kind"] == "clap":
                g.item_into(item, 4)
        g.w("</Directory>", 3)
        g.w("</Directory>", 2)
    g.w("</Directory>", 1)
    g.w("")

    # ---------------- Feature ----------------
    title = "Plugins (current user)" if per_user else "Plugins (all users)"
    g.w(f'<Feature Id="Plugins" Title="{title}" Level="1">', 1)
    for c in g.components:
        g.w(f'<ComponentRef Id="{c}"/>', 2)
    g.w("</Feature>", 1)
    g.w("")
    g.w('<UIRef Id="WixUI_Minimal"/>', 1)
    g.w("</Product>")
    g.w("</Wix>")
    return "\n".join(g.o) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    spec = json.loads(Path(a.spec).read_text(encoding="utf-8"))
    Path(a.out).write_text(build(spec), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
