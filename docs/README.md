# 文档索引

先读哪篇，取决于你要干什么。

| 你要… | 读这篇 |
|---|---|
| 搞清楚这个仓是干什么的、怎么用 | [../README.md](../README.md) |
| 在**一台干净机器**上从零装好 | [`04-dependencies.md`](04-dependencies.md) |
| 知道某处为什么这样写 | [`00-decisions.md`](00-decisions.md)（W-00x 决策账本） |
| 改打包流程 / 加新格式 | [`02-architecture.md`](02-architecture.md) |
| 判断"能不能算通过" / 加断言 | [`03-verify.md`](03-verify.md) |
| 了解生态边界（四个仓谁负责什么） | [`01-research.md`](01-research.md) |
| 知道踩过哪些坑、实测数字 | [`09-devlog.md`](09-devlog.md) |
| 看最初的需求书与路线图 | [`prompt.md`](prompt.md) |

---

## 文档清单

| 文件 | 内容 | 什么时候会过期 |
|---|---|---|
| [`00-decisions.md`](00-decisions.md) | 决策账本（W-001…W-009）：每条=背景/决定/后果 | 推翻某条决策时**必须**新增一条 |
| [`01-research.md`](01-research.md) | 生态调研：仓库地图、三个契约、mac 实现解剖、Windows 差异、环境实况 | rustomp 生态改契约时 |
| [`02-architecture.md`](02-architecture.md) | 架构：与 mac 的逐项对照、调用链、workspace 根/MSVC 注入/网络三个机制、通用性设计 | 脚本结构变化时 |
| [`03-verify.md`](03-verify.md) | 验证判据矩阵、三个工具的分工、arm64 的诚实边界、缺工具策略 | 加/改断言时 |
| [`04-dependencies.md`](04-dependencies.md) | 干净机器的完整依赖清单、安装顺序、体积、自检、四个常见坑 | 依赖版本或安装方式变化时 |
| [`09-devlog.md`](09-devlog.md) | 开发日志（E1…E7）：做了什么、为什么、踩了什么、实测数字 | 每轮开发追加一条 |
| [`prompt.md`](prompt.md) | 原始需求书（路线图、开发约定、可用工具） | 不改（历史存档） |

## 写文档的三条约定

1. **数字要带来源**：写"41.3 s"就说明是首次全量编译、哪台机器；
   没实测的写"未实测"，不要写成结论（例如 Git Bash 的支持状态）。
2. **决策与实现分离**：`00-decisions.md` 记"为什么"，其它篇只引用编号，不复述理由。
3. **README 保持能读完**：细节一律下沉到 `docs/`，README 只留"是什么/怎么用/边界"。
