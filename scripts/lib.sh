#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 公共库（必须 source）：日志、Python 发现、MSVC 环境发现与"在 vcvars 里跑命令"、
# Windows 用户级安装目录。
#
# 设计约束（Windows + MSYS2 的现实）：
#   1) MSVC 的环境变量（INCLUDE/LIB/PATH）无法用 bash `source` 进来 —— PATH 会被
#      改成 Windows 分号形式，bash 立刻找不到自己的工具。所以**不在 bash 里注入**，
#      而是生成一个 .bat：先 call vcvars64.bat，再执行命令。见 msvc_run()。
#   2) MSYS 的 bash 里 HOME=/home/Admin，**不是** C:\Users\Admin；
#      求"用户目录"必须走 LOCALAPPDATA/USERPROFILE + cygpath，不能用 $HOME。
#   3) 路径进 .bat 前一律 cygpath -w 转换，绝不手拼。

set -euo pipefail

# ---------------------------------------------------------------- PATH

# 让 rustup 的 shim 目录（~/.cargo/bin）排在前面。
# 两个坑：
#   1) MSYS 的 bash 里 HOME=/home/Admin，**不是** C:\Users\<me>，所以不能用 $HOME；
#   2) pacman 装的 rustc 是 -gnu（/c/msys64/clang64/bin），常常排在 PATH 更前面，
#      不优先就会用 GNU ABI 去编 Windows 插件 —— 必然失败，且报错很难懂。
_cargo_bin=""
if [ -n "${USERPROFILE:-}" ]; then
    _cargo_bin="$(cygpath -u "$USERPROFILE" 2>/dev/null)/.cargo/bin"
fi
if [ -n "$_cargo_bin" ] && [ -d "$_cargo_bin" ]; then
    case ":$PATH:" in
        *":$_cargo_bin:"*) ;;
        *) PATH="$_cargo_bin:$PATH"; export PATH ;;
    esac
fi

log()  { printf '%s\n' "$*" >&2; }
warn() { printf '  ! %s\n' "$*" >&2; }
# 全部日志都走 stderr：契约 B 规定 **stdout 只有 `ARTIFACT: <路径>` 这一种行**，
# 框架用它当"打包成功与否"的唯一信号，任何杂音都会污染解析。
ok()   { printf '  ✓ %s\n' "$*" >&2; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- Windows 路径

win_path() { cygpath -w "$1"; }

# 从 Python 取文本时必须过这个：Windows 的原生 Python 在文本模式下把 `\n` 写成
# `\r\n`，bash 的 `read` / `eval` 会把这颗 `\r` 当成内容的一部分
# —— 症状是 `[ -f "$path" ]` 明明路径正确却判定文件不存在、eval 出的变量尾部带怪字符。
py() { "$PYTHON" "$@" | tr -d '\r'; }

# 用户的 LocalAppData（POSIX 形式）
local_appdata() {
    local p
    if [ -n "${LOCALAPPDATA:-}" ]; then
        p="$LOCALAPPDATA"
    elif [ -n "${USERPROFILE:-}" ]; then
        p="${USERPROFILE}\\AppData\\Local"
    else
        return 1
    fi
    cygpath -u "$p"
}

# 用户级安装目录（免 UAC；大多数宿主都会扫这里）
install_dir_vst3() { local a; a="$(local_appdata)" || return 1; printf '%s/Programs/Common/VST3' "$a"; }
install_dir_clap() { local a; a="$(local_appdata)" || return 1; printf '%s/Programs/Common/CLAP' "$a"; }

# ---------------------------------------------------------------- Python

# 找一个能 `import tomllib`（≥3.11）的 Python。
# MSYS2 的 python3 不一定在登录 shell 的 PATH 里，所以显式探几个已知位置。
find_python() {
    local c
    local -a cands=()
    if [ -n "${PYTHON:-}" ]; then cands+=("$PYTHON"); fi
    for c in python3 python; do
        if command -v "$c" >/dev/null 2>&1; then cands+=("$(command -v "$c")"); fi
    done
    for c in /c/msys64/clang64/bin/python3.exe \
             /c/msys64/mingw64/bin/python3.exe \
             /c/msys64/usr/bin/python3.exe; do
        [ -x "$c" ] && cands+=("$c")
    done
    for c in /c/Users/*/AppData/Local/Programs/Python/Python3*/python.exe; do
        [ -x "$c" ] && cands+=("$c")
    done
    local p
    for p in "${cands[@]+"${cands[@]}"}"; do
        if "$p" -c 'import tomllib' >/dev/null 2>&1; then
            printf '%s' "$p"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------- MSVC

# vcvars64.bat 的路径（POSIX 形式）。优先 vswhere（能挑到任意安装位置与版本）。
find_vcvars() {
    local vsw="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
    local inst
    if [ -x "$vsw" ]; then
        inst="$("$vsw" -latest -products '*' \
                    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
                    -property installationPath 2>/dev/null | tr -d '\r' | head -1 || true)"
        if [ -n "$inst" ]; then
            inst="$(cygpath -u "$inst" 2>/dev/null || true)"
            if [ -n "$inst" ] && [ -f "$inst/VC/Auxiliary/Build/vcvars64.bat" ]; then
                printf '%s' "$inst/VC/Auxiliary/Build/vcvars64.bat"
                return 0
            fi
        fi
    fi
    local g
    for g in "/c/Program Files/Microsoft Visual Studio/2022"/*/VC/Auxiliary/Build/vcvars64.bat \
             "/c/Program Files (x86)/Microsoft Visual Studio/2022"/*/VC/Auxiliary/Build/vcvars64.bat; do
        if [ -f "$g" ]; then printf '%s' "$g"; return 0; fi
    done
    return 1
}

# 在 MSVC 环境里跑一条 cmd 命令行。
#
#   msvc_run <workdir(POSIX)> <cmd 命令行（Windows 风格，已自行加引号）>
#
# 用"生成 .bat 再 cmd //c 调它"而不是 `cmd //c "call vcvars && ..."`：
# MSYS 会把长参数里的路径/斜杠做启发式转换，实测会破坏 `&&` 链与引号。
msvc_run() {
    local workdir="$1"; shift
    local cmdline="$*"
    local vc bat v
    vc="$(find_vcvars)" || die "找不到 vcvars64.bat —— 需要 Visual Studio Build Tools 的「使用 C++ 的桌面开发」工作负载
      装法（管理员）：winget install Microsoft.VisualStudio.2022.BuildTools --override \"--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended\""
    mkdir -p "$ROOT/build"
    bat="$ROOT/build/.msvc.bat"
    {
        printf '@echo off\r\n'
        printf 'call "%s" >nul 2>&1\r\n' "$(win_path "$vc")"
        printf 'if errorlevel 1 exit /b 9\r\n'

        # ---- 网络环境透传 ----
        # 代理变量必须显式带进 cmd：cargo 的 git 依赖、crates 下载都走它们。
        for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY; do
            if [ -n "${!v:-}" ]; then printf 'set %s=%s\r\n' "$v" "${!v}"; fi
        done
        # cargo 默认用 libgit2 拉 git 依赖，它**不认** git 的 url.insteadOf / 代理配置；
        # 改成走 git CLI 才有救（本机实测 github.com:443 直连不通，SSH 与代理可用）。
        printf 'set CARGO_NET_GIT_FETCH_WITH_CLI=true\r\n'
        # 可选：把 https://github.com 重写成 SSH（RUSTOMP_GIT_SSH=1）。
        # 用 GIT_CONFIG_COUNT 注入，**不改用户的全局 git 配置**。
        if [ "${RUSTOMP_GIT_SSH:-0}" = "1" ]; then
            printf 'set GIT_CONFIG_COUNT=1\r\n'
            printf 'set GIT_CONFIG_KEY_0=url.git@github.com:.insteadOf\r\n'
            printf 'set GIT_CONFIG_VALUE_0=https://github.com/\r\n'
        fi

        printf 'cd /d "%s"\r\n' "$(win_path "$workdir")"
        printf '%s\r\n' "$cmdline"
        printf 'exit /b %%ERRORLEVEL%%\r\n'
    } > "$bat"
    set +e
    ( cd "$workdir" && cmd //c "$(win_path "$bat")" )
    local rc=$?
    set -e
    return "$rc"
}
