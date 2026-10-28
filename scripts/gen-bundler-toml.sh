#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 由 rustomp.toml 生成 nih-plug 的 bundler.toml。
#
#   ./scripts/gen-bundler-toml.sh [--variant mono|stereo|dual] [--name "自定义 bundle 名"]
#
# 为什么这件事在 Windows 上比 macOS 更重要：
#   nih-plug 的 bundle 文件名**只**由 bundler.toml 的 `name` 决定（不在命令行里传）。
#   macOS 那边是"先按原名构建，再把目录改名 + 改 plist"；Windows 的 VST3 是
#     <name>.vst3/Contents/x86_64-win/<name>.vst3
#   内层 DLL 名与外层目录名必须一致，改名很啰嗦 —— 所以这里**直接把变体名写进
#   bundler.toml**，让 bundler 一步到位产出正确的名字。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./plugin-env.sh
source "$ROOT/scripts/plugin-env.sh"

VARIANT=""
BUNDLE_NAME=""
while [ $# -gt 0 ]; do
    case "$1" in
        --variant) VARIANT="${2:?--variant 需要参数}"; shift 2 ;;
        --name)    BUNDLE_NAME="${2:?--name 需要参数}";   shift 2 ;;
        -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "未知参数：$1" ;;
    esac
done

if [ -z "$BUNDLE_NAME" ]; then
    case "${VARIANT:-dual}" in
        mono)   BUNDLE_NAME="$PLUGIN_NAME Mono" ;;
        stereo) BUNDLE_NAME="$PLUGIN_NAME Stereo" ;;
        dual|"") BUNDLE_NAME="$PLUGIN_NAME" ;;
        *) die "不支持的 variant：$VARIANT（mono|stereo|dual）" ;;
    esac
fi

# cargo-nih-plug 会 chdir 到**workspace 根**再读 bundler.toml，
# 所以写在那儿（插件只是某个 workspace 的成员时，两者不是同一个目录）。
OUT="$WS_ROOT/bundler.toml"
cat > "$OUT" <<EOT
# 由 rustomp-win-plugin 的 scripts/gen-bundler-toml.sh 从 rustomp.toml 生成，请勿手改。

["$PLUGIN_PACKAGE"]
name = "$BUNDLE_NAME"
EOT

printf '%s' "$BUNDLE_NAME"
