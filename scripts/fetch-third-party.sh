#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 拉取 Windows 打包器需要的第三方源码/工具（固定版本，见 deps.lock）。
#
#   ./scripts/fetch-third-party.sh             # CLAP SDK（编译 clap-probe 用）
#   ./scripts/fetch-third-party.sh --pluginval # 顺带下 pluginval（VST3 验证器）
#   ./scripts/fetch-third-party.sh --wix       # 顺带下 WiX 3.14 免安装 zip（打 MSI 用）
#   ./scripts/fetch-third-party.sh --all       # 上面都要
#
# 与 mac 仓的 fetch-third-party.sh 相比简单得多：Windows 侧不需要 clap-wrapper /
# AudioUnitSDK（那是 AU 专用的），只剩 CLAP 头文件；CMake 也不参与构建。
#
# 网络：CLAP SDK 用 **git clone**（而不是下载 GitHub 的 archive zip）——
# 本机实测 github.com:443 直连不通，而 SSH(22) 与 git 协议可用；
# git 能吃到 ~/vpn.env 的代理，也能被 url.insteadOf 重写成 SSH。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib.sh
source "$ROOT/scripts/lib.sh"

TP="$ROOT/third_party"
mkdir -p "$TP"

WANT_PLUGINVAL=0
WANT_WIX=0
for a in "$@"; do
    case "$a" in
        --pluginval) WANT_PLUGINVAL=1 ;;
        --wix)       WANT_WIX=1 ;;
        --all)       WANT_PLUGINVAL=1; WANT_WIX=1 ;;
        -h|--help)   sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "未知参数：$a（--pluginval | --wix | --all）" ;;
    esac
done

CLAP_TAG="$(sed -n 's/^clap-sdk-tag *= *//p' "$ROOT/deps.lock" | tr -d '\r ')"
[ -n "$CLAP_TAG" ] || die "deps.lock 里没有 clap-sdk-tag"

log "==> CLAP SDK ${CLAP_TAG}"
if [ -f "$TP/clap/include/clap/clap.h" ]; then
    ok "已存在：$TP/clap/include/clap/clap.h"
else
    tmp="$TP/.clap-src"
    rm -rf "$tmp"
    ok_clone=0
    for url in "https://github.com/free-audio/clap.git" "git@github.com:free-audio/clap.git"; do
        log "    git clone --depth 1 --branch ${CLAP_TAG} ${url}"
        if git clone -q --depth 1 --branch "$CLAP_TAG" "$url" "$tmp" 2>/dev/null; then
            ok_clone=1
            break
        fi
        rm -rf "$tmp"
    done
    [ "$ok_clone" = "1" ] || die "拉取 CLAP SDK 失败：github 的 https 与 ssh 都不通
      - 受限网络先 source ~/vpn.env 再重跑
      - 或用 git 配置把 https 重写成 ssh：
          git config --global url.\"git@github.com:\".insteadOf https://github.com/"
    rm -rf "$TP/clap"
    mkdir -p "$TP/clap"
    cp -R "$tmp/include" "$TP/clap/include"
    cp "$tmp/LICENSE.md" "$TP/clap/" 2>/dev/null || true
    rm -rf "$tmp"
    ok "就绪：$TP/clap/include/clap/clap.h"
fi

if [ "$WANT_PLUGINVAL" = "1" ]; then
    log "==> pluginval"
    PV_URL="$(sed -n 's/^pluginval-url *= *//p' "$ROOT/deps.lock" | tr -d '\r ')"
    if [ -f "$TP/pluginval/pluginval.exe" ]; then
        ok "已存在：$TP/pluginval/pluginval.exe"
    else
        PY="$(find_python)" || die "找不到 python（解压 zip 用它，避免依赖 unzip）"
        ZIP="$TP/pluginval.zip"
        log "    下载 $PV_URL"
        if command -v curl >/dev/null 2>&1; then
            curl -fL --retry 3 -o "$ZIP" "$PV_URL" \
                || die "下载失败（GitHub 的 https 直连在本机不通：先 source ~/vpn.env 再重跑）"
        else
            "$PY" - "$PV_URL" "$ZIP" <<'PY' || die "下载失败（先 source ~/vpn.env 再重跑）"
import sys, urllib.request
urllib.request.urlretrieve(sys.argv[1], sys.argv[2])
PY
        fi
        mkdir -p "$TP/pluginval"
        "$PY" - "$ZIP" "$TP/pluginval" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
        rm -f "$ZIP"
        # zip 里可能带一层目录，摊平到 third_party/pluginval/
        if [ ! -f "$TP/pluginval/pluginval.exe" ]; then
            inner="$(find "$TP/pluginval" -maxdepth 3 -name pluginval.exe -print -quit)"
            [ -n "$inner" ] || die "zip 里没有 pluginval.exe"
            cp -R "$(dirname "$inner")/." "$TP/pluginval/"
        fi
        ok "就绪：$TP/pluginval/pluginval.exe"
    fi
fi

if [ "$WANT_WIX" = "1" ]; then
    log "==> WiX 3.14（打 MSI 用；免安装 zip，不需要 .NET SDK）"
    if [ -x "$TP/wix/candle.exe" ]; then
        ok "已存在：$TP/wix/candle.exe"
    else
        RX_URL="$(sed -n 's/^wix-binaries-url *= *//p' "$ROOT/deps.lock" | tr -d '\r ')"
        [ -n "$RX_URL" ] || die "deps.lock 里没有 wix-binaries-url"
        PY="$(find_python)" || die "找不到 python（解压 zip 用它，避免依赖 unzip）"
        ZIP="$TP/wix.zip"
        log "    下载 $RX_URL"
        if command -v curl >/dev/null 2>&1; then
            curl -fL --retry 3 -o "$ZIP" "$RX_URL" \
                || die "下载失败（GitHub 的 https 直连在本机不通：先 source ~/vpn.env 再重跑）"
        else
            "$PY" - "$RX_URL" "$ZIP" <<'PY' || die "下载失败（先 source ~/vpn.env 再重跑）"
import sys, urllib.request
urllib.request.urlretrieve(sys.argv[1], sys.argv[2])
PY
        fi
        mkdir -p "$TP/wix"
        "$PY" - "$ZIP" "$TP/wix" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
        rm -f "$ZIP"
        [ -x "$TP/wix/candle.exe" ] || die "zip 里没有 candle.exe（结构变了？）"
        ok "就绪：$TP/wix（$(ls -1 "$TP/wix" | wc -l) 个文件）"
    fi
fi

log
log "完成。"
