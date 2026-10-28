#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 环境体检：缺什么就说清"怎么装"，不要等 cargo/MSVC 用天书报错。
#
#   ./scripts/doctor.sh           # 人读
#   ./scripts/doctor.sh --quiet   # 只报错（pack.sh 用）
set -uo pipefail

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT
# shellcheck source=./lib.sh
source "$ROOT/scripts/lib.sh"

bad()  { printf '  ✗ %s\n' "$*" >&2; MISSING=1; }
MISSING=0
[ "$QUIET" = "1" ] || echo "==> 环境体检（rustomp-win-plugin）" >&2

# ---- Shell 与基础工具（干净机器最容易缺的就是这一层）----
# 本仓全部脚本是 bash + MSYS 语义（cygpath / cp -R / POSIX 路径），
# 在 cmd/PowerShell/Linux-WSL 的 bash 里都不会正常工作。
case "$(uname -s 2>/dev/null || echo unknown)" in
    MSYS_NT*|MINGW64_NT*|MINGW32_NT*)
        ok "bash：MSYS 运行时（$(uname -s)，bash ${BASH_VERSION%%(*}）" ;;
    CYGWIN*)
        warn "bash：Cygwin（未实测；cygpath 与路径语义与 MSYS 有差异，建议改用 Git for Windows 或 MSYS2）" ;;
    Linux|Darwin)
        bad "bash：$(uname -s) —— 这是 **Windows** 打包器，必须在 Windows 上的
      Git for Windows（Git Bash）或 MSYS2 里跑，不能用 WSL 的 bash" ;;
    *)
        warn "bash：$(uname -s)（未识别；需要 MSYS 运行时）" ;;
esac
_missing_tools=""
for c in cygpath git sed tr head tail find mktemp cp rm mkdir; do
    command -v "$c" >/dev/null 2>&1 || _missing_tools="$_missing_tools $c"
done
if [ -z "$_missing_tools" ]; then
    ok "基础工具（cygpath/git/sed/tr/find/mktemp/cp …）"
else
    bad "缺基础命令：$_missing_tools
      → 装 Git for Windows（自带 Git Bash）或 MSYS2 后，在 **Git Bash / MSYS2 shell** 里跑本脚本"
fi

# ---- Rust：必须是 MSVC host，不能是 MSYS2 的 -gnu ----
if command -v rustc >/dev/null 2>&1; then
    _host="$(rustc -vV 2>/dev/null | awk '/^host:/{print $2}')"
    _ver="$(rustc -V 2>/dev/null | awk '{print $2}')"
    case "$_host" in
        x86_64-pc-windows-msvc) ok "rustc ${_ver}（host ${_host}）" ;;
        *-windows-gnu)
            bad "rustc 的 host 是 ${_host}（GNU ABI）—— Windows 插件必须用 MSVC 目标。
      原因：nih_plug 的 vst3 feature 依赖 vst3-sys，要编 Steinberg 的 C++；
            GNU ABI 与所有商用宿主的 CRT/异常模型不兼容。
      改法：用 rustup 装 MSVC 工具链并设为默认
        rustup toolchain install stable-x86_64-pc-windows-msvc
        rustup default stable-x86_64-pc-windows-msvc
      注意 PATH 里的 rustc 现在是：$(command -v rustc)（MSYS2 的 pacman 版），
      确保 ~/.cargo/bin 排在它前面。" ;;
        *) bad "rustc 的 host 是 ${_host}（本平台只支持 x86_64-pc-windows-msvc）" ;;
    esac
else
    bad "没有 rustc（装 Rust：https://rustup.rs，装完 rustup default stable-x86_64-pc-windows-msvc）"
fi

if command -v rustup >/dev/null 2>&1; then
    if rustup target list --installed 2>/dev/null | grep -qx 'x86_64-pc-windows-msvc'; then
        ok "rust target x86_64-pc-windows-msvc"
    else
        bad "缺 rust target x86_64-pc-windows-msvc（rustup target add x86_64-pc-windows-msvc）"
    fi
fi

# ---- MSVC / Windows SDK ----
if _vc="$(find_vcvars)"; then
    ok "MSVC 环境：$_vc"
else
    bad "没有 MSVC（找不到 vcvars64.bat）
      装法（管理员 PowerShell，约 3–6 GB）：
        winget install Microsoft.VisualStudio.2022.BuildTools --override \"--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended\""
fi

# ---- arm64 交叉工具链（只在 --arch arm64|both 时检查）----
case "${RUSTOMP_ARCH:-x64}" in
    arm64|both)
        if command -v rustup >/dev/null 2>&1; then
            if rustup target list --installed 2>/dev/null | grep -qx 'aarch64-pc-windows-msvc'; then
                ok "rust target aarch64-pc-windows-msvc"
            else
                bad "缺 rust target aarch64-pc-windows-msvc（rustup target add aarch64-pc-windows-msvc）"
            fi
        fi
        if _vca="$(find_vcvars arm64)"; then
            ok "MSVC arm64 交叉环境：$_vca"
        else
            bad "没有 ARM64 交叉工具集（找不到 vcvarsamd64_arm64.bat）
      装法（**必须一开始就提权**：静默模式不会自己弹 UAC）
        \"C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\setup.exe\" modify \\
          --installPath \"C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\" \\
          --add Microsoft.VisualStudio.Component.VC.Tools.ARM64 --quiet --norestart"
        fi
        ;;
esac

# ---- cargo-nih-plug：打包靠它（`cargo nih-plug bundle`）----
# 陷阱：`cargo nih-plug --help` 探测会误报（没有 --help 子命令，返回非 0）；
# 且开了 pipefail 时 `... | grep -q` 会让上游收到 SIGPIPE。所以用 command -v + case。
_have_nih_plug=0
command -v cargo-nih-plug >/dev/null 2>&1 && _have_nih_plug=1
if [ "$_have_nih_plug" = "0" ] && command -v cargo >/dev/null 2>&1; then
    case "$(cargo --list 2>/dev/null || true)" in *nih-plug*) _have_nih_plug=1 ;; esac
fi
if [ "$_have_nih_plug" = "1" ]; then
    ok "cargo-nih-plug"
else
    bad "没有 cargo-nih-plug（装法：cargo install --git https://github.com/robbert-vdh/nih-plug.git --rev de42101 cargo-nih-plug --locked）"
fi

# ---- python（读 rustomp.toml 用 tomllib）----
if _py="$(find_python)"; then
    ok "python：$_py（$("$_py" -V 2>&1)）"
else
    bad "没有可用 python（需要 ≥3.11 的 tomllib）
      MSYS2：pacman -S mingw-w64-clang-x86_64-python"
fi

# ---- 框架（读 manifest / 代码生成）----
FRAME="${RUSTOMP_ROOT:-}"
if [ -z "$FRAME" ] && [ -n "${PLUGIN_DIR:-}" ]; then
    [ -f "$PLUGIN_DIR/../rustomp/tools/meta/plugin_meta.py" ] && FRAME="$(cd "$PLUGIN_DIR/../rustomp" && pwd)"
fi
if [ -z "$FRAME" ] && [ -f "$ROOT/../rustomp/tools/meta/plugin_meta.py" ]; then
    FRAME="$(cd "$ROOT/../rustomp" && pwd)"
fi
if [ -n "$FRAME" ] && [ -f "$FRAME/tools/meta/plugin_meta.py" ]; then
    ok "rustomp 框架：$FRAME"
else
    bad "找不到 rustomp 框架 —— 读 rustomp.toml / 校验生成物都要用它
      约定：三个仓放在同一个目录（框架是插件项目的同级）
        cd \"\$(dirname <插件目录>)\"
        git clone https://github.com/amonisachicken/rustomp.git rustomp"
fi

# ---- 插件项目 ----
if [ -n "${PLUGIN_DIR:-}" ]; then
    ok "插件目录：$PLUGIN_DIR"
    if [ -d "$PLUGIN_DIR/plugin/src/generated" ]; then
        ok "生成物存在（plugin/src/generated）"
    else
        bad "缺 $PLUGIN_DIR/plugin/src/generated（先跑 rustomp-gen）"
    fi
    if _py="$(find_python)"; then
        PYTHON="$_py"; export PYTHON
        while IFS='=' read -r k rel; do
            [ -n "$k" ] || continue
            f="$PLUGIN_DIR/$rel"
            if [ -f "$f" ]; then ok "素材 ${k} ✓"; else bad "素材缺失：$f"; fi
        done < <(py - "$PLUGIN_DIR/rustomp.toml" <<'PY'
import sys
try:
    import tomllib
except ImportError:
    sys.exit(0)
d = tomllib.load(open(sys.argv[1], "rb"))
for k, v in d.get("assets", {}).items():
    print(f"{k}={v}")
PY
        )
    fi
fi

# ---- 可选：宿主侧验证器 ----
if [ -x "$ROOT/third_party/pluginval/pluginval.exe" ]; then
    ok "pluginval：$ROOT/third_party/pluginval/pluginval.exe"
elif command -v pluginval >/dev/null 2>&1; then
    ok "pluginval：$(command -v pluginval)"
else
    warn "没有 pluginval（VST3 宿主侧验证会跳过）
      装法：./scripts/fetch-third-party.sh --pluginval（或设 PLUGINVAL=/path/to/pluginval.exe）"
fi

exit "$MISSING"
