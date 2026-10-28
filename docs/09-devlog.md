# 开发日志

按时间倒序不重要，按**条目编号**走：每条记"做了什么 / 为什么 / 踩了什么"。
决策编号（W-00x）见 [`00-decisions.md`](00-decisions.md)。

---

## E1　立项与调研（2026-10-28）

读了三个仓：`rustomp@7a186e4`、`rustomp-mac-plugin@5d3b391 (v0.1.6)`、
`sparklin-drive@f7189fa`，外加 `nih-plug@de42101`（`deps.lock` 钉的 rev）。

结论写进 [`01-research.md`](01-research.md)。三条对实现有决定性影响的事实：

1. **Windows 没有 AU** —— 框架 `docs/declarative-build.md` §4.4 的平台矩阵里
   Windows 的 `au` 就是 ❌。所以格式集合是 VST3 + CLAP，clap-wrapper/CMake/plist/codesign
   那一整套在 Windows 上**不存在**。
2. **nih-plug 在 Windows 上的产物形状**：VST3 是
   `<name>.vst3/Contents/x86_64-win/<name>.vst3`（目录包，内层 DLL），CLAP 是
   `<name>.clap`（单文件 DLL）。名字**只**由 `bundler.toml` 的 `name` 决定。
3. **`bundle-universal` 是 macOS 专用**（源码里只走两条 `*-apple-darwin` 分支），
   Windows 只能 `bundle`。

---

## E2　环境搭建：把 MSVC 弄上手（2026-10-28）

本机原来只有 MSYS2 的 `-gnu` rustc，没有 MSVC、没有 Windows SDK，`rustup.exe` 还丢了
（`~/.rustup` 里有 toolchain，`~/.cargo/bin` 里只剩 `bat/edit/fd/tldr`）。

| 步骤 | 结果 |
|---|---|
| `rustup-init.exe -y --default-toolchain none` | 修复 rustup，重新装上 shim |
| `rustup toolchain install stable-x86_64-pc-windows-msvc` | rustc 1.99.1 |
| `winget install …BuildTools --override "… --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"` | 17.14，含 Win11 SDK 10.0.26100 |

**踩的坑**（详见 [`04-dependencies.md`](04-dependencies.md) §11）：

- VS 安装器下载 MS CDN 时反复 `WebException: 操作超时`，10 分钟零进度。
  根因是系统 WinINET 代理指到 LAN 上的代理服务器；把 `*.visualstudio.microsoft.com`
  加进代理例外后，速度从 ~55 KB/s 升到 1.6–2.4 MB/s，全程 1.7 GB 顺利装完。
  （改的是 `HKCU\…\Internet Settings\ProxyOverride`，装完已还原。）
- 装 arm64 组件时 `setup.exe modify --quiet` 返回 **5007**：
  "Commands with --quiet or --passive should be run elevated from the beginning"。
  用 `Start-Process -Verb RunAs` 提权后才成功。

---

## E3　首次端到端跑通（2026-10-28）

`./pack.sh ../sparklin-drive`：mono + stereo，VST3 + CLAP，装到用户级目录，全过。

| 项 | 实测 |
|---|---|
| 首次全量编译（nih-plug + egui + vst3-sys 的 C++） | **41.3 s** |
| clap-probe | mono → 进/出 `channels=1`；stereo → `channels=2`；id 带 `.mono/.stereo` |
| pluginval（strictness 5） | 两个变体全过（含 bus 布局、参数、状态、离线渲染） |
| 产物 | `Sparklin Drive Mono.vst3`（内层 `Contents/x86_64-win/`）+ `.clap` |

关键发现：**不需要事后改名**。`bundler.toml` 的 `name` 直接把 VST3 内外层与 `.clap`
文件名都定好，比 mac 那边"改名 + 改 plist"省一整步（W-003）。

---

## E4　契约 B 被抓到两次违约（2026-10-28）

第 1 次：`pack.sh … 2>/dev/null` 的 stdout 里混进了整个体检输出 ——
因为 `ok()` 直接 `printf` 到 stdout。修法：`log/warn/ok/die` 一律 stderr。

第 2 次（arm64 回归时才暴露）：编译 clap-probe 时 `cl.exe` 把源文件名
`clap_probe.c` 打到了 **stdout**。`cargo`/`rustc` 都写 stderr，所以第一轮没发现。
修法：`msvc_run` 里统一 `cmd //c <bat> 1>&2`。

现在的回归判据（写进流程）：`./pack.sh … 2>/dev/null` 的输出**只有** `ARTIFACT:` 行。

---

## E5　Windows 特有的三个坑（2026-10-28）

1. **原生 Python 的 stdout 是 CRLF**：`plugin_meta.py --shell` 经 `eval` 后每个变量
   尾部带 `\r`；`[ -f "$path" ]` 会判定"文件不存在"，而打印出来的路径看起来完全正常。
   → `lib.sh` 的 `py()` 统一 `tr -d '\r'`。
2. **Python 的 I/O 编码跟系统 codepage**：中文 Windows 默认 GBK，Python 把中文/`✓`
   编成 GBK 写进管道，bash 按 UTF-8 读 → 乱码。→ `PYTHONIOENCODING=utf-8`、`PYTHONUTF8=1`。
3. **MSYS 的 `HOME` 不是 `C:\Users\<me>`**（是 `/home/Admin`）：求用户目录必须
   `cygpath -u "$LOCALAPPDATA"`；`~/.cargo/bin` 要用 `$USERPROFILE` 拼。

外加一条环境事实：本机 `github.com:443` 直连不通（SSH 与代理可用），
所以 `msvc_run` 默认给 cargo 设 `CARGO_NET_GIT_FETCH_WITH_CLI=true`，
并支持 `RUSTOMP_GIT_SSH=1` 用 `GIT_CONFIG_*` 把 https 重写成 SSH（不改全局 git 配置）。

---

## E6　arm64（2026-10-28）

新增 `--arch x64|arm64|both`（W-006）。实测：

| 项 | x64 | arm64 |
|---|---|---|
| 首次编译 | 41.3 s | **42.0 s** |
| VST3 内层路径 | `Contents/x86_64-win/` | `Contents/arm_64-win/` |
| PE Machine | `0x8664` | `0xAA64` |
| 运行时验证 | clap-probe + pluginval | **只能静态校验**（W-007） |

三个实现要点：

1. `--target aarch64-pc-windows-msvc` 之后，nih-plug 的 `bundle_home` 仍是
   `<ws>/target/bundled`（不分 triple），产物按 `bundler.toml` 的 `name` 各成包，互不覆盖。
2. **必须用 `vcvarsamd64_arm64.bat`**。用 `vcvars64.bat` 时 cargo 依然"成功"，
   只是产物是 x64 —— 所以加了 `scripts/pe_machine.py` 读 PE Machine 字段兜底。
3. `--arch both` 默认只装 x64：两个架构 identity 相同，同机装两份会让宿主扫到重复插件。

---

## E7　去耦合与文档重排（2026-10-29）

目标：从"一个能打 sparklin-drive 的工具"变成"能打任何 rustomp 插件的工具"。

代码：

- **默认变体改为读清单** `[build] variants`（原来是硬编码 `mono stereo`）——
  一个只出 dual 的插件不该被逼着出 mono/stereo；命令行 `--variant` 仍然优先，
  与清单不符时只警告不阻断（允许对照构建）。
- **`WS_ROOT`**：复刻 nih-plug `chdir_workspace_root()` 的"最顶层 Cargo.toml"规则，
  `bundler.toml` 与 `target/bundled/` 都在那儿 —— 插件是更大 workspace 的成员时也能用。
- **`doctor.sh` 增加 shell 层体检**：bash 运行时识别（MSYS/Cygwin/Linux）、
  必需命令（`cygpath`/`git`/`sed`/`tr`/`find`/`mktemp`/`cp`）——干净机器最容易缺这一层。
- 脚本里**零插件名**（原来的示例文字改成 `../my-effect`）。

文档：README 按 `rustomp-circuit-designer` 的规范重排（编号章节 + 表格 + docs 索引），
把细节拆到 `docs/`：决策账本、调研、架构、验证、依赖、本日志；原始需求移入 `docs/prompt.md`。

回归：默认路径（读清单 → mono+stereo → x64）与既有产物均验证通过，
`2>/dev/null` 下 stdout 仍然只有 `ARTIFACT:` 行。
