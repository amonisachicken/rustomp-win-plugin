# 架构与实现

> 参照物是 [rustomp-mac-plugin](https://github.com/amonisachicken/rustomp-mac-plugin)（v0.1.6）。
> 下面的差异**全部由平台事实决定**，不是风格偏好；对应的决策编号见 [`00-decisions.md`](00-decisions.md)。

---

## 1. 与 mac 仓的逐项对照

| 环节 | macOS（参照实现） | Windows（本仓） | 为什么不同 |
|---|---|---|---|
| 编译 | `cargo nih-plug bundle-universal`（x86_64 + arm64 lipo） | `cargo nih-plug bundle`（每架构一次） | `bundle-universal` 在 nih-plug 源码里只走两条 `*-apple-darwin` 分支 |
| 工具链 | Xcode CLT + clang | **MSVC**（`vcvars64` / `vcvarsamd64_arm64`）+ Windows SDK | `vst3-sys` 要编 Steinberg 的 C++；商用宿主全是 MSVC ABI |
| 环境注入 | 天然就是 clang 环境 | 生成 `.bat`：`call vcvars*.bat` 再执行命令 | `vcvars` 把 `PATH` 改成 Windows 分号形式，注入 bash 会毁掉 bash 自己的 PATH（W-002） |
| 产物 | `.component` / `.vst3` / `.clap`（都是目录包） | `.vst3`（目录包）+ `.clap`（**单文件 DLL**） | CLAP 只在 macOS 上用 bundle |
| 变体命名 | 先构建再**改名**目录 + 改 `Info.plist` | 变体名**直接写进 `bundler.toml`** | VST3 在 Windows 上内外层必须同名，改名比生成贵（W-003） |
| 架构策略 | 一条命令出 universal | `--arch x64\|arm64\|both`，每架构独立产物 | Windows 没有 universal binary（W-006） |
| AU | clap-wrapper + AudioUnitSDK + 3 个补丁 | **不存在** | AU 是 Apple 的宿主 API |
| 签名 | `codesign -s -`（ad-hoc） | 不做（Authenticode 单列） | 只有分发才需要证书 |
| 安装 | `~/Library/Audio/Plug-Ins/{Components,VST3,CLAP}` | `%LOCALAPPDATA%\Programs\Common\{VST3,CLAP}` | 用户级免 UAC（W-004） |
| 自检 | `au_smoke`（进程内 AU 渲染 + RMS 对拍） | `clap-probe` + `pluginval` + PE 校验 | Windows 没有 `auval` 等价物（W-005/W-007） |
| 第三方源码 | clap-wrapper / CLAP SDK / AudioUnitSDK | 只有 CLAP SDK（给 probe 用） | 其余都不需要 |

---

## 2. 调用链

```text
pack.sh
  ├─ scripts/doctor.sh          体检：shell 运行时 / MSVC / rustc host / cargo-nih-plug / python / 框架 / 素材
  ├─ scripts/plugin-env.sh      经框架 plugin_meta.py --shell 载入 PLUGIN_* / ASSET_* / UI_*，并求出 WS_ROOT
  ├─ 定变体                      默认取 [build] variants（命令行 --variant 优先）
  └─ for variant in <变体>:
       scripts/build-variant.sh <variant> --arch <x64|arm64|both>
         └─ for arch in <架构>:
              gen-bundler-toml.sh --name "<Name>[ 变体][ (ARM64)]"   → <WS_ROOT>/bundler.toml
              msvc_run(<plugin_dir>, <arch>, "cargo nih-plug bundle <pkg> --release
                                             [--features <v>] [--target aarch64-pc-windows-msvc]")
              校验 <Name>.vst3/Contents/<arch>-win/<Name>.vst3 存在
              校验 PE Machine == 目标架构（scripts/pe_machine.py）
              安装到 %LOCALAPPDATA%\Programs\Common\{VST3,CLAP}（按 --arch / --install-both 决定）
              verify.sh --variant <v> --arch <a>
              写 build/artifacts-<v>.tsv（**不走 stdout**）
  └─ 逐行打印 ARTIFACT: <路径>    ← 契约 B：stdout 只有这一种行
```

---

## 3. 三个关键机制

### 3.1 workspace 根 ≠ 插件目录（通用性的前提）

`cargo-nih-plug` 的 `chdir_workspace_root()` 会从插件目录**向上找最顶层**带 `Cargo.toml`
的目录当 workspace 根，`bundler.toml` 与 `target/bundled/` 都在那儿。

所以本仓不硬编码"插件目录 == 目标目录"，而是复刻同一条规则（`plugin-env.sh` 里的 `WS_ROOT`）：
往上一直走到根，记住**最后一个**带 `Cargo.toml` 的目录。

后果：插件是某个更大 workspace 的成员时也能正常工作；反之若把插件塞进本仓目录树，
`WS_ROOT` 会跑到本仓根，导致 `packages outside of workspace` 之类的错误 ——
所以"插件必须住在本仓之外"这条约束是**结构性**的，不是洁癖。

### 3.2 MSVC 环境不注入 bash，而是生成 `.bat`

`vcvars64.bat` 会把 `PATH` 改成 Windows 分号形式；一旦 `source`/`export` 进 bash，
bash 立刻找不到自己的 `/usr/bin` 工具。另一条路 `cmd //c "call vcvars && cargo ..."`
也不可用：MSYS 会对长参数里的 `&&`、引号、斜杠做路径启发式转换，实测会把命令撕碎。

最终形态（`lib.sh` 的 `msvc_run`）：

```text
写 <ROOT>/build/.msvc-<arch>.bat：
    @echo off
    call "<vcvars>.bat" >nul 2>&1
    if errorlevel 1 exit /b 9
    set <透传代理变量 / CARGO_NET_GIT_FETCH_WITH_CLI / GIT_CONFIG_*>   ← 见 3.3
    cd /d "<plugin_dir>"
    <cargo 命令>
    exit /b %ERRORLEVEL%
然后 cmd //c <bat>    ← 且 **1>&2**：编译器的 stdout 并到 stderr（W-008）
```

按架构选脚本：x64 → `vcvars64.bat`；arm64 → `vcvarsamd64_arm64.bat`。
**用错不会报错**：`vcvars64.bat` 下 cargo 依然"成功"，只是产物是 x64 —— 这就是
`pe_machine.py` 存在的原因。

### 3.3 网络：libgit2 不认 git 的配置

cargo 默认用 libgit2 拉 git 依赖，它**不认** `url.insteadOf` 与代理配置。
`msvc_run` 因此默认设 `CARGO_NET_GIT_FETCH_WITH_CLI=true`（改走 git CLI），
并按需透传代理变量；`RUSTOMP_GIT_SSH=1` 时用 `GIT_CONFIG_COUNT/KEY/VALUE`
把 `https://github.com` 重写成 SSH，**不改用户的全局 git 配置**。

### 3.4 架构维度

| 事实 | 后果 |
|---|---|
| Windows **没有** universal binary（那是 macOS 的 lipo） | 两个架构是**两套独立产物**，arm64 名字带 ` (ARM64)` |
| VST3 目录包按架构分子目录（`x86_64-win` / `arm_64-win`），CLAP 是单文件 | 两套产物路径天然不冲突，不需要合并/改名 |
| nih-plug 的 `bundle_home` 是 `<ws>/target/bundled`（不分 triple） | 交叉编译时产物落点不变，只是内容不同 |
| identity（VST3 class id / CLAP id）与架构无关 | `--arch both` 默认只装 x64（W-006） |

---

## 4. 通用性：本仓不认识任何具体插件

| 插件相关信息 | 从哪来 |
|---|---|
| 显示名 / 包名 / 变体清单 | `rustomp.toml` → `plugin_meta.py --shell`（契约 A） |
| bundle / 产物文件名 | 由本仓按 `名称 + 变体后缀 + 架构后缀` 拼，写进 `bundler.toml` |
| 声道布局 / 插件身份 | 插件自己的 `plugin/src/generated/*.rs`（本仓只做断言，不改） |
| 素材 | 只在体检时确认存在（缺失会让 `include_bytes!` 编译失败） |

仓库里唯一的"具体插件"痕迹是**文档中的示例**（用 sparklin-drive 当参考插件），
代码与配置里没有任何插件名。
