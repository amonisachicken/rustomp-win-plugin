# 实现说明（rustomp-win-plugin）

> 与 `docs/00-research.md`（调研）配套：本文记录**实际实现**的形态与理由。
> 参照物是 `rustomp-mac-plugin@v0.1.6`，差异全部由平台事实决定，不是偏好。

---

## 1. 与 mac 版的逐项对照

| 环节 | macOS（参照实现） | Windows（本仓） | 为什么不同 |
|---|---|---|---|
| 编译 | `cargo nih-plug bundle-universal`（x86_64 + arm64 lipo） | `cargo nih-plug bundle`（单架构） | `bundle-universal` 在源码里只走两条 `*-apple-darwin` 分支 |
| 工具链 | Xcode CLT + clang | **MSVC**（vcvars64）+ Windows SDK | `vst3-sys` 要编 Steinberg 的 C++；宿主全是 MSVC ABI |
| 环境注入 | 天然就是 clang 环境 | 生成 `.bat`：`call vcvars64.bat` 再执行命令 | `vcvars` 把 `PATH` 改成 Windows 分号形式，注入 bash 会毁掉 bash 自己的 PATH |
| 产物 | `.component` / `.vst3` / `.clap`（都是目录包） | `.vst3`（目录包）+ `.clap`（**单文件 DLL**） | CLAP 只在 macOS 上用 bundle |
| 变体命名 | 先构建再**改名**目录 + 改 `Info.plist` | 变体名**直接写进 `bundler.toml`** | VST3 在 Windows 上内外层同名，改名比生成贵 |
| AU | clap-wrapper + AudioUnitSDK + 3 个补丁 | **不存在** | AU 是 Apple 的宿主 API |
| 签名 | `codesign -s -`（ad-hoc） | 不做（Authenticode 单列 v0.2） | 分发才需要证书 |
| 安装 | `~/Library/Audio/Plug-Ins/{Components,VST3,CLAP}` | `%LOCALAPPDATA%\Programs\Common\{VST3,CLAP}` | 用户级免 UAC；系统级要提权 |
| 自检 | `au_smoke`（进程内 AU 渲染 + RMS 对拍） | `clap-probe`（LoadLibrary 查端口/参数）+ `pluginval`（strictness 全套） | Windows 没有 auval 等价物 |
| 第三方源码 | clap-wrapper / CLAP SDK / AudioUnitSDK | 只有 CLAP SDK（给 probe 用） | 其余都不需要 |

---

## 2. 调用链

```text
pack.sh
  ├─ scripts/doctor.sh            体检（rustc host / MSVC / cargo-nih-plug / python / 框架 / 素材）
  ├─ scripts/plugin-env.sh        经框架 tools/meta/plugin_meta.py --shell 载入 PLUGIN_* / ASSET_* / UI_*
  └─ for variant in mono stereo:
       scripts/build-variant.sh <variant> --arch <x64|arm64|both>
         ├─ for arch in <arches>:
         │    scripts/gen-bundler-toml.sh --name "<Name>[ (ARM64)]"  → <plugin>/bundler.toml
         │    msvc_run(plugin_dir, arch, "cargo nih-plug bundle <pkg> --release --features <v> [--target aarch64-pc-windows-msvc]")
         │    校验 <name>.vst3/Contents/<x86_64-win|arm_64-win>/<name>.vst3 存在
         │    校验 PE Machine 字段 == 目标架构（scripts/pe_machine.py）
         │    安装（按 --arch / --install-both 决定哪些架构进用户目录）
         │    scripts/verify.sh --variant <v> --arch <a>
         └─ 写 build/artifacts-<v>.tsv（**不走 stdout**）
  └─ 逐行打印 ARTIFACT: <路径>      ← 契约 B：stdout 只有这一种行
```

### 2.1 架构维度（2026-10-28 追加）

| 事实 | 后果 |
|---|---|
| Windows **没有** universal binary（那是 macOS 的 lipo） | 两个架构是**两套独立产物**，arm64 名字带 ` (ARM64)` |
| VST3 目录包按架构分子目录（`x86_64-win` / `arm_64-win`），CLAP 是单文件 | 两套产物路径天然不冲突；不需要任何合并/改名 |
| arm64 交叉必须用 `vcvarsamd64_arm64.bat` | `find_vcvars <arch>` 按架构选脚本；`msvc_run` 多一个 arch 参数 |
| identity（VST3 class id / CLAP id）与架构无关 | `--arch both` **默认只装 x64**，否则同机出现"重复插件"；`--install-both` 才都装 |
| x64 进程加载不了 arm64 DLL，pluginval 只有 x64 | arm64 **只做静态校验**（PE + 目录结构），`RUSTOMP_REQUIRE_VERIFY=1` 时主动失败 |

---

## 3. Windows 上踩到的三个坑（都已写进代码注释）

1. **原生 Python 的 stdout 是 CRLF**
   `plugin_meta.py --shell` 的输出经 `eval` 后每个变量尾部带 `\r`；
   `[ -f "$path" ]` 会因此判定"文件不存在"，且报错信息看起来完全正常。
   → `lib.sh` 的 `py()` 统一 `tr -d '\r'`。

2. **MSYS 的 `HOME` 不是 `C:\Users\<me>`**
   `HOME=/home/Admin`。求用户目录必须 `cygpath -u "$LOCALAPPDATA"`。
   同理 `~/.cargo/bin` 要用 `$USERPROFILE` 拼，且必须**排在 pacman 的 `-gnu` rustc 之前**。

3. **`cmd //c "call vcvars && ..."` 会被 MSYS 撕碎**
   长参数里的 `&&`、引号、斜杠会被路径启发式转换破坏。
   → 一律**先落盘成 `.bat`** 再 `cmd //c <bat>`。

4. **`cl.exe` 往 stdout 打横幅**（追加于 arm64 那次回归）
   编译 clap-probe 时 MSVC 会把源文件名 `clap_probe.c` 打到 **stdout**，
   于是"stdout 只有 ARTIFACT 行"这条契约又被破坏了一次（`cargo`/`rustc` 都走 stderr，
   所以之前没暴露）。→ `msvc_run` 里统一 `cmd //c <bat> 1>&2`。

5. **Python 的 I/O 编码跟着系统 codepage 走**
   中文 Windows 默认 GBK，Python 把源码里的中文/`✓` 编成 GBK 写进管道，bash 按 UTF-8 解读 → 乱码。
   → `lib.sh` 里 `export PYTHONIOENCODING=utf-8 PYTHONUTF8=1`。

另外两个环境事实（不是代码问题，但决定了使用方式）：

- **本机 `github.com:443` 直连不通，SSH(22) 与代理可用。**
  `msvc_run` 默认给 cargo 设置 `CARGO_NET_GIT_FETCH_WITH_CLI=true`（libgit2 不认 git 的
  `url.insteadOf`/代理配置）；需要把 https 重写成 SSH 时设 `RUSTOMP_GIT_SSH=1`，
  用 `GIT_CONFIG_COUNT/KEY/VALUE` 注入，**不改用户的全局 git 配置**。
- **系统 WinINET 代理**（`server.local:8888`）会让 VS 安装器下载 MS CDN 超时；
  直连约 440 KB/s。装 Build Tools 时把 `*.visualstudio.microsoft.com` 加进代理例外。

---

## 4. 验证要证明什么

| 断言 | 手段 | 通过判据 |
|---|---|---|
| VST3 目录包结构正确 | `build-variant.sh` | `Contents/x86_64-win/<name>.vst3` 存在 |
| 插件能被加载 | `clap-probe` | `LoadLibrary` 成功、`clap_entry->init` 成功、插件数 ≥ 1 |
| 变体声道数正确 | `clap-probe` + 断言 | mono 出现 `channels=1`，stereo 出现 `channels=2` |
| 身份正确 | `clap-probe` / pluginval | `id` / `name` 与 `identity.rs` 一致（带 Mono/Stereo 后缀） |
| 能实例化、参数、状态、渲染 | `pluginval` strictness 5 | 退出码 0 |
| 安装落点正确 | `build-variant.sh` | `%LOCALAPPDATA%\Programs\Common\VST3\<name>.vst3` 存在 |

`RUSTOMP_REQUIRE_VERIFY=1` 时**缺工具即失败**：不允许"没验证"被当成"验证通过"
（mac 仓用 `RUSTOMP_REQUIRE_NGSPICE` 学到的教训）。

---

## 5. 实测结果（2026-10-28，本机首次跑通）

```text
$ ./pack.sh ../sparklin-drive
==> 环境体检 → 14 项全绿
########## variant: mono ##########
   Finished `release` profile [optimized] target(s) in 41.34s
   Created a CLAP bundle at '...\target\bundled\Sparklin Drive Mono.clap'
   Created a VST3 bundle at '...\target\bundled\Sparklin Drive Mono.vst3'
  ✓ VST3 / CLAP 结构校验
  ✓ 安装到 %LOCALAPPDATA%\Programs\Common\{VST3,CLAP}
  ✓ clap-probe：id=com.honeypieeffects.sparklin_drive.mono，进/出 channels=1 type=mono
  ✓ pluginval 通过（strictness 5，跳过 GUI）
########## variant: stereo ##########  → channels=2 / id=...stereo，同样全过
ARTIFACT: .../Sparklin Drive Mono.vst3
ARTIFACT: .../Sparklin Drive Mono.clap
ARTIFACT: .../Sparklin Drive Stereo.vst3
ARTIFACT: .../Sparklin Drive Stereo.clap
```

三个结论：

1. **不需要事后改名**：`bundler.toml` 的 `name` 直接决定 VST3 内外层名与 `.clap` 文件名，
   nih-plug 一步产出 `Sparklin Drive Mono.vst3/Contents/x86_64-win/Sparklin Drive Mono.vst3`。
2. **变体确实生效**：clap-probe 与 pluginval 都独立确认了 mono=1ch / stereo=2ch，
   且 CLAP id 带 `.mono` / `.stereo` 后缀（新身份，宿主的扫描缓存天然不冲突）。
3. **契约 B 干净**：`2>/dev/null` 后 stdout 恰好四行 `ARTIFACT:`，没有半句人话混进去
   （这一条最初是错的：`ok()` 直接打 stdout，已被 `_contract.sh` 抓出来并修掉）。

首次环境搭建的耗时（一次性）：VS Build Tools 约 1.7 GB 下载 —— 走系统代理时反复超时，
把 `*.visualstudio.microsoft.com` 加进 WinINET 代理例外后升到 1.6–2.4 MB/s。

---

## 6. arm64 实测（2026-10-28 追加）

```text
$ ./pack.sh ../sparklin-drive --variant mono --arch arm64 --no-install
  Finished `release` profile [optimized] target(s) in 42.01s
  Created a CLAP bundle at '...\bundled\Sparklin Drive Mono (ARM64).clap'
  Created a VST3 bundle at '...\bundled\Sparklin Drive Mono (ARM64).vst3'
  ✓ Sparklin Drive Mono (ARM64).vst3 ← PE arm64
  ✓ Sparklin Drive Mono (ARM64).clap ← PE arm64

$ ./pack.sh ../sparklin-drive --variant mono --arch both
  [x64]   ✓ 安装 + clap-probe 通过 + pluginval 通过（strictness 5）
  [arm64] ✓ PE arm64（静态校验），跳过安装（不在安装列表：x64）
ARTIFACT: .../Sparklin Drive Mono.vst3
ARTIFACT: .../Sparklin Drive Mono.clap
ARTIFACT: .../Sparklin Drive Mono (ARM64).vst3
ARTIFACT: .../Sparklin Drive Mono (ARM64).clap
```

要点：

1. **`--target aarch64-pc-windows-msvc` 就够了**：nih-plug 的 `bundle_home` 是
   `target/bundled`（不分 triple），两份产物按 `bundler.toml` 的 `name` 各自成包，互不覆盖。
2. **PE 校验是这条链上关键的兜底**：交叉编译配错 vcvars 时 cargo 依然"成功"，
   只是产物是 x64。`scripts/pe_machine.py` 读 PE 头 Machine 字段（x64=`0x8664`、
   arm64=`0xAA64`），在构建期和验证期各查一次。
3. **arm64 的运行时验证是空缺的，且被显式标注**：本机 x64 无法 `LoadLibrary` arm64 DLL；
   `verify.sh` 对 arm64 明确打印"仅静态校验通过"，`RUSTOMP_REQUIRE_VERIFY=1` 时直接失败。
4. 新增的环境要求：`rustup target add aarch64-pc-windows-msvc` +
   MSVC 组件 `Microsoft.VisualStudio.Component.VC.Tools.ARM64`（装它必须**一开始就提权**，
   否则安装器退出码 `5007`）。
