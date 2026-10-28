# 开发面向Windows平台的rustomp打包器

我开发了一个基于rust的软效果器框架，目前已经在macOS上跑通全过程了，并且实际产出了可用的软效果器。该项目采用跨平台与模块化设计，只有打包器与平台有关。面向macOS平台的打包器已经可用，现在你参照amonisachicken/rustomp-mac-plugin的github项目，开发一个面向Windows平台的打包器，以与rustomp主项目组合使用。

## 开发约定

1. rustomp主项目**不关心**插件实际运行的平台，因此开发面向Windows的打包器也不需要对上游的rustomp主项目进行修改。
2. 目前只实现Windows平台VST/AU插件的生成，暂时不考虑standalone应用生成。
3. 如遇技术选型问题，一定要与我讨论，把可用选项交我决定，经我批准才能继续。

## 开发路线图

1. 阅读rustomp生态系统的相关md文档，了解这个框架的功能、技术实现、开发偏好，知道每个模块各自的功能边界。
2. 参照rustomp-mac-plugin的实现，开发面向Windows平台相同功能的打包器。
3. 克隆sparklin-drive仓库，利用打包器生成适用于Windows平台的插件。

## 可用工具

- 如遇到网络问题，可source ~/vpn.env
- 本机自带msys2生态，可通过pacman安装需要的包
