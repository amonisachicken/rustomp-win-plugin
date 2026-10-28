# 验证判据（凭什么说"打出来的东西能用"）

Windows 上没有 `auval`，也没有 mac 仓那种 AU 进程内自检（`au_smoke`）。
所以"能用"被拆成**三条独立的证据**，分别由三个工具给出，任何一条都不会被另一条掩盖。

---

## 1. 判据矩阵

| 断言 | 手段 | 通过判据 | 失败时说明什么 |
|---|---|---|---|
| VST3 目录包结构正确 | `build-variant.sh` | `Contents/<arch>-win/<Name>.vst3` 存在 | bundler.toml 的 name 与产物不符，或 bundler 没写进包 |
| DLL 真是目标架构 | `pe_machine.py` | PE Machine == `x64`/`arm64` | vcvars 用错（arm64 用了 `vcvars64.bat`）—— **cargo 不会报错** |
| 插件能被加载 | `clap-probe` | `LoadLibrary` + `clap_entry->init` 成功、插件数 ≥ 1 | 导出符号缺失 / ABI 不匹配 / 依赖 DLL 找不到 |
| 变体声道数正确 | `clap-probe` + 断言 | mono 出现 `channels=1`，stereo 出现 `channels=2` | feature 没生效，或 `identity.rs`/`AUDIO_LAYOUTS` 与变体不一致 |
| 身份正确 | `clap-probe` / pluginval | `id`、`name` 与 `identity.rs` 一致（带 ` Mono` / ` Stereo` 后缀） | 生成物过期（忘了 `rustomp-gen`） |
| 能实例化 / 参数 / 状态 / 离线渲染 | `pluginval` strictness 5 | 退出码 0 | 真实宿主里也会出问题的那一类 |
| 安装落点正确 | `build-variant.sh` | `%LOCALAPPDATA%\Programs\Common\VST3\<Name>.vst3` 存在 | 路径算错（`LOCALAPPDATA` 取错是常见原因） |
| 契约 B 干净 | 外部（CI / 框架） | `2>/dev/null` 后 stdout 只有 `ARTIFACT:` 行 | 有日志漏到 stdout（W-008） |

---

## 2. 三个工具的分工

### 2.1 `tools/clap-probe`（自写，C，约 120 行）

`LoadLibrary` 那个 `.clap`（Windows 上就是 DLL），打印：
插件数、id/name/vendor/version/features、输入输出端口数与**每个端口的声道数**、
`audio-ports-config`、参数数。

它回答的问题是**宿主菜单里看不出来、pluginval 也不细分**的：这个变体到底声明了几进几出。
所以 `verify.sh` 会顺带做变体断言（mono → `channels=1`，stereo → `channels=2`）。

依赖：CLAP SDK 头文件（`./scripts/fetch-third-party.sh`）+ MSVC 的 `cl`。

### 2.2 `pluginval`（Tracktion，可选但建议）

`--strictness-level 5`：实例化、参数枚举、状态保存/恢复、bus 布局、离线渲染、
内存与线程检查等一整套。`--skip-gui-tests` 默认打开（headless 友好），`--with-gui` 关掉。

退出码：0 全过、1 有错。日志写到 `build/pluginval-logs/`。

### 2.3 `pe_machine.py`（自写，Python，约 50 行）

读 PE 头的 Machine 字段：`x64=0x8664`、`arm64=0xAA64`、`x86=0x014C`。
**这是唯一能证明"这个 DLL 到底是哪个架构"的硬证据** —— 目录名和文件名都可能骗人。

---

## 3. arm64 的诚实边界

arm64 产物在本机（x64）**做不了运行时验证**：

- x64 进程 `LoadLibrary` 一个 arm64 DLL → `ERROR_BAD_EXE_FORMAT`；
- pluginval 只有 x64 版，同样加载不了。

所以 `verify.sh --arch arm64` 只做**静态校验**（PE 架构 + 目录结构），并且：

| 场景 | 行为 |
|---|---|
| 默认 | 明确打印"仅静态校验通过；运行时兼容性必须在一台 ARM 机器上验证"，**退出码 0** |
| `RUSTOMP_REQUIRE_VERIFY=1` | **直接失败** —— 不允许把"静态校验"当成"运行时验证通过" |

这条策略是照着 mac 仓 `RUSTOMP_REQUIRE_NGSPICE` 的教训写的：
**"没验证"绝不能默认变成"验证通过"**。

---

## 4. 缺工具时的策略

| 情况 | 默认 | `RUSTOMP_REQUIRE_VERIFY=1` |
|---|---|---|
| 没有 pluginval | 警告 + 跳过（SKIPPED） | 失败 |
| 没有 CLAP SDK（编译不了 probe） | 警告 + 跳过 | 失败 |
| 没有 CLAP 产物（插件没导出） | 警告 + 跳过该步 | 不失败（这是插件属性，不是环境问题） |
| arm64 产物 | 静态校验 + 警告 | 失败 |

---

## 5. 怎么加一条新断言

1. 在 `verify.sh` 里拿到 `OUT="$("$PROBE" "$CLAP")"` 之后加 `grep`/比较；
2. 失败就设 `FAILED=1`（不要 `exit`，让其余检查也跑完）；
3. 断言要尽量**具体到值**（例如 `channels=1`），不要只判"有输出"；
4. 新断言写进本文 §1 的矩阵，注明"失败时说明什么"。
