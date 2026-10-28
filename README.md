# rustomp-win-plugin

**rustomp 插件的 Windows 打包工具** —— 把一个「已经生成好代码的 rustomp 插件项目」
打成 **VST3 / CLAP**（x64 与 arm64），装进用户级插件目录，并做宿主侧自检。

它**不针对任何具体插件**：所有插件相关的值都来自插件项目自己的 `rustomp.toml`（契约 A），
所以任何用 rustomp 做出来的效果器都能直接用它打包。

```text
插件项目（Rust + rustomp.toml）              rustomp-win-plugin                    宿主
────────────────────────────                ─────────────────────                ──────
cargo nih-plug bundle（MSVC）        ──►    取产物 / 校验 PE 架构与目录形状
  target/bundled/*.vst3 | *.clap     ──►    复制到 %LOCALAPPDATA%\Programs\Common
                                            clap-probe（LoadLibrary，查端口/参数）
                                            pluginval（strictness 校验 + 离线渲染）
                                                   │
                                           打印 ARTIFACT: <路径>  ──►  VST3 / CLAP
```

macOS 的同位实现是 [rustomp-mac-plugin](https://github.com/amonisachicken/rustomp-mac-plugin)，
框架是 [rustomp](https://github.com/amonisachicken/rustomp)；
仓库边界与三个跨仓契约见 rustomp 的 `docs/ecosystem.md`。

> **Windows 上没有 AU。** Audio Unit 是 Apple 的宿主 API，所以本仓产出 **VST3 + CLAP**；
> 请求 `--format au` 会明确报错，而不是静默跳过。

---

## 1. 产品介绍

打包的本质是**三件与平台强相关的事**，本仓替插件项目把这三件事做掉：

| 交付物 | 用来做什么 |
|---|---|
| **VST3 目录包** | `<Name>.vst3/Contents/<arch>-win/<Name>.vst3`，装进 `%LOCALAPPDATA%\Programs\Common\VST3` |
| **CLAP 单文件** | `<Name>.clap`（Windows 上就是 DLL），装进 `%LOCALAPPDATA%\Programs\Common\CLAP` |
| **`ARTIFACT:` 行** | 契约 B 的唯一输出：框架/CI 只认这一行，不需要知道 Windows 的任何细节 |

它解决的是**"改完 DSP 到能在 DAW 里听到"之间那段脏活**：MSVC 环境注入、变体/架构的
bundle 命名、PE 架构核对、装到对的位置、用两个独立工具证明"宿主真的能加载它"。

**面向谁**：已经用 rustomp 生成好插件项目（有 `rustomp.toml` 与 `plugin/src/generated/`）
的开发者。**不做**代码生成、不改 DSP、不碰插件源码 —— 那是 rustomp 的事。

### 当前状态（2026-10-29）

| 项 | 状态 |
|---|---|
| VST3 / CLAP（x64） | ✅ 可用；已在本机 DAW 实测出声 |
| arm64（`--arch arm64/both`） | ✅ 产物可用（PE `0xAA64` 已核）；**运行时待 ARM 机器验证** |
| 变体 | ✅ mono / stereo / dual；**默认值取自插件的 `[build] variants`** |
| 自检 | ✅ clap-probe（端口/身份/声道数）+ pluginval（strictness 5）+ PE 架构核对 |
| 目录安装 | ✅ 用户级目录（免 UAC），可 `--no-install` |
| **MSI 安装包**（`--format msi`） | ✅ **系统级 / 用户级两个包**，安装→卸载生命周期实测通过（见 W-010） |
| 已知边界 | 无代码签名；arm64 只能静态校验；AU 与 standalone 不做；没有"一个向导里选范围"的 EXE 引导器 |

---

## 2. 架构

```text
pack.sh（契约 B 入口）
  │  1 体检  scripts/doctor.sh            —— shell/MSVC/rustc host/python/框架/素材 逐项给"怎么装"
  │  2 读清单 scripts/plugin-env.sh        —— 经框架 plugin_meta.py 读 rustomp.toml（契约 A）
  │  3 定变体                              —— 默认取 [build] variants，命令行的 --variant 优先
  └  4 逐变体 × 逐架构  scripts/build-variant.sh
        ├ gen-bundler-toml.sh   → <workspace>/bundler.toml（bundle 名 = 插件名[ 变体][ (ARM64)]）
        ├ msvc_run(arch)        → cargo nih-plug bundle <pkg> --release [--features v] [--target arm64]
        ├ 校验产物               → 目录形状 + PE Machine 字段（scripts/pe_machine.py）
        ├ 安装                   → %LOCALAPPDATA%\Programs\Common\{VST3,CLAP}
        └ verify.sh             → clap-probe + pluginval（x64）/ 静态校验（arm64）
```

| 层 | 选型 | 理由 |
|---|---|---|
| 脚本语言 | **bash**（MSYS 运行时） | 与 mac 仓同构，两个平台的脚本可以逐段对照；MSYS 提供 `cygpath` 等 Windows 路径互转 |
| 编译 | **MSVC**（`vcvars64` / `vcvarsamd64_arm64`） | `vst3-sys` 要编 Steinberg 的 C++；商用宿主全是 MSVC ABI（ADR W-002） |
| 打包 | `cargo-nih-plug bundle`（钉 rev） | 与 mac 侧同一个 bundler，产物形状一致 |
| MSI | **WiX 3.14 免安装 zip**（candle/light） | 不引入 .NET SDK；两个包按范围固定（W-010） |
| 验证 | clap-probe（自写 C）+ pluginval | Windows 没有 `auval` 等价物；一个查端口/身份，一个查实例化/状态/渲染 |
| 命名 | bundle 名写进 `bundler.toml` | Windows 的 VST3 内外层必须同名，事后改名比生成更贵（W-003） |

### 目录

```text
pack.sh                  入口（契约 B）：体检 → 读清单 → 定变体 → 构建/安装/验证 → 打印 ARTIFACT
scripts/
  lib.sh                 公共库：日志（全走 stderr）/ Python 发现 / 按架构找 vcvars / 在 MSVC 环境里跑命令
  doctor.sh              环境体检（shell、MSVC、rustc host、cargo-nih-plug、python、框架、素材、验证器、WiX）
  build-variant.sh       单变体 × 单架构：bundler.toml → 构建 → PE 校验 → 安装 → 验证
  verify.sh              宿主侧验证：x64 = clap-probe + pluginval；arm64 = 静态校验
  build-msi.sh           打 MSI：收集产物 → 生成 spec → candle/light → 两个范围各一个包
  gen-wix.py             由产物清单生成 WiX 源（两套目录树、确定性 GUID、WixUI_Minimal）
  plugin-version.py      从插件的 Cargo.toml 取版本号（MSI 的 ProductVersion）
  pe_machine.py          读 PE Machine 字段（x64=0x8664 / arm64=0xAA64）
  gen-bundler-toml.sh    生成 <workspace>/bundler.toml（bundle 名带变体/架构后缀）
  plugin-env.sh          经框架读 rustomp.toml → shell 变量 + workspace 根探测
  fetch-third-party.sh   拉 CLAP SDK / pluginval / WiX（固定版本，见 deps.lock）
tools/clap-probe/        最小 CLAP 宿主（C）：LoadLibrary 一个 .clap，dump 端口/参数/身份
capabilities.toml        能力声明（platforms / formats / variants / arches / 验证矩阵）
deps.lock                外部依赖的固定版本（nih-plug rev、CLAP SDK tag、pluginval、WiX、rust target）
docs/                    决策账本 / 调研 / 架构 / 验证 / 依赖 / 开发日志 / 原始需求
```

---

## 3. 功能范围

### 能做

| 类别 | 内容 |
|---|---|
| **格式** | VST3（目录包）、CLAP（单文件 DLL）、MSI 安装包 |
| **架构** | x64（默认）、arm64、`both`（两套产物；默认只装 x64） |
| **变体** | mono / stereo / dual；默认按插件 `[build] variants`，也可 `--variant` 覆盖 |
| **安装** | 用户级 `%LOCALAPPDATA%\Programs\Common\{VST3,CLAP}`；`--no-install` 只产出 |
| **MSI** | 按范围出两个包：`(system)` → `C:\Program Files\Common Files\{VST3,CLAP}`（需管理员）、`(per-user)` → `%LOCALAPPDATA%\Programs\Common\{VST3,CLAP}`（免 UAC）；含升级/卸载 |
| **验证** | clap-probe（身份/端口/声道数，含 mono=1ch、stereo=2ch 断言）、pluginval（strictness 可调）、PE 架构核对 |
| **通用性** | 只依赖 `rustomp.toml`（契约 A）；支持插件是更大 workspace 的成员（bundle 落 workspace 根） |
| **可诊断** | `doctor.sh` 逐项说"缺什么、怎么装"；失败信息带原始命令 |

### 暂不（有明确边界，不是遗忘）

| 项 | 状态 |
|---|---|
| 代码签名 / Authenticode | 未做（对外分发才需要证书；MSI 也没签） |
| **一个向导里选安装范围** | 未做：Windows Installer 没有可靠的单包双范围路径（W-010）；目前是**两个 MSI**，要单入口得再包一层 EXE 引导器（NSIS/Burn） |
| CI 工作流 | 未做（脚本已按 `RUSTOMP_REQUIRE_VERIFY=1` 的 CI 姿态设计） |
| VST2 | 不做（Steinberg 已停止授权，nih-plug 也不导出 VST2 入口） |

### 明确不做

| 不做 | 原因 |
|---|---|
| **AU** | Audio Unit 是 Apple 的宿主 API，Windows 上不存在（rustomp `declarative-build.md` §4.4 矩阵里就是 ❌） |
| **standalone** | 需要音频设备选择/设置持久化，是独立的一件事（原始需求里明确排除） |
| **DSP / 代码生成 / 改插件源码** | 那是 rustomp 框架与 rustomp-gen 的职责；本仓只消费已生成的产物 |
| **AAX** | 需要 Avid 授权，且与 GPL-3 冲突 |

---

## 4. 部署与运行

### 依赖（一台干净 Windows 机器从零开始）

| 依赖 | 用途 | 检查 | 装法 |
|---|---|---|---|
| **Windows 10/11 x64** | 平台 | — | — |
| **Git for Windows** 或 **MSYS2** | 提供 bash + `cygpath`/`sed`/`tr`/`find` 等（本仓全部脚本是 bash） | `bash --version`、`cygpath -w /` | [Git for Windows](https://git-scm.com/download/win)（自带 Git Bash）或 [MSYS2](https://www.msys2.org/)；**本机实测的是 MSYS2** |
| **Rust（rustup）+ MSVC 工具链** | 编译插件 | `rustc -vV` → host 必须是 `x86_64-pc-windows-msvc` | `winget install Rustlang.Rustup` 然后 `rustup default stable-x86_64-pc-windows-msvc` |
| **VS Build Tools 2022**（C++ 工作负载，含 Windows SDK） | MSVC 的 `cl.exe`/`link.exe`、`vcvars64.bat`、CRT 与 Win32 库 | `vswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64` | `winget install Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"`（约 1.7 GB） |
| **Python ≥ 3.11** | 读 `rustomp.toml`（框架的 `plugin_meta.py` 用 `tomllib`） | `python -V` | `winget install Python.Python.3.12`（或 MSYS2 `pacman -S mingw-w64-clang-x86_64-python`） |
| **cargo-nih-plug**（rev 钉死） | `cargo nih-plug bundle` | `cargo --list \| grep nih-plug` | `cargo install --git https://github.com/robbert-vdh/nih-plug.git --rev de42101 cargo-nih-plug --locked` |
| **rustomp 框架仓** | 读清单 / 校验生成物 | 同级 `../rustomp/tools/meta/plugin_meta.py` | `git clone https://github.com/amonisachicken/rustomp.git` |
| **CLAP SDK**（只给 clap-probe 用） | 编译验证工具 | `third_party/clap/include/clap/clap.h` | `./scripts/fetch-third-party.sh` |
| **pluginval**（可选但建议） | VST3 宿主侧验证 | `third_party/pluginval/pluginval.exe` | `./scripts/fetch-third-party.sh --pluginval` |
| **WiX 3.14**（只在打 MSI 时要） | `candle`/`light` 编安装包 | `third_party/wix/candle.exe` | `./scripts/fetch-third-party.sh --wix`（免安装 zip，约 40 MB；运行时需 .NET Framework 3.5） |

只在要出 arm64 时再要两样：

| 依赖 | 用途 | 装法 |
|---|---|---|
| rust target `aarch64-pc-windows-msvc` | 交叉编译 | `rustup target add aarch64-pc-windows-msvc` |
| MSVC ARM64 交叉工具集（`vcvarsamd64_arm64.bat`） | 编 arm64 的 C++/链接 | 见 [docs/04-dependencies.md](docs/04-dependencies.md) §3（**必须提权**，静默模式不会自己弹 UAC） |

> 一条命令看缺什么：`./scripts/doctor.sh`（每一项都附"怎么装"；`--format msi` 时会额外查 WiX）。
> 完整清单、体积、离线注意事项见 [docs/04-dependencies.md](docs/04-dependencies.md)。

### 启动（打包一个插件）

```bash
# 目录约定：框架与打包工具都是**插件项目的同级**
#   some-dir/{rustomp, rustomp-win-plugin, my-effect}

./scripts/doctor.sh                                   # 一次性体检
./pack.sh ../my-effect                                # 变体/格式/架构全取默认，装到用户目录
./pack.sh ../my-effect --variant stereo --format vst3 --no-install
./pack.sh ../my-effect --arch both                    # 再出 arm64 一套
./pack.sh ../my-effect --format msi --no-install      # 出两个安装包（系统级 / 用户级）
```

成功时 stdout **只有** `ARTIFACT:` 行（契约 B）：

```text
ARTIFACT: C:/…/my-effect/target/bundled/My Effect Stereo.vst3
ARTIFACT: C:/…/my-effect/target/bundled/My Effect Stereo.clap
ARTIFACT: C:/…/rustomp-win-plugin/build/msi/My Effect Setup (system).msi
ARTIFACT: C:/…/rustomp-win-plugin/build/msi/My Effect Setup (per-user).msi
```

### 关于两个 MSI

| 包 | 装到哪 | 需要管理员 |
|---|---|---|
| `<Name> Setup (system).msi` | `C:\Program Files\Common Files\{VST3,CLAP}` | 是（UAC 一次） |
| `<Name> Setup (per-user).msi` | `%LOCALAPPDATA%\Programs\Common\{VST3,CLAP}` | 否 |

两个包的 `UpgradeCode` 不同 = **两个产品身份**，所以同一台机器可以同时装两种范围，
也可以各自独立升级/卸载。

> ⚠ 但这不意味着"两种都装"是个好主意：两份文件的**插件身份（VST3 class id / CLAP id）完全相同**
> （身份来自插件的 `identity.rs`，与安装位置无关）。同一台机器装两套，宿主会扫到重复插件。
> 一台机器只装一种范围。为什么不做成"一个向导里选"：Windows Installer 没有可靠的单包
双范围路径（实测会出"两处都写"的混合安装），完整证据见
[docs/00-decisions.md](docs/00-decisions.md) W-010 与 [docs/09-devlog.md](docs/09-devlog.md) E8。

静默安装（适合脚本/CI）：

```bash
msiexec /i "My Effect Setup (per-user).msi" /qn          # 用户级，无需提权
msiexec /i "My Effect Setup (system).msi"   /qn          # 系统级，需管理员
msiexec /x "My Effect Setup (per-user).msi" /qn          # 卸载（用哪个包装的就用哪个包卸）
```

### 环境变量

| 变量 | 默认 | 作用 |
|---|---|---|
| `RUSTOMP_ROOT` | `<plugin_dir>/../rustomp` | 框架目录（读 `rustomp.toml` 用） |
| `PLUGIN_DIR` | 第一个位置参数 | 插件项目目录 |
| `RUSTOMP_GUEST` | — | 由插件的 `build.sh` 调用时指定插件目录 |
| `RUSTOMP_BUILD_JOBS` | cargo 自己决定 | `cargo -j` 并行度 |
| `RUSTOMP_REQUIRE_VERIFY` | `0` | `1` = 缺验证工具即失败（CI 姿态） |
| `RUSTOMP_GIT_SSH` | `0` | `1` = 把 `https://github.com` 重写成 SSH 拉 git 依赖 |
| `PLUGINVAL` / `PLUGINVAL_STRICTNESS` | 自动找 / `5` | pluginval 可执行文件与严格度 |
| `PYTHON` | 自动探测 | 指定 Python（≥3.11） |

### 测试（本仓库自己的验证）

```bash
./scripts/doctor.sh                              # 环境体检
./scripts/verify.sh --variant mono               # 对已构建产物跑 clap-probe + pluginval
./scripts/verify.sh --variant stereo --with-gui  # 连 GUI 一起测
./scripts/verify.sh --variant mono --arch arm64  # arm64：只做静态校验（PE + 目录结构）
RUSTOMP_REQUIRE_VERIFY=1 ./pack.sh ../my-effect  # CI 姿态：缺工具即失败
```

判据与三项工具的分工见 [docs/03-verify.md](docs/03-verify.md)。

---

## 5. 与 rustomp 对接

本仓是**契约 B 的一个实现**（`rustomp/docs/ecosystem.md` §2）：

| 契约 | 本仓怎么用 |
|---|---|
| **A：`rustomp.toml`** | 只读，且**必须**经框架的 `tools/meta/plugin_meta.py`（不自己解析 TOML）。用到的键：`[plugin] package/name`、`[build] variants/dual_variant`、`[assets]`（体检用）、`[requires] packer` |
| **B：命令行与产物** | `pack.sh <plugin_dir> [--variant …] [--format …] [--arch …]`；成功时 **stdout 逐行** `ARTIFACT: <绝对路径>`，失败非 0 退出 + 人话原因 |
| **C：`[assets]`/`[ui]`** | 不消费内容，只在体检时确认素材文件存在（缺失会让插件编译期 `include_bytes!` 直接失败） |

**版本约束**：插件 `rustomp.toml` 的 `[requires] packer` 会在启动时校验一次，
不满足就明确报错，绝不产出"能编但行为不同"的插件。

**五个从平台事实来的约定**：

1. 插件项目必须在**框架目录树之外**（`cargo-nih-plug` 会向上找最顶层 `Cargo.toml` 当 workspace 根）；
2. bundle 名、变体后缀、架构后缀全部由本仓写进 `bundler.toml`，插件源码一行不改；
3. 默认变体取插件的 `[build] variants`，命令行可覆盖；
4. 两个架构的 identity（VST3 class id / CLAP id）相同 → `--arch both` 默认只装 x64；
5. `ARTIFACT:` 之外的一切日志都在 stderr（框架/CI 靠 stdout 判成功）。

---

## 6. 文档

细节全在 [`docs/`](docs/README.md)（含索引与"何时读哪篇"）：

- **决策账本** [`docs/00-decisions.md`](docs/00-decisions.md) —— 先读这个，每条形如 W-00x；
- **依赖与安装** [`docs/04-dependencies.md`](docs/04-dependencies.md) —— 干净机器从零装什么、为什么；
- **验证判据** [`docs/03-verify.md`](docs/03-verify.md) —— 用什么证明"宿主真能加载"；
- **架构** [`docs/02-architecture.md`](docs/02-architecture.md) —— 与 mac 仓的逐项对照、调用链、Windows 特有的坑；
- **生态调研** [`docs/01-research.md`](docs/01-research.md) —— 四个仓谁负责什么、三个契约；
- **开发日志** [`docs/09-devlog.md`](docs/09-devlog.md) —— 做了什么、为什么、踩了什么坑（含实测数字）；
- **原始需求** [`docs/prompt.md`](docs/prompt.md) —— 立项书（含路线图与开发约定）。

---

## 7. 许可证

GPL-3.0-or-later（[`LICENSE`](LICENSE)）。第三方：CLAP SDK（MIT）、pluginval（GPL-3）、
nih-plug（GPL-3），版本钉在 [`deps.lock`](deps.lock)。
