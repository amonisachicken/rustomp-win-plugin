#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 宿主侧验证：证明"打出来的东西真的能被加载、身份正确、端口正确"。
#
#   ./scripts/verify.sh --variant mono [--with-gui] [--require]
#
# 两道关卡（对应 Windows 上不存在 auval / au_smoke 的现实）：
#   1. **clap-probe**（本仓 tools/clap-probe，自写）：LoadLibrary 那个 .clap，
#      dump 插件 id/name/features、音频端口数与声道数、audio-ports-config、参数数。
#      → 回答了"这个变体到底声明了几进几出"，宿主菜单里看不出来、pluginval 也不细分。
#   2. **pluginval**（Tracktion，可选但强烈建议）：按 strictness 走官方那套
#      实例化/参数/状态/离线渲染检查，覆盖 VST3 这一类。
#
# 缺工具时的策略：
#   默认 **警告并跳过**（本地开发别被工具没装卡住）；
#   设 RUSTOMP_REQUIRE_VERIFY=1 或传 --require → **缺工具即失败**（CI 用，
#   避免"没验证"被当成"验证通过"——这是 mac 仓用 RUSTOMP_REQUIRE_NGSPICE 学到的教训）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./plugin-env.sh
source "$ROOT/scripts/plugin-env.sh"

VARIANT=""
WITH_GUI=0
REQUIRE="${RUSTOMP_REQUIRE_VERIFY:-0}"
while [ $# -gt 0 ]; do
    case "$1" in
        --variant) VARIANT="${2:?--variant 需要参数}"; shift 2 ;;
        --with-gui) WITH_GUI=1; shift ;;
        --require) REQUIRE=1; shift ;;
        *) die "未知参数：$1" ;;
    esac
done
[ -n "$VARIANT" ] || die "用法: $0 --variant <mono|stereo|dual> [--with-gui] [--require]"

case "$VARIANT" in
    mono)   SUFFIX=" Mono" ;;
    stereo) SUFFIX=" Stereo" ;;
    dual)   SUFFIX="" ;;
    *) die "未知变体：$VARIANT" ;;
esac
NAME="$PLUGIN_NAME$SUFFIX"
BUNDLED="$PLUGIN_DIR/target/bundled"
VST3="$BUNDLED/${NAME}.vst3"
CLAP="$BUNDLED/${NAME}.clap"

FAILED=0
SKIPPED=0

log "==> 宿主侧验证：${NAME}"

# ---------------------------------------------------------------- 1. clap-probe
if [ ! -f "$CLAP" ]; then
    warn "没有 CLAP 产物，跳过 clap-probe"
else
    SDK_INC="$ROOT/third_party/clap/include"
    if [ ! -f "$SDK_INC/clap/clap.h" ]; then
        warn "缺 CLAP SDK 头文件：$SDK_INC/clap/clap.h（跑 ./scripts/fetch-third-party.sh）"
        if [ "$REQUIRE" = "1" ]; then FAILED=1; else SKIPPED=1; fi
    else
        PROBE="$ROOT/build/clap_probe.exe"
        mkdir -p "$ROOT/build"
        log "  编译 clap-probe（MSVC）"
        msvc_run "$ROOT/build" \
            "cl /nologo /utf-8 /O2 /W3 /Fe:\"$(win_path "$PROBE")\" \"$(win_path "$ROOT/tools/clap-probe/clap_probe.c")\" /I\"$(win_path "$SDK_INC")\"" \
            || { warn "clap-probe 编译失败"; FAILED=1; }
        if [ -x "$PROBE" ] || [ -f "$PROBE" ]; then
            log "  --- clap-probe 输出 ---"
            set +e
            OUT="$("$PROBE" "$CLAP" 2>&1)"
            rc=$?
            set -e
            printf '%s\n' "$OUT" | sed 's/^/    /'
            if [ "$rc" != "0" ]; then
                warn "clap-probe 退出码 ${rc}（期望 0）"
                FAILED=1
            else
                # 会话内断言：变体声道数必须与变体名一致（mono=1 / stereo=2）
                case "$VARIANT" in
                    mono)  printf '%s' "$OUT" | grep -q 'channels=1' \
                             || { warn "mono 变体没报出 channels=1 的端口"; FAILED=1; } ;;
                    stereo) printf '%s' "$OUT" | grep -q 'channels=2' \
                             || { warn "stereo 变体没报出 channels=2 的端口"; FAILED=1; } ;;
                esac
                ok "clap-probe 通过"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------- 2. pluginval
PV="${PLUGINVAL:-}"
if [ -z "$PV" ]; then
    if [ -x "$ROOT/third_party/pluginval/pluginval.exe" ]; then
        PV="$ROOT/third_party/pluginval/pluginval.exe"
    elif command -v pluginval >/dev/null 2>&1; then
        PV="$(command -v pluginval)"
    fi
fi

if [ ! -d "$VST3" ]; then
    warn "没有 VST3 产物，跳过 pluginval"
elif [ -z "$PV" ]; then
    warn "没有 pluginval（./scripts/fetch-third-party.sh --pluginval 可自动下载）"
    if [ "$REQUIRE" = "1" ]; then FAILED=1; else SKIPPED=1; fi
else
    PV_ARGS=(--strictness-level "${PLUGINVAL_STRICTNESS:-5}" --validate "$VST3")
    [ "$WITH_GUI" = "1" ] || PV_ARGS+=(--skip-gui-tests)
    mkdir -p "$ROOT/build/pluginval-logs"
    PV_ARGS+=(--output-dir "$ROOT/build/pluginval-logs")
    log "  pluginval ${PV_ARGS[*]}"
    set +e
    "$PV" "${PV_ARGS[@]}" 2>&1 | sed 's/^/    /'
    rc=${PIPESTATUS[0]}
    set -e
    if [ "$rc" != "0" ]; then
        warn "pluginval 失败（退出码 ${rc}，日志：$ROOT/build/pluginval-logs）"
        FAILED=1
    else
        ok "pluginval 通过（strictness ${PLUGINVAL_STRICTNESS:-5}${WITH_GUI:+, 含 GUI}）"
    fi
fi

log
if [ "$FAILED" = "1" ]; then
    die "宿主侧验证未通过"
elif [ "$SKIPPED" = "1" ]; then
    warn "部分验证被跳过（不构成\"验证通过\"；CI 请设 RUSTOMP_REQUIRE_VERIFY=1）"
else
    ok "全部验证通过"
fi
