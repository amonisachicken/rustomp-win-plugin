#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 构建一个变体（mono / stereo / dual），可指定目标架构，并安装。
#
#   ./scripts/build-variant.sh <mono|stereo|dual> [--arch x64|arm64|both] \
#                              [--no-install] [--no-verify] [--install-both]
#
# 与 macOS 版的差异（都是平台事实决定的）：
#   * 没有 `bundle-universal`（那是 lipo 专用），Windows 用 `cargo nih-plug bundle`；
#   * 不需要改 plist / 签名，**也不需要事后改名**：bundle 名直接写进 bundler.toml（见
#     gen-bundler-toml.sh），bundler 一步产出 `<Name>.vst3/Contents/<arch>-win/<Name>.vst3`；
#   * VST3 是**目录包**，CLAP 是**单文件 DLL**（两者在 Windows 上都由 nih-plug 自动产出）；
#   * 编译必须在 MSVC 环境里（vst3-sys 要编 Steinberg 的 C++），见 lib.sh 的 msvc_run；
#   * **没有"通用二进制"**：Windows 的 VST3 目录包按架构分子目录，宿主只认自己的那份，
#     所以两个架构是**两套独立产物**（arm64 的名字带 " (ARM64)"，见 ADR-w1）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./plugin-env.sh
source "$ROOT/scripts/plugin-env.sh"

VARIANT=""
ARCH="x64"
INSTALL=1
VERIFY=1
INSTALL_BOTH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)          ARCH="${2:?--arch 需要参数（x64|arm64|both）}"; shift 2 ;;
        --no-install)    INSTALL=0; shift ;;
        --no-verify)     VERIFY=0; shift ;;
        --install-both)  INSTALL_BOTH=1; shift ;;
        -*) die "未知参数：$1" ;;
        *)  VARIANT="$1"; shift ;;
    esac
done
[ -n "$VARIANT" ] || die "用法: $0 <mono|stereo|dual> [--arch x64|arm64|both] [--no-install] [--no-verify] [--install-both]"

case "$VARIANT" in
    mono)   SUFFIX=" Mono";   FEATURES="mono" ;;
    stereo) SUFFIX=" Stereo"; FEATURES="stereo" ;;
    dual)   SUFFIX="";        FEATURES="" ;;
    *) die "未知变体：${VARIANT}（mono|stereo|dual）" ;;
esac

case "$ARCH" in
    x64)   ARCHES=(x64) ;;
    arm64) ARCHES=(arm64) ;;
    both)  ARCHES=(x64 arm64) ;;
    *) die "未知架构：${ARCH}（x64|arm64|both）" ;;
esac

# 架构 → 名字后缀 / cargo target / VST3 子目录
arch_suffix() { case "$1" in x64) printf '' ;; arm64) printf ' (ARM64)' ;; esac; }
arch_triple() { case "$1" in x64) printf '' ;; arm64) printf 'aarch64-pc-windows-msvc' ;; esac; }
arch_vst3dir() { case "$1" in x64) printf 'x86_64-win' ;; arm64) printf 'arm_64-win' ;; esac; }
arch_pe()     { case "$1" in x64) printf 'x64' ;; arm64) printf 'arm64' ;; esac; }

# 哪些架构要装到用户目录。
# `both` 默认**只装 x64**：两套产物的 VST3 class id / CLAP id 完全相同（身份来自 identity.rs，
# 与架构无关），同一台机器上装两份会让宿主扫到重复身份（多数宿主会去重或告警）。
# 真要两个都装（例如同一台机器上有 x64 与 arm64 两个宿主），显式给 --install-both。
INSTALL_ARCHES=()
if [ "$INSTALL" = "1" ]; then
    if [ "$INSTALL_BOTH" = "1" ]; then
        INSTALL_ARCHES=("${ARCHES[@]}")
    elif [ "${#ARCHES[@]}" = "1" ]; then
        INSTALL_ARCHES=("${ARCHES[0]}")
    else
        INSTALL_ARCHES=(x64)
    fi
fi
wants_install() {
    local want="$1" a
    for a in "${INSTALL_ARCHES[@]+"${INSTALL_ARCHES[@]}"}"; do [ "$a" = "$want" ] && return 0; done
    return 1
}

mkdir -p "$ROOT/build"

for a in "${ARCHES[@]}"; do
    NAME="$PLUGIN_NAME$SUFFIX$(arch_suffix "$a")"
    TRIPLE="$(arch_triple "$a")"
    VST3_SUB="$(arch_vst3dir "$a")"
    # 每个 (变体, 架构) 一份产物清单：MSI 按架构打包时要精确挑，不能靠文件名猜
    TSV="$ROOT/build/artifacts-${VARIANT}-${a}.tsv"
    : > "$TSV"

    log
    log "===== ${VARIANT} / ${a} → ${NAME} ====="

    # ------------------------------------------------------------ 1. bundler.toml
    log "==> [1/4] bundler.toml（bundle 名 = ${NAME}）"
    "$ROOT/scripts/gen-bundler-toml.sh" --name "$NAME" >/dev/null

    # ------------------------------------------------------------ 2. 编译 + 打包
    log "==> [2/4] 构建 ${NAME}（MSVC/${a}，feature=${FEATURES:-<无，即 dual>}）"
    CARGO_CMD="cargo nih-plug bundle $PLUGIN_PACKAGE --release"
    [ -n "$FEATURES" ] && CARGO_CMD="$CARGO_CMD --features $FEATURES"
    # 交叉到 arm64 时必须显式给 --target（否则编的是宿主架构）
    [ -n "$TRIPLE" ] && CARGO_CMD="$CARGO_CMD --target $TRIPLE"
    [ -n "${RUSTOMP_BUILD_JOBS:-}" ] && CARGO_CMD="$CARGO_CMD -j $RUSTOMP_BUILD_JOBS"
    msvc_run "$PLUGIN_DIR" "$a" "$CARGO_CMD" \
        || die "编译/打包失败（${CARGO_CMD}）"

    BUNDLED="$WS_ROOT/target/bundled"
    VST3="$BUNDLED/${NAME}.vst3"
    CLAP="$BUNDLED/${NAME}.clap"

    # ------------------------------------------------------------ 3. 校验产物形状
    log "==> [3/4] 校验产物（架构 = ${a}）"
    [ -d "$VST3" ] || die "VST3 产物缺失：$VST3（检查 bundler.toml 的 name 与 cargo nih-plug 的输出）"
    VST3_DLL="$VST3/Contents/${VST3_SUB}/${NAME}.vst3"
    [ -f "$VST3_DLL" ] || die "VST3 目录包结构不对，找不到内层 DLL：$VST3_DLL
      VST3 在 Windows 上要求 <name>.vst3/Contents/<arch>-win/<name>.vst3（内层与外层同名）"
    ok "VST3：$VST3"

    if [ -f "$CLAP" ]; then
        ok "CLAP：$CLAP"
    else
        warn "CLAP 产物缺失：$CLAP（插件若没导出 clap 入口属正常）"
    fi

    # PE 头里的 machine 字段是"这个 DLL 到底是哪个架构"的唯一硬证据 ——
    # 名字和目录都可能骗人（交叉编译配错 vcvars 时尤其容易）。
    "$PYTHON" "$ROOT/scripts/pe_machine.py" "$VST3_DLL" "$(arch_pe "$a")" \
        || die "VST3 DLL 的 PE 架构不是 ${a}（vcvars 用错了？arm64 必须用 vcvarsamd64_arm64.bat）"
    if [ -f "$CLAP" ]; then
        "$PYTHON" "$ROOT/scripts/pe_machine.py" "$CLAP" "$(arch_pe "$a")" \
            || die "CLAP 的 PE 架构不是 ${a}"
    fi
    ok "PE 架构校验通过（${a}）"

    # ------------------------------------------------------------ 4. 安装
    if wants_install "$a"; then
        log "==> [4/4] 安装（${a}）"
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
    else
        log "==> [4/4] 跳过安装（该架构不在安装列表：${INSTALL_ARCHES[*]:-无}）"
    fi

    # ------------------------------------------------------------ 5. 宿主侧验证
    if [ "$VERIFY" = "1" ]; then
        "$ROOT/scripts/verify.sh" --variant "$VARIANT" --arch "$a" || die "宿主侧验证未通过"
    fi

    printf '%s\n' "$VST3" >> "$TSV"
    [ -f "$CLAP" ] && printf '%s\n' "$CLAP" >> "$TSV"
done

log
log "完成：${PLUGIN_NAME}${SUFFIX}（${VARIANT}，架构 ${ARCH}）"
exit 0
