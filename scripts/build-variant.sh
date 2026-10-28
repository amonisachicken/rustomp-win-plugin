#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 构建一个变体（mono / stereo / dual）并安装。
#
#   ./scripts/build-variant.sh <mono|stereo|dual> [--no-install] [--no-verify]
#
# 与 macOS 版的差异（都是平台事实决定的）：
#   * 没有 `bundle-universal`（那是 lipo 专用），Windows 用 `cargo nih-plug bundle`；
#   * 不需要改 plist / 签名，**也不需要事后改名**：变体名直接写进 bundler.toml（见
#     gen-bundler-toml.sh），bundler 一步产出 `<Name>.vst3/Contents/x86_64-win/<Name>.vst3`；
#   * VST3 是**目录包**，CLAP 是**单文件 DLL**（两者在 Windows 上都由 nih-plug 自动产出）；
#   * 编译必须在 MSVC 环境里（vst3-sys 要编 Steinberg 的 C++），见 lib.sh 的 msvc_run。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./plugin-env.sh
source "$ROOT/scripts/plugin-env.sh"

VARIANT=""
INSTALL=1
VERIFY=1
for a in "$@"; do
    case "$a" in
        --no-install) INSTALL=0 ;;
        --no-verify)  VERIFY=0 ;;
        -*) die "未知参数：$a" ;;
        *)  VARIANT="$a" ;;
    esac
done
[ -n "$VARIANT" ] || die "用法: $0 <mono|stereo|dual> [--no-install] [--no-verify]"

case "$VARIANT" in
    mono)   SUFFIX=" Mono";   FEATURES="mono" ;;
    stereo) SUFFIX=" Stereo"; FEATURES="stereo" ;;
    dual)   SUFFIX="";        FEATURES="" ;;
    *) die "未知变体：${VARIANT}（mono|stereo|dual）" ;;
esac
NAME="$PLUGIN_NAME$SUFFIX"

# ---------------------------------------------------------------- 1. bundler.toml
log "==> [1/4] bundler.toml（bundle 名 = ${NAME}）"
"$ROOT/scripts/gen-bundler-toml.sh" --variant "$VARIANT" >/dev/null

# ---------------------------------------------------------------- 2. 编译 + 打包
log "==> [2/4] 构建 ${NAME}（MSVC，feature=${FEATURES:-<无，即 dual>}）"
CARGO_CMD="cargo nih-plug bundle $PLUGIN_PACKAGE --release"
[ -n "$FEATURES" ] && CARGO_CMD="$CARGO_CMD --features $FEATURES"
[ -n "${RUSTOMP_BUILD_JOBS:-}" ] && CARGO_CMD="$CARGO_CMD -j $RUSTOMP_BUILD_JOBS"
msvc_run "$PLUGIN_DIR" "$CARGO_CMD" || die "编译/打包失败（cargo nih-plug bundle $PLUGIN_PACKAGE --release --features ${FEATURES}）"

BUNDLED="$PLUGIN_DIR/target/bundled"
VST3="$BUNDLED/${NAME}.vst3"
CLAP="$BUNDLED/${NAME}.clap"

# ---------------------------------------------------------------- 3. 校验产物形状
log "==> [3/4] 校验产物"
[ -d "$VST3" ] || die "VST3 产物缺失：$VST3（检查 bundler.toml 的 name 与 cargo nih-plug 的输出）"
VST3_DLL="$VST3/Contents/x86_64-win/${NAME}.vst3"
[ -f "$VST3_DLL" ] || die "VST3 目录包结构不对，找不到内层 DLL：$VST3_DLL
      VST3 规范要求 <name>.vst3/Contents/x86_64-win/<name>.vst3，内层名与外层一致"
ok "VST3：$VST3"
if [ -f "$CLAP" ]; then
    ok "CLAP：$CLAP"
    CLAP_DONE=1
else
    warn "CLAP 产物缺失：$CLAP（插件若未启用 clap feature 属正常；Windows 上 .clap 是单文件 DLL）"
    CLAP_DONE=""
fi

# ---------------------------------------------------------------- 4. 安装
log "==> [4/4] 安装"
if [ "$INSTALL" = "0" ]; then
    log "    （--no-install：跳过安装）"
else
    DST_VST3="$(install_dir_vst3)" || die "取不到 %LOCALAPPDATA%"
    mkdir -p "$DST_VST3"
    rm -rf "$DST_VST3/${NAME}.vst3"
    cp -R "$VST3" "$DST_VST3/"
    ok "安装 VST3 → $DST_VST3/${NAME}.vst3"

    if [ -f "$CLAP" ]; then
        DST_CLAP="$(install_dir_clap)" || die "取不到 %LOCALAPPDATA%"
        mkdir -p "$DST_CLAP"
        rm -f "$DST_CLAP/${NAME}.clap"
        cp "$CLAP" "$DST_CLAP/"
        ok "安装 CLAP → $DST_CLAP/${NAME}.clap"
    fi
fi

# ---------------------------------------------------------------- 5. 宿主侧验证
if [ "$VERIFY" = "1" ]; then
    "$ROOT/scripts/verify.sh" --variant "$VARIANT" || die "宿主侧验证未通过"
fi

log
log "完成：${NAME}  →  VST3${CLAP_DONE:+ / CLAP}（${VARIANT}）"
# 供 pack.sh 收集（契约 B 的路径表）。**不写 stdout**：stdout 只允许 ARTIFACT 行。
mkdir -p "$ROOT/build"
: > "$ROOT/build/artifacts-${VARIANT}.tsv"
printf '%s\n' "$VST3" >> "$ROOT/build/artifacts-${VARIANT}.tsv"
[ -f "$CLAP" ] && printf '%s\n' "$CLAP" >> "$ROOT/build/artifacts-${VARIANT}.tsv"
exit 0
