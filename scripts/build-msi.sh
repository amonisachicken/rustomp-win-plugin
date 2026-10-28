#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 把已构建好的产物打成 MSI 安装包（WiX 3.14，免安装 zip 版）。
#
#   ./scripts/build-msi.sh --variants "mono stereo" [--arch x64|arm64] [--scope both|machine|user]
#
# **为什么是两个包**：Windows Installer 没有可靠的"一个包既能装系统又能装用户"的路径
# （实测会出混合安装，见 docs/09-devlog.md E8）。所以按范围各出一个：
#   <Name> Setup (system).msi    → C:\Program Files\Common Files\VST3|CLAP   （需要管理员）
#   <Name> Setup (per-user).msi  → %LOCALAPPDATA%\Programs\Common\VST3|CLAP （免 UAC）
#
# 输出：每个 MSI 的绝对路径（Windows 形式）逐行打到 **stdout**，日志走 stderr。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./plugin-env.sh
source "$ROOT/scripts/plugin-env.sh"

VARIANTS_STR=""
ARCH="x64"
SCOPE="both"
OUT_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --variants) VARIANTS_STR="${2:?--variants 需要参数}"; shift 2 ;;
        --arch)     ARCH="${2:?--arch 需要参数（x64|arm64）}"; shift 2 ;;
        --scope)    SCOPE="${2:?--scope 需要参数（both|machine|user）}"; shift 2 ;;
        --out)      OUT_DIR="${2:?--out 需要参数}"; shift 2 ;;
        -h|--help)  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "未知参数：$1" ;;
    esac
done
[ -n "$VARIANTS_STR" ] || die "用法: $0 --variants \"mono stereo\" [--arch x64|arm64] [--scope both|machine|user]"
case "$ARCH" in x64|arm64) ;; *) die "未知架构：$ARCH（x64|arm64）" ;; esac
case "$SCOPE" in both|machine|user) ;; *) die "未知范围：$SCOPE（both|machine|user）" ;; esac

WIX="$ROOT/third_party/wix"
[ -x "$WIX/candle.exe" ] || die "没有 WiX（candle.exe）—— 先跑 ./scripts/fetch-third-party.sh --wix
      说明：本仓用 WiX 3.14 的免安装 zip（约 40 MB），不引入 .NET SDK。"

OUT_DIR="${OUT_DIR:-$ROOT/build/msi}"
mkdir -p "$OUT_DIR"

# ---- 收集产物 ----
SPEC_ITEMS="$OUT_DIR/items.tsv"
: > "$SPEC_ITEMS"
found=0
for v in $VARIANTS_STR; do
    TSV="$ROOT/build/artifacts-${v}-${ARCH}.tsv"
    [ -f "$TSV" ] || die "缺产物清单：$TSV（先构建变体 ${v} / 架构 ${ARCH}）"
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        # WiX 是 Windows 程序：Source 必须是 Windows 路径（C:\…），MSYS 的 /c/… 它不认
        wp="$(win_path "$p")"
        case "$p" in
            *.vst3) printf 'vst3\t%s\t%s\n' "$wp" "$(basename "$p")" >> "$SPEC_ITEMS"; found=$((found + 1)) ;;
            *.clap) printf 'clap\t%s\t%s\n' "$wp" "$(basename "$p")" >> "$SPEC_ITEMS"; found=$((found + 1)) ;;
        esac
    done < "$TSV"
done
[ "$found" -gt 0 ] || die "没有可打包的产物（--variants \"$VARIANTS_STR\" 里没有 .vst3/.clap）"

VERSION="$("$PYTHON" "$ROOT/scripts/plugin-version.py" --ws "$WS_ROOT" --package "$PLUGIN_PACKAGE")"
[ -n "$VERSION" ] || VERSION="0.1.0"

ARCH_TAG=""
[ "$ARCH" = "arm64" ] && ARCH_TAG=" (ARM64)"

build_one() {
    local scope="$1" suffix
    case "$scope" in
        machine) suffix=" (system)" ;;
        user)    suffix=" (per-user)" ;;
    esac
    local msi="$OUT_DIR/${PLUGIN_NAME} Setup${suffix}${ARCH_TAG}.msi"
    local spec="$OUT_DIR/spec-${scope}.json"
    local wxs="$OUT_DIR/product-${scope}.wxs"
    local obj="$OUT_DIR/product-${scope}.wixobj"

    "$PYTHON" - "$spec" "$SPEC_ITEMS" "$PLUGIN_NAME" "$PLUGIN_VENDOR" "$VERSION" \
              "${PLUGIN_URL:-}" "$ARCH" "$scope" <<'PY'
import json, sys
out, items_path, name, vendor, version, url, arch, scope = sys.argv[1:9]
items = []
for line in open(items_path, encoding="utf-8"):
    line = line.rstrip("\n")
    if not line:
        continue
    kind, src, install_name = line.split("\t")
    items.append({"kind": kind, "source": src, "install_name": install_name})
json.dump({"product_name": name, "manufacturer": vendor, "version": version,
           "url": url, "arch": arch, "scope": scope, "items": items},
          open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
    "$PYTHON" "$ROOT/scripts/gen-wix.py" --spec "$spec" --out "$wxs"

    log "==> candle（${scope}，arch=${ARCH}）"
    "$WIX/candle.exe" -nologo -arch "$ARCH" -out "$(win_path "$obj")" "$(win_path "$wxs")" >&2 \
        || die "candle 失败（${scope}）"
    log "==> light（${scope}）"
    "$WIX/light.exe" -nologo -sice:ICE91 -sice:ICE61 \
        -ext "$(win_path "$WIX/WixUIExtension.dll")" \
        -out "$(win_path "$msi")" "$(win_path "$obj")" >&2 \
        || die "light 失败（${scope}）"
    [ -f "$msi" ] || die "MSI 没生成：$msi"
    ok "MSI（${scope}）：$msi（$(( $(stat -c %s "$msi") / 1024 )) KB，版本 ${VERSION}）"
    win_path "$msi"
}

case "$SCOPE" in
    machine) build_one machine ;;
    user)    build_one user ;;
    both)    build_one machine; build_one user ;;
esac
