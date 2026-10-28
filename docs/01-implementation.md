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
       scripts/build-variant.sh <variant>
         ├─ scripts/gen-bundler-toml.sh --variant <v>     → <plugin>/bundler.toml（name 带变体后缀）
         ├─ msvc_run(plugin_dir, "cargo nih-plug bundle <pkg> --release --features <v>")
         ├─ 校验 <name>.vst3/Contents/x86_64-win/<name>.vst3 存在
         ├─ 安装到 %LOCALAPPDATA%\Programs\Common\{VST3,CLAP}
         ├─ scripts/verify.sh --variant <v>
         └─ 写 build/artifacts-<v>.tsv（**不走 stdout**）
  └─ 逐行打印 ARTIFACT: <路径>      ← 契约 B：stdout 只有这一种行
```

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
