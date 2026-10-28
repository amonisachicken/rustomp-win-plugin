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
```

成功时 stdout **只有** `ARTIFACT:` 行（契约 B）：

```text
ARTIFACT: C:/Users/me/deve/sparklin-drive/target/bundled/Sparklin Drive Mono.vst3
ARTIFACT: C:/Users/me/deve/sparklin-drive/target/bundled/Sparklin Drive Mono.clap
```

框架侧据此判断"打包成功与否"，**不需要知道 Windows 的任何细节**。

---

## 参数

```text
pack.sh <plugin_dir> [--variant mono|stereo|dual]... [--format vst3|clap]... [--no-install] [--no-verify]

默认：variant = mono + stereo，format = vst3 + clap，安装到 %LOCALAPPDATA%\Programs\Common\
```

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
  lib.sh                 公共库：日志 / Python 发现 / vcvars 发现 / **在 MSVC 环境里跑命令** / 安装目录
  doctor.sh              环境体检（缺什么给"怎么装"）
  build-variant.sh       单个变体：bundler.toml → cargo nih-plug bundle → 校验产物 → 安装 → 验证
  verify.sh              宿主侧验证：clap-probe + pluginval
  gen-bundler-toml.sh    从插件 rustomp.toml 生成 bundler.toml（bundle 名带变体后缀）
  plugin-env.sh          读 rustomp.toml（经由框架的 plugin_meta.py）→ shell 变量
  fetch-third-party.sh   拉 CLAP SDK / pluginval（固定版本，见 deps.lock）
tools/clap-probe/        最小 CLAP 宿主（C）：LoadLibrary 一个 .clap，dump 端口/参数/身份
capabilities.toml        能力声明（formats / variants / 安装位置）
deps.lock                外部依赖的固定版本（nih-plug rev、CLAP SDK tag、pluginval）
docs/00-research.md      前期调研：生态边界、mac 实现解剖、Windows 差异、环境实况
```

---

## 为什么每一步这样做

| 决定 | 原因 |
|---|---|
| **必须 MSVC**，不能用 MSYS2 的 `-gnu` rustc | `nih_plug` 的 `vst3` feature 依赖 `vst3-sys`，要编 Steinberg 的 **C++**；且所有商用宿主都是 MSVC 编译，GNU ABI 的 CRT/异常模型对不上 |
| MSVC 环境**不注入 bash**，而是生成 `.bat` 再 `cmd /c` | `vcvars64.bat` 会把 `PATH` 改成 Windows 分号形式，bash 立刻找不到自己的工具；`cmd /c "call ... && ..."` 的长参数又被 MSYS 的路径启发式破坏 |
| 变体名写进 `bundler.toml`，**不事后改名** | nih-plug 的 bundle 名只由 `bundler.toml` 的 `name` 决定；Windows 的 VST3 是 `<name>.vst3/Contents/x86_64-win/<name>.vst3`，内外层必须同名，改名比生成更麻烦 |
| VST3 校验**内层 DLL 存在** | 只检查外层目录会漏掉"目录建了但 DLL 没进去"这种半成品 |
| 装到 `%LOCALAPPDATA%\Programs\Common` | 用户级目录免 UAC（脚本化不会卡在提权对话框），主流宿主都会扫；系统级需要管理员 |
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
| ARM64 | 没做。`x86_64-pc-windows-msvc` 覆盖绝大多数宿主；加 arm64 只是多一个 triple + 目录 `arm_64-win` |
| VST2 | 不做（Steinberg 已停止授权，nih-plug 也不导出 VST2 入口） |
| AAX | 不做（需要 Avid 授权，且与 GPL-3 冲突） |

---

## 许可证

GPL-3.0-or-later。第三方源码的许可证见各自目录（CLAP SDK: MIT，pluginval: GPL-3）。
