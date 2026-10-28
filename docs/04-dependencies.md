# 干净 Windows 机器：依赖清单与安装顺序

> README §4 是速查表；本文是**从零到"能打包出第一个插件"**的完整清单，
> 每项写清：干什么用的、怎么检查、怎么装、多大、以及**为什么不能用替代品**。
> 实测环境：Windows 10 19044 x64（2026-10-28/29）。

---

## 0. 一页总结

| # | 依赖 | 必需性 | 下载量 | 装完占用 |
|---|---|---|---|---|
| 1 | POSIX bash 环境（Git for Windows **或** MSYS2） | **必需** | ~60 MB | ~300 MB |
| 2 | Rust（rustup）+ `stable-x86_64-pc-windows-msvc` | **必需** | ~300 MB | ~1.6 GB |
| 3 | VS Build Tools 2022（C++ 工作负载 + Windows SDK） | **必需** | ~1.7 GB | ~4.5 GB |
| 4 | Python ≥ 3.11 | **必需** | ~30 MB | ~100 MB |
| 5 | cargo-nih-plug（钉 rev） | **必需** | 源码编译 | ~30 MB |
| 6 | rustomp 框架仓（同级目录） | **必需** | ~10 MB | ~30 MB |
| 7 | CLAP SDK（给 clap-probe） | 强烈建议 | ~1 MB | ~0.4 MB |
| 8 | pluginval（VST3 验证） | 建议 | ~1.4 MB | ~3.3 MB |
| 8b | WiX 3.14 免安装 zip（打 MSI） | 仅 MSI | ~40 MB | ~75 MB |
| 9 | rust target `aarch64-pc-windows-msvc` | 仅 arm64 | ~50 MB | ~400 MB |
| 10 | MSVC ARM64 交叉工具集 | 仅 arm64 | ~250 MB | ~1 GB |

**总计（只出 x64）**：下载约 **2.2 GB**、磁盘约 **7 GB**；另加每个插件项目首次构建缓存
**0.6–1 GB**。装完的时间取决于网速：本机实测 Build Tools 1.7 GB 用了约 20 分钟
（走代理时反复超时，见 §4 的坑 1）。

**不需要**：Node.js、CMake、WSL、Visual Studio IDE（Build Tools 足够）、Xcode。

---

## 1. POSIX bash 环境

**为什么**：本仓全部脚本是 bash，并且依赖 MSYS 的路径语义（`cygpath`、`cp -R`、
POSIX 路径与 Windows 路径互转）。cmd / PowerShell / WSL 的 bash 都不行
（WSL 里没有 `cygpath`，也看不到 Windows 的 `C:\` 挂载语义）。

**装哪个**：

| 选项 | 说明 |
|---|---|
| **MSYS2** | **本机实测**。`C:\msys64`，`C:\msys64\usr\bin\bash.exe`；工具链齐全（478 个包） |
| **Git for Windows**（自带 Git Bash） | 同样基于 MSYS 运行时，`cygpath`/`sed`/`tr`/`find` 都在；**未在本机实测**，若遇到路径问题请换 MSYS2 |

**检查**：`bash --version`、`uname -s`（应是 `MSYS_NT-*` 或 `MINGW*_NT-*`）、`cygpath -w /`。

> `doctor.sh` 会检查这一点，并在 Cygwin/Linux 的 bash 里直接报错——因为那条路没验证过。

---

## 2. Rust（rustup，MSVC 工具链）

```powershell
winget install Rustlang.Rustup
# 新开一个 shell
rustup default stable-x86_64-pc-windows-msvc
```

**必须**是 `*-windows-msvc`。`*-windows-gnu`（MSYS2 pacman 里的 rustc 就是）**不行**：

- `nih_plug` 的 `vst3` feature 依赖 `vst3-sys`，要编译 Steinberg 的 **C++**；
- 商用宿主全部是 MSVC ABI，GNU 的 CRT/异常模型对不上。

**检查**：`rustc -vV | grep host` → `x86_64-pc-windows-msvc`。

> 坑：MSYS2 的 `pacman` 也装了一份 rustc（`-gnu`）。`doctor.sh` 会把 `~/.cargo/bin`
> 前置到 PATH 并对 host 做硬校验，所以即使两者共存也能用，但别手动 `export PATH` 打乱它。

---

## 3. VS Build Tools 2022（C++ 工作负载）

```powershell
winget install Microsoft.VisualStudio.2022.BuildTools --override `
  "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

提供三样东西：`cl.exe`/`link.exe`、`vcvars64.bat`、以及 **Windows SDK**（CRT 与 `kernel32.lib` 等）。

**检查**：

```powershell
& "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe" `
    -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
```

### 3.1 只在要 arm64 时追加

```powershell
# 必须“一开始就提权”（管理员 PowerShell），--quiet 不会自己弹 UAC
& "C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe" modify `
    --installPath "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools" `
    --add Microsoft.VisualStudio.Component.VC.Tools.ARM64 --quiet --norestart

rustup target add aarch64-pc-windows-msvc
```

装完应能看到这两个文件：

```text
…\BuildTools\VC\Auxiliary\Build\vcvarsamd64_arm64.bat
…\BuildTools\VC\Tools\MSVC\<版本>\bin\Hostx64\arm64\cl.exe
```

（Windows SDK 的 arm64 库 10.0.26100 默认就有：`…\Windows Kits\10\Lib\10.0.26100.0\{um,ucrt}\arm64`。）

---

## 4. Python ≥ 3.11

**为什么**：框架的 `tools/meta/plugin_meta.py` 用 `tomllib`（3.11 起是标准库）。
本仓不自己解析 TOML（契约 A 要求走框架的读取器）。

```powershell
winget install Python.Python.3.12
# 或 MSYS2：pacman -S mingw-w64-clang-x86_64-python
```

**检查**：`python -c "import tomllib"`。

`doctor.sh` 会依次找：`$PYTHON` → PATH 里的 `python3`/`python` → `C:\msys64\*\bin\python3.exe`
→ `%LOCALAPPDATA%\Programs\Python\Python3*\python.exe`，并要求**能 `import tomllib`**。

---

## 5. cargo-nih-plug（版本必须钉死）

```bash
cargo install --git https://github.com/robbert-vdh/nih-plug.git --rev de42101 cargo-nih-plug --locked
```

rev 与 [deps.lock](../deps.lock) 以及插件项目 `Cargo.toml` 里的 nih-plug rev **必须一致**，
否则 bundler 行为可能不同。`doctor.sh` 检查它是否存在；
`cargo nih-plug --help` **不能**用来探测（没有这个子命令，会误报）。

> 本机实测：编译约 72 秒（首次要连 GitHub 拉源码）。

---

## 6. rustomp 框架仓

```bash
cd <放插件的目录>
git clone https://github.com/amonisachicken/rustomp.git
```

只用来读 `rustomp.toml`（`tools/meta/plugin_meta.py`）与校验生成物，
**不需要编译它**。默认按 `<plugin_dir>/../rustomp` 查找，也可用 `RUSTOMP_ROOT` 指定。

---

## 7. CLAP SDK（clap-probe 用）

```bash
./scripts/fetch-third-party.sh
```

拉 `free-audio/clap` 的 tag `1.2.9`（`deps.lock` 钉死）到 `third_party/clap/include/clap/`。
用 `git clone` 而不是下载 zip：GitHub 的 https 在某些网络下不通，而 git 能走 SSH/代理。
体积约 341 KB。

没有它时 `verify.sh` 会**警告并跳过** clap-probe（`RUSTOMP_REQUIRE_VERIFY=1` 时算失败）。

---

## 8. pluginval（VST3 验证）

```bash
./scripts/fetch-third-party.sh --pluginval      # 需要能访问 GitHub releases
```

解压到 `third_party/pluginval/pluginval.exe`（v1.0.3，约 3.3 MB）。
也可以用 `PLUGINVAL=/path/to/pluginval.exe` 指定已有副本。

---

## 8b. WiX 3.14（只在打 MSI 时需要）

```bash
./scripts/fetch-third-party.sh --wix            # 需要能访问 GitHub releases（约 40 MB）
```

解压到 `third_party/wix/`（`candle.exe` / `light.exe` / `WixUIExtension.dll` 等 71 个文件）。

**为什么是 WiX v3 而不是 v4/v5**：v4+ 是 dotnet tool，必须装 .NET SDK（约 500 MB）；
v3 的 candle/light 是独立 exe，运行时只要 **.NET Framework 3.5**（Win10 自带，可在
「启用或关闭 Windows 功能 → .NET Framework 3.5」勾选）。本机实测 v3.14.1 直接可用。

**不需要**：Visual Studio IDE、CMake、NSIS、任何 .NET SDK。

装上之后 `doctor.sh --format msi` 会检查它；没装时 `pack.sh --format msi` 会明确告诉你
跑哪条命令，而不是让 light 报天书。

---

## 9. 网络受限时

| 现象 | 处理 |
|---|---|
| `github.com:443` 超时，但 `ssh -T git@github.com` 通 | `RUSTOMP_GIT_SSH=1 ./pack.sh …`（把 https 重写成 SSH 拉 git 依赖；**不改全局 git 配置**） |
| 需要走代理 | 先 `source ~/vpn.env`（`http_proxy`/`https_proxy`），本仓会自动透传进 MSVC 的 `.bat` |
| crates.io 慢 | `~/.cargo/config.toml` 配镜像（本机用 USTC sparse 源） |

---

## 10. 装完自检

```bash
./scripts/doctor.sh
```

期望看到（每行都应有一个 ✓）：

```text
✓ bash：MSYS 运行时（MSYS_NT-…，bash 5.3.9）
✓ 基础工具（cygpath/git/sed/tr/find/mktemp/cp …）
✓ rustc …（host x86_64-pc-windows-msvc）
✓ rust target x86_64-pc-windows-msvc
✓ MSVC 环境：…\vcvars64.bat
✓ cargo-nih-plug
✓ python：…（Python 3.12.x）
✓ rustomp 框架：…\rustomp
✓ 插件目录 / 生成物 / 素材 …
✓ pluginval：…（可选）
```

`doctor.sh` 的退出码就是"缺没缺东西"：`pack.sh` 会在第一步调用它，缺就停。

---

## 11. 装的过程中最容易踩的四个坑

1. **系统代理会毒死 VS 安装器**
   本机 WinINET 代理指向 `http://server.local:8888`，安装器下载 MS CDN 时反复
   `WebException: 操作超时`（10 分钟零进度）。把 `*.visualstudio.microsoft.com`
   加进「Internet 选项 → 连接 → 局域网设置 → 高级 → 例外」，速度从 ~55 KB/s 提到 2.4 MB/s。

2. **静默安装 arm64 组件时退出码 5007**
   `vs_installer` 的 `--quiet/--passive` 模式要求进程**一开始**就是管理员；
   否则它直接返回 `5007`（"Commands with --quiet or --passive should be run elevated from the beginning"）。
   用管理员 PowerShell，或 `Start-Process … -Verb RunAs`。

3. **MSYS2 的 `-gnu` rustc 抢在前面**
   症状是链接期一堆 `-l` 找不到或产物 ABI 不对。`doctor.sh` 会硬校验 `rustc -vV` 的 host。

4. **在 cmd/PowerShell 里直接跑 `pack.sh`**
   会用到系统里任意一个 bash（可能是 WSL 的），然后 `cygpath: command not found`。
   必须在 **Git Bash / MSYS2 的 bash** 里跑。
