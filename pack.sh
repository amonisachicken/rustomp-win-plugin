#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# **rustomp-win-plugin 的入口** —— 契约 B 的实现（见 rustomp/docs/ecosystem.md §2）。
#
#   ./pack.sh <plugin_dir> [--variant mono|stereo|dual]... [--format vst3|clap]...
#             [--arch x64|arm64|both] [--install-both] [--no-install] [--no-verify]
#
# 成功：**只在 stdout** 逐行打印 `ARTIFACT: <绝对路径>`，退出码 0。
# 失败：非 0 退出 + 人话原因（缺 MSVC / 缺 rust target / 缺 cargo-nih-plug / 素材缺失 / 框架找不到…）。
#
# 框架（rustomp）只知道 `ARTIFACT:` 这一行，不知道 Windows 的任何细节。
#
# 与 macOS 版的差别：没有 AU（Windows 上没有 AU 这种宿主 API），
# 所以格式集合是 vst3 + clap，且没有 clap-wrapper / CMake / 签名 / 自检 App 那一整套。
set -euo pipefail

PACKER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 版本从 git tag 取（没装 git / 不是 clone 时退回硬编码）
PACKER_VERSION="$(git -C "$PACKER_ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
[ -n "$PACKER_VERSION" ] || PACKER_VERSION="0.1.0"

usage() {
    sed -n '4,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    echo
    echo "架构（--arch）："
    echo "  x64     默认；产出 <Name>.vst3 / <Name>.clap"
    echo "  arm64   产出 <Name> (ARM64).vst3 / <Name> (ARM64).clap"
    echo "  both    两套都产出；默认只把 x64 装到用户目录（两个架构的 identity 相同，"
    echo "          同一台机器装两份会让宿主扫到重复身份），要都装加 --install-both"
    echo
    echo "环境变量："
    echo "  RUSTOMP_ROOT       框架目录（默认自动探测：<plugin_dir>/../rustomp）"
    echo "  PLUGIN_DIR         等价于第一个位置参数"
    echo "  RUSTOMP_GUEST      若由框架/插件的 build.sh 调用，用它指定插件目录"
    echo "  RUSTOMP_BUILD_JOBS cargo -j 的并行度（默认：cargo 自己决定）"
    echo "  RUSTOMP_GIT_SSH    1 = 把 https://github.com 重写成 SSH 拉 git 依赖（本机 https 直连不通时用）"
    echo "  RUSTOMP_REQUIRE_VERIFY 1 = 缺验证工具即失败（CI 用）"
}

# shellcheck source=./scripts/lib.sh
source "$PACKER_ROOT/scripts/lib.sh"

PLUGIN_DIR="${PLUGIN_DIR:-}"
VARIANTS=()
FORMATS=()
ARCH="x64"
INSTALL_BOTH=0
INSTALL=1
VERIFY=1

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --variant) VARIANTS+=("${2:?--variant 需要参数}"); shift 2 ;;
        --format)  FORMATS+=("${2:?--format 需要参数}");  shift 2 ;;
        --arch)    ARCH="${2:?--arch 需要参数（x64|arm64|both）}"; shift 2 ;;
        --install-both) INSTALL_BOTH=1; shift ;;
        --no-install) INSTALL=0; shift ;;
        --no-verify)  VERIFY=0; shift ;;
        -*) die "未知参数：$1（--help 看用法）" ;;
        *)  if [ -n "$PLUGIN_DIR" ] && [ "$PLUGIN_DIR" != "$1" ]; then
                die "只能指定一个插件目录（已有 ${PLUGIN_DIR}，又给了 $1）"
            fi
            PLUGIN_DIR="$1"; shift ;;
    esac
done

[ -n "$PLUGIN_DIR" ] || { usage; exit 2; }
PLUGIN_DIR="$(cd "$PLUGIN_DIR" && pwd)" || die "插件目录不存在：$PLUGIN_DIR"
export PLUGIN_DIR
[ -f "$PLUGIN_DIR/rustomp.toml" ] || die "${PLUGIN_DIR} 不是插件项目（没有 rustomp.toml）"

[ ${#VARIANTS[@]} -gt 0 ] || VARIANTS=(mono stereo)
[ ${#FORMATS[@]}  -gt 0 ] || FORMATS=(vst3 clap)
for v in "${VARIANTS[@]}"; do
    case "$v" in mono|stereo|dual) ;; *) die "不支持的 variant：${v}（mono|stereo|dual）" ;; esac
done
case "$ARCH" in
    x64|arm64|both) ;;
    *) die "不支持的 arch：${ARCH}（x64|arm64|both）" ;;
esac
# 体检要知道目标架构：arm64 需要额外的 rust target 与 ARM64 MSVC 工具集
export RUSTOMP_ARCH="$ARCH"
for f in "${FORMATS[@]}"; do
    case "$f" in
        vst3|clap) ;;
        au) die "Windows 上没有 AU —— Audio Unit 是 Apple 的宿主 API，本平台只能出 VST3 / CLAP。
      这与 rustomp/docs/declarative-build.md §4.4 的平台矩阵一致（Windows: au ❌）。" ;;
        *) die "不支持的 format：${f}（vst3|clap）" ;;
    esac
done

# ---------------------------------------------------------------- 1. 体检
"$PACKER_ROOT/scripts/doctor.sh" || die "环境体检未通过（见上面缺什么）"

# ---------------------------------------------------------------- 2. 读 manifest
log "==> 读插件清单"
# shellcheck source=./scripts/plugin-env.sh
source "$PACKER_ROOT/scripts/plugin-env.sh"
log "    插件：${PLUGIN_NAME}（${PLUGIN_PACKAGE}）  框架：${RUSTOMP_ROOT}"

# 版本约束（契约：rustomp.toml [requires]）
REQ="$(py "$RUSTOMP_ROOT/tools/meta/plugin_meta.py" "$PLUGIN_DIR/rustomp.toml" --get requires.packer 2>/dev/null || true)"
if [ -n "$REQ" ]; then
    "$PYTHON" - "$REQ" "$PACKER_VERSION" <<'PY' || die "本打包工具版本不满足插件要求"
import sys, re
req, ver = sys.argv[1], sys.argv[2]
def parse(v):
    return tuple(int(x) for x in re.findall(r"\d+", v)[:2])
lo = (0, 0)
m = re.search(r">=\s*([\d.]+)", req)
if m: lo = parse(m.group(1))
if parse(ver) < lo:
    print(f"✗ 插件要求 packer {req}，当前 {ver}", file=sys.stderr)
    sys.exit(1)
PY
    log "    requires.packer = ${REQ}（当前 ${PACKER_VERSION}）"
fi

# ---------------------------------------------------------------- 3. 逐 variant 构建
for v in "${VARIANTS[@]}"; do
    log
    log "########## variant: ${v} ##########"
    args=("$v" --arch "$ARCH")
    [ "$INSTALL_BOTH" = "1" ] && args+=(--install-both)
    [ "$INSTALL" = "1" ] || args+=(--no-install)
    [ "$VERIFY"  = "1" ] || args+=(--no-verify)
    "$PACKER_ROOT/scripts/build-variant.sh" "${args[@]}"
done

# ---------------------------------------------------------------- 4. 契约 B 的输出
log
log "==> 产物"
ARTIFACTS=()
for v in "${VARIANTS[@]}"; do
    TSV="$PACKER_ROOT/build/artifacts-${v}.tsv"
    [ -f "$TSV" ] || die "缺产物清单：$TSV（构建脚本没写出结果？）"
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        for f in "${FORMATS[@]}"; do
            case "$p" in
                *".$f") ARTIFACTS+=("$p"); break ;;
            esac
        done
    done < "$TSV"
done

for a in "${ARTIFACTS[@]}"; do
    printf 'ARTIFACT: %s\n' "$a"
done
[ ${#ARTIFACTS[@]} -gt 0 ] || die "没有任何产物（检查 --format 与构建日志）"
