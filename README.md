# rustomp-win-plugin

**rustomp 插件的 Windows 打包工具** —— 把「已经生成好代码的插件项目」打成
**VST3 / CLAP**（x86_64），装到用户级插件目录，并做宿主侧自检。

```text
插件项目（Rust + rustomp.toml）        rustomp-win-plugin                     宿主
──────────────────────────           ─────────────────────                 ──────
cargo nih-plug bundle（MSVC）  ──►    取产物 / 校验 VST3 目录包结构
  target/bundled/*.vst3|*.clap  ──►    复制到 %LOCALAPPDATA%\Programs\Common
                                      clap-probe（LoadLibrary，查端口/参数）
                                      pluginval（strictness 校验 + 离线渲染）
                                             │
                                     打印 ARTIFACT: <路径>  ──►  VST3 / CLAP
```

**这个仓库只管打包。** DSP、代码生成、面板都在 [rustomp](https://github.com/amonisachicken/rustomp)；
macOS 的同位实现是 [rustomp-mac-plugin](https://github.com/amonisachicken/rustomp-mac-plugin)。
仓库边界与三个跨仓契约见 rustomp 的 `docs/ecosystem.md`。

> **Windows 上没有 AU。** Audio Unit 是 Apple 的宿主 API（`docs/declarative-build.md` §4.4
> 的平台矩阵里 Windows 的 `au` 就是 ❌），所以本仓产出 **VST3 + CLAP**，
> 请求 `--format au` 会明确报错而不是静默跳过。Clap-wrapper / CMake / AudioUnitSDK /
> plist / codesign 那一整套在 Windows 上**不存在**，也因此没有对应实现。

---

## 快速开始

```bash
# 0) 让三个仓同级（框架与打包工具都是插件项目的同级）
mkdir -p ~/deve && cd ~/deve
git clone git@github.com:amonisachicken/rustomp.git
git clone git@github.com:amonisachicken/sparklin-drive.git
cd rustomp-win-plugin

# 一次性依赖
winget install Microsoft.VisualStudio.2022.BuildTools \
  --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
rustup toolchain install stable-x86_64-pc-windows-msvc
rustup default stable-x86_64-pc-windows-msvc
cargo install --git https://github.com/robbert-vdh/nih-plug.git --rev de42101 cargo-nih-plug --locked
./scripts/fetch-third-party.sh --pluginval     # CLAP SDK + pluginval（可选但建议）
./scripts/doctor.sh                            # 体检：MSVC / rustc host / cargo-nih-plug / python / 框架 / 素材

# 2) 打包一个插件项目（插件住在**本仓之外**）
./pack.sh ../sparklin-drive                              # mono + stereo，VST3 + CLAP，并安装
./pack.sh ../sparklin-drive --variant stereo --format vst3 --no-install
./pack.sh ../sparklin-drive --arch both                  # 再出 arm64 一套（x64 仍然照装）
```

要用 `--arch arm64|both` 的话，额外装两样（一次性）：

```bash
rustup target add aarch64-pc-windows-msvc
# ARM64 交叉工具集：**必须在管理员 PowerShell 里跑**（--quiet 不会自己弹 UAC，否则退出码 5007）
& "C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe" modify `
    --installPath "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools" `
    --add Microsoft.VisualStudio.Component.VC.Tools.ARM64 --quiet --norestart
```

成功时 stdout **只有** `ARTIFACT:` 行（契约 B）：

```text
ARTIFACT: C:/Users/me/deve/sparklin-drive/target/bundled/Sparklin Drive Mono.vst3
ARTIFACT: C:/Users/me/deve/sparklin-drive/target/bundled/Sparklin Drive Mono.clap
```

框架侧据此判断"打包成功与否"，**不需要知道 Windows 的任何细节**。

### 本机已跑通（2026-10-28，Windows 10 19044）

| 项 | 实测 |
|---|---|
| 工具链 | rustup `stable-x86_64-pc-windows-msvc` 1.99.1 + VS Build Tools 2022 17.14（VCTools 工作负载，含 Win11 SDK 10.0.26100） |
| 首次全量编译 | **41 s**（nih-plug + egui + vst3-sys 的 C++ 部分）；arm64 首次 **42 s** |
| 产物（x64） | `Sparklin Drive Mono/Stereo .vst3`（目录包，内层 `Contents/x86_64-win/<name>.vst3`）+ `.clap`（单文件 DLL） |
| 产物（arm64） | `Sparklin Drive Mono (ARM64).vst3`（内层 `Contents/arm_64-win/`）+ `.clap`，PE Machine = **0xAA64** |
| clap-probe | mono → `channels=1` 进/出；stereo → `channels=2` 进/出；`id` 带 `.mono/.stereo` 后缀 ✓ |
| pluginval | mono / stereo 各 **strictness 5 全部通过**（含 bus 布局、参数、状态、离线渲染） |
| 安装落点 | `%LOCALAPPDATA%\Programs\Common\{VST3,CLAP}\Sparklin Drive {Mono,Stereo}.*` ✓ |
| 契约 B | `pack.sh ... 2>/dev/null` 的 stdout **恰好只有** `ARTIFACT:` 行 ✓ |

> arm64 的**运行时**验证在本机做不了（x64 进程 `LoadLibrary` 一个 arm64 DLL 只会得到
> `ERROR_BAD_EXE_FORMAT`，pluginval 也只有 x64 版）。本仓对 arm64 只做静态校验
> （PE Machine 字段 + 目录结构），并且**明说**这一点 —— 见下面「架构」一节。

---

## 参数

```text
pack.sh <plugin_dir> [--variant mono|stereo|dual]... [--format vst3|clap]...
        [--arch x64|arm64|both] [--install-both] [--no-install] [--no-verify]

默认：variant = mono + stereo，format = vst3 + clap，arch = x64，
      安装到 %LOCALAPPDATA%\Programs\Common\
```

| 参数 | 作用 |
|---|---|
| `--arch x64` | **默认**：产出 `<Name>.vst3` / `<Name>.clap` |
| `--arch arm64` | 产出 `<Name> (ARM64).vst3` / `<Name> (ARM64).clap`（PE = arm64） |
| `--arch both` | 两套都产出；**默认只把 x64 装到用户目录**（见下「架构」），要都装加 `--install-both` |

| 环境变量 | 作用 |
|---|---|
| `RUSTOMP_ROOT` | 显式指定框架目录（**默认**：`<plugin_dir>/../rustomp`） |
| `PLUGIN_DIR` | 等价于第一个位置参数 |
| `RUSTOMP_GUEST` | 若 `pack.sh` 由插件的 `build.sh` 调用，用它指定插件目录 |
| `RUSTOMP_BUILD_JOBS` | `cargo -j` 的并行度（默认交给 cargo） |
| `RUSTOMP_REQUIRE_VERIFY` | `1` = 缺验证工具即失败（CI 用，避免"没验证"当成"通过"） |
| `PLUGINVAL` | 显式指定 pluginval 可执行文件 |
| `PLUGINVAL_STRICTNESS` | pluginval 严格度（默认 5，1–10） |
| `PYTHON` | 显式指定 Python（需 ≥3.11 的 `tomllib`） |

目录约定（三个仓同级）：

```text
some-dir/
  rustomp/              ← 框架
  rustomp-win-plugin/   ← 本工具
  sparklin-drive/       ← 插件项目
```

**插件项目必须住在框架目录树之外**：`cargo-nih-plug` 会向上找**最顶层**的 `Cargo.toml`
当 workspace 根，插件嵌在 `rustomp/plugins/` 里会被拉到框架根 → `packages outside of workspace`。

---

## 目录

```text
pack.sh                  入口（契约 B）：体检 → 读清单 → 逐 variant 构建 → 打印 ARTIFACT
scripts/
  lib.sh                 公共库：日志 / Python 发现 / vcvars(按架构) 发现 / **在 MSVC 环境里跑命令** / 安装目录
  doctor.sh              环境体检（缺什么给"怎么装"；--arch arm64|both 时额外查 arm64 工具链）
  build-variant.sh       单个变体 × 架构：bundler.toml → cargo nih-plug bundle → 校验产物(含 PE) → 安装 → 验证
  verify.sh              宿主侧验证：x64 用 clap-probe + pluginval；arm64 只做静态校验
  pe_machine.py          读 PE Machine 字段，确认 DLL 真是目标架构（防止"目录写 arm64、内容却是 x64"）
  gen-bundler-toml.sh    从插件 rustomp.toml 生成 bundler.toml（bundle 名带变体/架构后缀）
  plugin-env.sh          读 rustomp.toml（经由框架的 plugin_meta.py）→ shell 变量
  fetch-third-party.sh   拉 CLAP SDK / pluginval（固定版本，见 deps.lock）
tools/clap-probe/        最小 CLAP 宿主（C）：LoadLibrary 一个 .clap，dump 端口/参数/身份
capabilities.toml        能力声明（formats / variants / arches / 验证矩阵）
deps.lock                外部依赖的固定版本（nih-plug rev、CLAP SDK tag、pluginval、rust target）
docs/00-research.md      前期调研：生态边界、mac 实现解剖、Windows 差异、环境实况
docs/01-implementation.md 实现说明：与 mac 的逐项对照、调用链、踩过的坑、实测结果
```

---

## 架构：x64 / arm64（没有"通用二进制"）

macOS 的 universal binary 是把两份机器码 lipo 进同一个文件；**Windows 没有这个机制**，
VST3 目录包按架构分 `Contents/<arch>-win/` 子目录，宿主只加载自己那份。所以：

| 方案 | 说明 |
|---|---|
| 默认 `--arch x64` | 与加 arm64 之前完全一致，不改变现有行为 |
| `--arch arm64` | 单独一套产物，名字带 ` (ARM64)`，PE Machine = `0xAA64` |
| `--arch both` | 两套都产出；**默认只安装 x64** |

**为什么 `both` 默认只装 x64**：两个架构的 identity（VST3 class id、CLAP id）完全相同 ——
身份来自 `rustomp.toml` → `identity.rs`，与架构无关。同一台机器的插件目录里同时存在两份
相同 id 的模块时，宿主会扫到"重复插件"（多数宿主去重或告警）。所以真正需要并存的场合
（同一台机器上同时装了 x64 宿主与原生 arm64 宿主）才用 `--install-both`。

**arm64 的验证到什么程度**：本机是 x64，`LoadLibrary` 一个 arm64 DLL 只会得到
`ERROR_BAD_EXE_FORMAT`，pluginval 也只有 x64 版。所以 arm64 **只做静态校验**：
PE Machine 字段 + 目录结构（`Contents/arm_64-win/<name>.vst3`）。运行时要等一台 ARM 机器。
`RUSTOMP_REQUIRE_VERIFY=1` 时 arm64 会**主动失败**，避免把"静态校验"当成"验证通过"。

---

## 为什么每一步这样做

| 决定 | 原因 |
|---|---|
| **必须 MSVC**，不能用 MSYS2 的 `-gnu` rustc | `nih_plug` 的 `vst3` feature 依赖 `vst3-sys`，要编 Steinberg 的 **C++**；且所有商用宿主都是 MSVC 编译，GNU ABI 的 CRT/异常模型对不上 |
| MSVC 环境**不注入 bash**，而是生成 `.bat` 再 `cmd /c` | `vcvars64.bat` 会把 `PATH` 改成 Windows 分号形式，bash 立刻找不到自己的工具；`cmd /c "call ... && ..."` 的长参数又被 MSYS 的路径启发式破坏 |
| 变体名写进 `bundler.toml`，**不事后改名** | nih-plug 的 bundle 名只由 `bundler.toml` 的 `name` 决定；Windows 的 VST3 是 `<name>.vst3/Contents/x86_64-win/<name>.vst3`，内外层必须同名，改名比生成更麻烦 |
| VST3 校验**内层 DLL 存在** | 只检查外层目录会漏掉"目录建了但 DLL 没进去"这种半成品 |
| 装到 `%LOCALAPPDATA%\Programs\Common` | 用户级目录免 UAC（脚本化不会卡在提权对话框），主流宿主都会扫；系统级需要管理员 |
| arm64 用 `vcvarsamd64_arm64.bat`，**不是** `vcvars64.bat` | 后者的 cl/link 只会产出 x64；配错了 cargo 仍会"成功"，直到 ARM 机器上加载才炸 —— 所以额外用 PE Machine 字段兜底 |
| 缺验证工具默认**警告**，`RUSTOMP_REQUIRE_VERIFY=1` 才**失败** | 本地开发别被"没装 pluginval"卡住；CI 里"没验证"绝不能被当成"验证通过"（mac 仓 `RUSTOMP_REQUIRE_NGSPICE` 的教训） |

---

## 验证是怎么做的

Windows 上没有 `auval` / AU 进程内自检这种等价物，所以分成两层：

1. **`tools/clap-probe`（自写，C）** —— `LoadLibrary` 那个 `.clap`，打印插件 id/name/features、
   音频端口数与声道数、`audio-ports-config`、参数数。它回答的是"这个变体到底声明了几进几出"，
   这个问题在宿主菜单里看不出来、pluginval 也不细分。**变体断言**：mono 必须出现 `channels=1`，
   stereo 必须出现 `channels=2`。
2. **`pluginval`（可选）** —— Tracktion 的跨平台插件验证器，`--strictness-level` 走实例化、
   参数、状态保存恢复、离线渲染等一整套检查；`--skip-gui-tests` 可跳过 GUI（默认跳过，
   `--with-gui` 打开）。

```bash
./scripts/verify.sh --variant mono                 # 用默认工具集
./scripts/verify.sh --variant stereo --with-gui     # 连 GUI 一起测
./scripts/verify.sh --variant mono --arch arm64     # arm64：只做静态校验（PE + 目录结构）
RUSTOMP_REQUIRE_VERIFY=1 ./pack.sh ../sparklin-drive   # CI 姿态：缺工具即失败
```

---

## 已知限制

| 项 | 状态 |
|---|---|
| AU | **不存在**（Apple 专有）；本仓只出 VST3 / CLAP |
| standalone | **没做**（prompt 明确排除） |
| 签名 | 没做。对外分发需要 Authenticode + 证书，单列一项（mac 那边是 ad-hoc 起步） |
| 安装包（MSI/EXE） | 没做，列在 v0.2 |
| ARM64 | **产物已支持**（`--arch arm64|both`）；但 **运行时要在一台 ARM 机器上验证** —— 本机是 x64，只能做静态校验（PE + 目录结构） |
| VST2 | 不做（Steinberg 已停止授权，nih-plug 也不导出 VST2 入口） |
| AAX | 不做（需要 Avid 授权，且与 GPL-3 冲突） |

---

## 许可证

GPL-3.0-or-later。第三方源码的许可证见各自目录（CLAP SDK: MIT，pluginval: GPL-3）。
