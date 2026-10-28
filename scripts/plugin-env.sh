#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 从插件的 rustomp.toml 载入身份/素材/界面配置（与 rustomp-mac-plugin 同构）。
#
# 本脚本属于 **rustomp-win-plugin**（打包工具），**不针对任何具体插件**：
# 所有插件相关的值都来自 `<插件目录>/rustomp.toml`（契约 A）。
#
# 读 manifest 的 `plugin_meta.py` 属于框架，所以需要知道 rustomp 在哪：
#   RUSTOMP_ROOT=/path/to/rustomp  （或 env，或 <插件目录>/../rustomp）
#
# 用法（必须 source）：
#   PLUGIN_DIR=<插件目录> source scripts/plugin-env.sh
#
# 注意：不要用位置参数——source 时 $1 会指向调用者的参数。
set -euo pipefail

_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib.sh
source "$_ROOT/scripts/lib.sh"

if [ -n "${PLUGIN_DIR:-}" ]; then
    _PLUGIN_DIR="$PLUGIN_DIR"
elif [ -n "${RUSTOMP_GUEST:-}" ] && [ -f "${RUSTOMP_GUEST}/rustomp.toml" ]; then
    _PLUGIN_DIR="$RUSTOMP_GUEST"
else
    die "请用 PLUGIN_DIR=<插件目录> 或 RUSTOMP_GUEST=<插件目录> 指定要操作的插件项目。
插件项目应当放在**本仓之外**（例如 ../my-effect）：
  ./pack.sh ../my-effect
原因：cargo-nih-plug 会向上找最顶层的 Cargo.toml，插件嵌在本仓里会报
      \"cannot specify features for packages outside of workspace\"。"
fi
[ -f "$_PLUGIN_DIR/rustomp.toml" ] || die "找不到 $_PLUGIN_DIR/rustomp.toml —— 这不是一个 rustomp 插件项目"
_PLUGIN_DIR="$(cd "$_PLUGIN_DIR" && pwd)"

# ---- 定位框架（manifest 读取器在 rustomp 里）----
if [ -z "${RUSTOMP_ROOT:-}" ]; then
    for cand in "$_PLUGIN_DIR/../rustomp" "$_PLUGIN_DIR/../rustomp-framework"; do
        if [ -f "$cand/tools/meta/plugin_meta.py" ]; then RUSTOMP_ROOT="$(cd "$cand" && pwd)"; break; fi
    done
fi
if [ -z "${RUSTOMP_ROOT:-}" ] || [ ! -f "$RUSTOMP_ROOT/tools/meta/plugin_meta.py" ]; then
    die "找不到 rustomp 框架（需要它里面的 tools/meta/plugin_meta.py 读 rustomp.toml）。
      约定：框架是插件项目的同级目录
        cd $(dirname "$_PLUGIN_DIR")
        git clone https://github.com/amonisachicken/rustomp.git rustomp
      或显式指定：RUSTOMP_ROOT=/path/to/rustomp"
fi
export RUSTOMP_ROOT

# ---- Python（≥3.11，要 tomllib）----
if ! PYTHON="${PYTHON:-$(find_python)}" || [ -z "$PYTHON" ]; then
    die "找不到可用的 python（需要 ≥3.11 的 tomllib）。
      MSYS2：pacman -S mingw-w64-clang-x86_64-python
      Windows：https://www.python.org/downloads/"
fi
export PYTHON

# ---- workspace 根（决定 bundler.toml 与 target/bundled 的位置）----
# cargo-nih-plug 的 chdir_workspace_root() 会从插件目录往上找**最顶层**带 Cargo.toml 的目录，
# 插件若只是某个更大 workspace 的成员，bundle 会落在那个 workspace 根下 —— 这里复刻同一规则。
_ws="$_PLUGIN_DIR"
_cur="$_PLUGIN_DIR"
while :; do
    if [ -f "$_cur/Cargo.toml" ]; then _ws="$_cur"; fi
    _parent="$(dirname "$_cur")"
    [ "$_parent" = "$_cur" ] && break
    _cur="$_parent"
done
WS_ROOT="$_ws"
export WS_ROOT

# ---- 载入清单（契约 A：一律经由框架的读取器，不自己解析 TOML）----
# 注意 `py` 会去掉 Python 在 Windows 上输出的 \r，否则每个变量尾部都会带 CR。
eval "$(py "$RUSTOMP_ROOT/tools/meta/plugin_meta.py" "$_PLUGIN_DIR/rustomp.toml" --shell)"
ROOT="$_ROOT"          # 打包工具根目录（scripts/、tools/ 都在这下面）
export ROOT
