# 决策账本

每条都是一个**会影响实现形态**的决定，按 `W-00x` 编号。改实现前先读这里；
要推翻某条，就新增一条说明"为什么现在不一样了"，不要静默改。

| 编号 | 决定 | 一句话理由 |
|---|---|---|
| W-001 | 打包器用 **bash + MSYS**，不用 PowerShell/Python 单文件 | 与 mac 仓同构，两个平台的脚本能逐段对照 |
| W-002 | 工具链**必须 MSVC**（`-gnu` 一律不行） | `vst3-sys` 要编 Steinberg 的 C++；宿主全是 MSVC ABI |
| W-003 | bundle/产物名**写进 `bundler.toml`**，不做事后改名 | Windows 的 VST3 内外层必须同名 |
| W-004 | 默认安装到**用户级** `%LOCALAPPDATA%\Programs\Common` | 免 UAC，脚本化不会卡在提权对话框 |
| W-005 | 验证用 **clap-probe + pluginval** 双轨 | Windows 没有 `auval`；一个查端口/身份，一个查实例化/渲染 |
| W-006 | 架构上**每架构独立产物**；`both` 默认只装 x64 | Windows 没有 universal binary；两架构 identity 相同 |
| W-007 | arm64 **只做静态校验**，`REQUIRE_VERIFY=1` 时主动失败 | x64 进程加载不了 arm64 DLL；不许把"没验证"当"通过" |
| W-008 | **stdout 只允许 `ARTIFACT:` 行**，其余全走 stderr | 契约 B；框架/CI 靠它判成功 |
| W-009 | 不针对任何插件：默认变体取 `[build] variants`，`WS_ROOT` 复刻 nih-plug 规则 | 换一个插件项目不该改脚本 |
| W-010 | MSI 用 **WiX 3.14 免安装 zip**，且**按范围出两个包**（系统 / 用户） | 单包双范围会被 MSI 重新定价，实测出现"两处都写" |

---

## W-001 脚本形态：bash + MSYS

**背景**：mac 仓是 `pack.sh` + `scripts/*.sh` 的 bash 体系。Windows 上可选 bash(MSYS2)、
PowerShell 7、或一个单文件 Python。

**决定**：bash + MSYS 运行时。

**后果**：两个仓的脚本可以逐段对照（改一个能立刻看另一个怎么写的）；
代价是**用户必须先有 MSYS 运行时**（Git for Windows 或 MSYS2），且脚本里的
`cygpath`/`cp -R` 语义是 MSYS 专有的（Cygwin/WSL 未验证，`doctor.sh` 会拒绝）。

---

## W-002 必须 MSVC

**背景**：MSYS2 也带 rustc，但 host 是 `x86_64-pc-windows-gnu`。

**决定**：只用 `stable-x86_64-pc-windows-msvc`；arm64 用 `aarch64-pc-windows-msvc`。

**后果**：每个用户都要装 VS Build Tools（约 4.5 GB）。
`doctor.sh` 对 `rustc -vV` 的 host 做**硬校验**，MSYS2 的 `-gnu` rustc 会被点名。

---

## W-003 名字写进 `bundler.toml`，不事后改名

**背景**：mac 版的流程是"先按原名构建 → `mv` 目录 → 改 `Info.plist` → 改内层可执行名"。

**决定**：Windows 直接让 nih-plug 生成正确名字：`bundler.toml` 的 `name` 决定
`<name>.vst3/Contents/<arch>-win/<name>.vst3` 与 `<name>.clap`。

**后果**：每个变体/架构构建前重写一次 `bundler.toml`（生成式，不手改）；
换来的是"产物一步到位"，没有改名失败导致的半成品。

---

## W-004 用户级安装

**背景**：VST3 的系统级目录是 `%ProgramFiles%\Common Files\VST3`，写入需要管理员。

**决定**：默认装 `%LOCALAPPDATA%\Programs\Common\{VST3,CLAP}`；`--no-install` 只产出。

**后果**：脚本永远不会卡在 UAC；代价是"全机可用"需要用户自己拷到系统目录
（或未来加 `--system-install`，目前不做）。

---

## W-005 验证双轨

**背景**：mac 有 `auval` + 自带 `au_smoke`（进程内渲染 + RMS 对拍）。
Windows 既没有 `auval`，也没有跨格式的等价物。

**决定**：
- `tools/clap-probe`（自写 C，约 120 行）：`LoadLibrary` 加载 `.clap`，dump
  身份/端口/声道数/参数数 —— 补上"宿主菜单里看不出来"的那一层；
- `pluginval`（Tracktion，可选）：strictness 级校验，覆盖实例化/参数/状态/离线渲染。

**后果**：`verify.sh` 有两个独立的失败来源；缺工具默认只警告，
`RUSTOMP_REQUIRE_VERIFY=1` 才算失败。

---

## W-006 每架构独立产物；`both` 默认只装 x64

**背景**：macOS 用 universal binary（lipo）一次出两份机器码；Windows 没有这个机制，
VST3 目录包按 `Contents/<arch>-win/` 分子目录，CLAP 是单个 DLL 文件。

**决定**：
- 架构是独立维度：`--arch x64|arm64|both`，arm64 的名字带 ` (ARM64)`；
- `both` 时**默认只把 x64 装进用户目录**，`--install-both` 才都装。

**后果**：两个架构的 identity（VST3 class id / CLAP id）完全相同 —— 它们来自
`rustomp.toml` → `identity.rs`，与架构无关。同机装两份会让宿主扫到"重复插件"。

---

## W-007 arm64 只做静态校验

**背景**：本机是 x64。`LoadLibrary` 一个 arm64 DLL 只会得到 `ERROR_BAD_EXE_FORMAT`；
pluginval 也只有 x64 版。

**决定**：arm64 验证 = PE Machine 字段 + 目录结构；**明确打印"仅静态校验"**，
`RUSTOMP_REQUIRE_VERIFY=1` 时**直接失败**。

**后果**：arm64 的运行时兼容性必须在 ARM 机器上人工验证一次。
这条是照着 mac 仓 `RUSTOMP_REQUIRE_NGSPICE` 的教训写的：
**"没验证"绝不能默认变成"验证通过"**。

---

## W-008 stdout 只允许 `ARTIFACT:`

**背景**：契约 B 规定框架只认 stdout 里的 `ARTIFACT:` 行。

**决定**：`log/warn/ok/die` 全部写 stderr；`msvc_run` 把编译器的 stdout 也并到 stderr
（`cmd //c <bat> 1>&2`）。

**后果**：这条被违反过两次（`ok()` 直接打 stdout；`cl.exe` 打印源文件名），
两次都是**实际抓到的**，见 [`09-devlog.md`](09-devlog.md) E4。回归方式：
`./pack.sh … 2>/dev/null` 的输出必须只有 `ARTIFACT:` 行。

---

## W-009 不针对任何插件

**背景**：本仓最初是照着一个具体插件（sparklin-drive）滚出来的，容易把它的特征写死。

**决定**：
- 插件相关信息**只**来自 `rustomp.toml`（契约 A）；
- **默认变体**取 `[build] variants`，不再硬编码 `mono stereo`；
- `WS_ROOT` 复刻 nih-plug 的 "最顶层 `Cargo.toml`" 规则（支持插件是更大 workspace 的成员）；
- 代码/配置里不出现任何插件名（文档里的示例除外）。

**后果**：换一个插件项目 = 换一个目录参数，脚本一行不改。

---

## W-010 MSI：WiX 3.14 免安装 zip + 按范围出两个包

**背景**：需求是"安装时可选装入系统目录或用户目录"。看起来最自然的实现是
**一个 MSI** + 安装向导里一个单选（`ALLUSERS` / `MSIINSTALLPERUSER` 切换）。

**试过，不行**（完整实验见 [`09-devlog.md`](09-devlog.md) E8）：
- Windows Installer 对"同一个包既能装系统又能装用户"没有官方路径。改 `ALLUSERS`/
  `MSIINSTALLPERUSER` 的时机稍晚一点，MSI 就按自己的判定重新定价；
- 实测出现过**系统目录与用户目录同时被写入**的混合安装（安装还悄悄提了权），
  卸载时又因为包身份不一致而失败。

**决定**：
1. 工具链用 **WiX 3.14 的免安装二进制 zip**（`third_party/wix/`）：`candle`/`light` 是独立 exe，
   只依赖 .NET Framework 3.5；换成 WiX v4/v5 要装 .NET SDK（约 500 MB），对"干净机器"负担太大。
2. **按范围出两个 MSI**，各自固定、不依赖运行时判定：
   - `<Name> Setup (system).msi` → `CommonFiles64Folder\VST3|CLAP`，需管理员；
   - `<Name> Setup (per-user).msi` → `LocalAppData\Programs\Common\VST3|CLAP`，免 UAC。
   "选择"发生在**选哪个包**；两个包的 `UpgradeCode` 不同（不同产品身份），
   所以同一台机器可以同时存在两种范围而不互相覆盖。

**后果**：真正的"一个向导里选范围"需要再包一层 EXE 引导器（NSIS / Burn，见 W-011 待定）；
两个 MSI 的安装/卸载生命周期都实测通过（`docs/03-verify.md` §6）。
