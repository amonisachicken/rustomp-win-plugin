# Windows 打包器：前期调研（rustomp 生态 / 参照实现 / 本机环境）

> 状态：调研完成，**待用户决策**若干选型项（见 §5）。
> 来源：`rustomp@7a186e4`、`rustomp-mac-plugin@5d3b391 (v0.1.6)`、`sparklin-drive@f7189fa`、
> `nih-plug@de42101`（`deps.lock` 钉的 rev）。

---

## 1. 生态与仓库边界（结论已定的部分）

四个仓分工明确，打包器是**可替换的平台插件**：

| 仓库 | 负责 | 不负责 |
|---|---|---|
| `rustomp`（框架） | 器件模型 / MNA / 实时路径 / `rustomp-gen` 代码生成 / `plugin_meta.py` 读清单 / 对拍 | 任何平台打包 |
| `rustomp-mac-plugin` | macOS：AUv2（clap-wrapper）+ VST3 + CLAP、签名、安装、`au_smoke` | DSP / 生成物 |
| **`rustomp-win-plugin`（本仓）** | Windows：VST3 / CLAP 打包 + 宿主侧验证 | 同上 |
| `sparklin-drive` | 参考插件（电路 + 生成物 + 面板 + `build.sh`） | 框架代码 |
| `rustomp-box-designer` / `rustomp-circuit-designer` | 面板 / 原理图设计器 | 打包 |

**三个跨仓契约**（`docs/ecosystem.md` §2）：

- **契约 A** `rustomp.toml`：打包器只读 `[plugin] [au] [build]`，且**必须**通过框架的
  `tools/meta/plugin_meta.py` 读（`--shell` 输出可 `eval` 的变量）。打包器**不复制**这份解析逻辑。
- **契约 B** 命令行与产物：`<packer> <plugin_dir> --variant mono|stereo|dual --format ... [--no-install]`，
  成功时 stdout **逐行** `ARTIFACT: <绝对路径>`，失败非 0 退出 + 人话原因。
  框架侧不认识平台的任何细节（clap-wrapper / codesign / CMake）。
- **契约 C** 设计器导出 `[assets]` + `[ui]`（毫米坐标、12 px/mm）。

版本约束：插件 `rustomp.toml` 的 `[requires] packer` 由打包器启动时校验一次。

> `docs/declarative-build.md` §4.2 还给了"后端契约"的一种更细的设想
> （`scripts/pack/<platform>/<format>.sh` + `PLUGIN_DIR/VARIANT/TARGET_TRIPLE/OUT_DIR/SIGN_MODE` 环境变量 +
> `capabilities.toml`）。**实际落地的是 mac 仓的 `pack.sh` + 子脚本形式**，本仓以实际实现为准，
> 只用 `capabilities.toml` 做能力声明。

---

## 2. 参照实现：rustomp-mac-plugin 的解剖

19 个文件，入口 `pack.sh`（119 行），职责链极清晰：

```
pack.sh                 体检 → 读清单 → 校验 requires.packer → 逐 variant 调 build-variant.sh → 打印 ARTIFACT
scripts/doctor.sh       查 cargo / Xcode CLT / cmake / python3 / cargo-nih-plug / rust target / 框架 / third_party / 素材
scripts/plugin-env.sh   source 后得到 PLUGIN_* / AU_* / ASSET_* / UI_*（经 plugin_meta.py --shell）
scripts/gen-bundler-toml.sh  从 rustomp.toml 生成 nih-plug 的 bundler.toml（bundle 名 = 插件名）
scripts/build-variant.sh     单变体：cargo nih-plug bundle-universal → 改名/plist → clap-wrapper→AUv2 → 签名 → 安装 → au_smoke
scripts/fetch-third-party.sh 拉 clap-wrapper / CLAP SDK / AudioUnitSDK（钉 commit）+ 打补丁
cmake/CMakeLists.txt   clap-wrapper 的 AUv2 包装（把 .clap 嵌进 .component）
patches/               AUv2 host classification 等 3 个上游补丁
tools/au-smoke         AU 进程内自检（C，绕过系统注册表）
tools/clap-probe       最小 CLAP 宿主（C，dlopen）
deps.lock              nih-plug rev de42101 / clap-wrapper commit / CLAP SDK 1.2.9 / AudioUnitSDK 1.1.0
```

几个**必须继承的设计经验**（都是踩过坑的）：

1. `MACOS_DEPLOYMENT_TARGET` 之类的 CMake 变量**留空会触发构建期联网下载**（CPM）→ Windows 侧等价物是
   "任何构建期下载"都要禁止并显式报错。
2. `build-variant.sh` 用 `--features mono|stereo` 构建；变体差异（显示名、CLAP id、VST3 class id）由
   `rustomp-gen` 的 `identity.rs` 用 `cfg(feature)` 决定，`plugin_meta.py --rust` 里的逻辑同源。
3. 并行度可配（`RUSTOMP_BUILD_JOBS`，默认 4），不按 `nproc` 打满。
4. 插件项目必须在**框架目录树之外**：`cargo-nih-plug` 会向上找最顶层 `Cargo.toml` 当 workspace 根。
   `target/bundled/` 与 `bundler.toml` 都落在**插件项目根**。
5. 安装 = 先 `rm -rf` 目标再 `cp -R`，避免残留旧文件。

---

## 3. Windows 与 macOS 的**实质**差异（决定实现形态）

### 3.1 AU 不存在

`docs/declarative-build.md` §4.4 平台矩阵已明确：

| 平台 | au | vst3 | clap | standalone |
|---|---|---|---|---|
| macOS | ✅ clap-wrapper | ✅ | ✅ | ⬜ |
| **Windows** | **❌ 无 AU** | ✅ | ✅ | ⬜ |

AU（Audio Unit）是 Apple 的宿主侧 API，Windows 上没有对应标准。
→ **本仓的范围应为 VST3（+ 可选 CLAP）**；`prompt.md` 里的 "VST/AU" 需按此解释并确认（§5 Q1）。

连带影响：clap-wrapper / CMake / AudioUnitSDK / patches / plist / codesign / au_smoke 全部**不需要**，
`build-variant.sh` 的 [3/5]–[5/5] 大半在 Windows 上无对应物 → Windows 打包器**比 mac 短得多**，
主要工作是"构建 + 命名 + 安装 + 验证"。

### 3.2 nih-plug 在 Windows 上的产物形状（`nih_plug_xtask@de42101`）

| 格式 | Windows 路径（相对 `target/bundled/`） |
|---|---|
| VST3 | `<bundle_name>.vst3/Contents/x86_64-win/<bundle_name>.vst3`（**目录包**，内层是 DLL） |
| CLAP | `<bundle_name>.clap`（**单文件** DLL，无目录包） |
| VST2 | `<bundle_name>.dll`（nih-plug 不导出 VST2 入口，实际不会生成） |
| standalone | `<bundle_name>.exe`（本期不做） |

`bundle_name` 来自 **`bundler.toml` 的 `name`**（不在 CLI 里传）。于是：

- mac 用"先构建再 rename 目录 + 改 plist"的方式拿变体名；
- **Windows 不需要 rename**：给 `bundler.toml` 写 `name = "Sparklin Drive Mono"` 即可直接产出
  `Sparklin Drive Mono.vst3/Contents/x86_64-win/Sparklin Drive Mono.vst3`。
  代价是每个变体要重写一次 `bundler.toml`（`gen-bundler-toml.sh` 已经是生成式的，顺便加 `--variant` 参数即可）。
- VST3 的 `class_id` 与 `name` 都来自 `identity.rs`（`cfg(feature)`），与 bundle 文件名无关。

`cargo nih-plug bundle-universal` 是 **macOS 专用**（源码里走 `x86_64-apple-darwin`/`aarch64-apple-darwin`
两条 lipo 分支），Windows 必须用 `cargo nih-plug bundle <package> --release [--target <triple>]`。

### 3.3 必须 MSVC 的原因（已确认，非偏好问题）

`nih_plug` 的 `vst3` feature 依赖 `vst3-sys`（git，`robbert-vdh/vst3-sys`），它会 **编译 Steinberg VST3 SDK 的 C++ 源码**；
egui 侧 `baseview`（git）也走 C/C++ + Windows 原生窗口。GNU ABI 的 MSYS2 rustc 无法编译这些 C++ 目标，
且与宿主（全部 MSVC 编译）的 CRT/异常模型不一致。→ **`x86_64-pc-windows-msvc` 是唯一可行目标**（用户已决策）。

---

## 4. 本机环境实况（影响第一步能否跑通）

| 项 | 现状 | 影响 |
|---|---|---|
| Rust（MSYS2 pacman） | `C:\msys64\clang64\bin\rustc.exe`，**1.98.0-nightly，host `x86_64-pc-windows-gnu`** | **不能用**于 MSVC 目标 |
| rustup | `~/.rustup` 里有 `stable/nightly`，**只有 `-gnu`**；`~/.cargo/bin` 里**没有 `rustup.exe`**（只剩 bat/edit/fd/tldr） | 需要重装/修复 rustup 并 `rustup target add x86_64-pc-windows-msvc` |
| MSVC / VS Build Tools | **完全未安装**（无 vswhere、无 `Program Files\Microsoft Visual Studio`） | 必须先装 |
| Windows SDK | **未安装**（无 `Windows Kits\10`） | 随 Build Tools 一起装 |
| winget | `C:\Users\Admin\AppData\Local\Microsoft\WindowsApps\winget.exe` 存在（不在 bash 的 PATH 里） | 可用于安装 Build Tools |
| OS | Windows 10 19044.5487 | Build Tools 2022 支持，但注意 Win10 上无 arm64 目标需求 |
| python3 | MSYS2 3.12.12（clang64/mingw64）+ Windows Python 3.13.2 | `plugin_meta.py` 需要 ≥3.11 的 `tomllib`，**满足** |
| cmake | `C:\msys64\mingw64\bin\cmake.exe` | Windows 侧本期基本用不到（无 CMake 步骤）；仅当引入 VST3 validator 时用 |
| bash / MSYS2 | 5.3.9，GNU 工具齐全 | 可直接照搬 mac 的 bash 脚本形态 |

> 结论：**第一件实事是装 MSVC 工具链**（Build Tools 2022 + VC Tools 工作负载 ≈ 3–6 GB，需 UAC 提权），
> 然后修复 rustup 并切到 `x86_64-pc-windows-msvc`。在此之前的任何"打包器"都只能是纸面设计。

---

## 5. 待决策项（**已全部决策，2026-10-28**）

| # | 问题 | 结论 |
|---|---|---|
| Q1 | 产物格式范围（AU 在 Windows 不存在） | ✅ **VST3 + CLAP** |
| Q2 | 打包器脚本形态 | ✅ **bash（MSYS2）**，与 mac 同构 |
| Q3 | 宿主侧验证手段 | ✅ **pluginval + 自写 clap-probe** |
| Q4 | 默认安装位置 | ✅ **用户级** `%LOCALAPPDATA%\Programs\Common\{VST3,CLAP}` |
| Q5 | MSVC 工具链安装 | ✅ winget 装 Build Tools 2022（含 VCTools 工作负载） |

落地结果与实测数据见 `docs/01-implementation.md` §5。

---

## 6. 我对实现形态的预判（供决策参考，非结论）

```text
rustomp-win-plugin/
  pack.sh                    契约 B 入口：体检 → 读清单 → 校验 requires → 逐 variant 构建 → 打印 ARTIFACT
  scripts/doctor.sh          cargo(msvc) / link.exe / cargo-nih-plug / python3 / 框架 / 素材 / 目标 triple
  scripts/plugin-env.sh      与 mac 同构（读 plugin_meta.py --shell）
  scripts/gen-bundler-toml.sh  加 --variant，直接产出带变体名的 bundler.toml
  scripts/build-variant.sh   cargo nih-plug bundle <pkg> --release --features <v> → 收集 target/bundled → 安装 → 验证
  scripts/verify.sh          宿主侧验证（pluginval 或自写 probe）
  scripts/msvc-env.sh        定位 vcvars64.bat / 设置 INCLUDE/LIB/PATH（或走 cmd /c call）
  capabilities.toml          platforms = ["windows"], formats = ["vst3", ...]
  docs/                      与本文同源的实现说明
```

预期**没有** CMake / clap-wrapper / patches / 签名（Authenticode 可后续单列）/ plist，
所以 Windows 打包器的代码量大概是 mac 的 1/3，难点集中在：MSVC 环境注入、VST3 目录包的命名与安装、
以及"用什么证明它在 Windows 宿主里真的能被扫出来并出声"。
