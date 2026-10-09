# Siril iPadOS 移植

使用真实 Siril 上游源码构建 iPadOS arm64 内核，再通过 C 接口连接 SwiftUI 界面。
固定上游提交：`6c0f8f3207b9cb712f7e04249217123a8ca66915`。

当前移植界面的功能是多张 FITS 导入、图像信息和自动拉伸预览。
FITS 读取调用 Siril 的 `readfits`；自动拉伸调用 Siril 的自动 MTF 参数计算和 `MTFp`。
C 接口也接入了上游图像算术函数。校准、配准、叠加和完整桌面功能尚未接入界面。

构建由 GitHub Actions 的 macOS 机器完成，本地可以只有 Windows 和 iPad。
工作流先编译目标依赖，再编译 Siril，并要求整个编译内核链接通过，最后生成
`SirilCore-iPadOS-arm64` 和 `SirilPad-unsigned` 两个构建产物。成功生成安装包后，
可在 Windows 上通过 [Sideloadly](https://sideloadly.io/) 本地签名并安装到连接的 iPad。
Apple 账号只用于本地签名，云端构建不需要 Apple 密码。

[构建记录](https://github.com/BackerMrW/siril-ipados/actions/workflows/ipados-preflight.yml)
会分别显示依赖、内核链接、App 构建的结果。编译及链接成功不代表已在 iPad 上运行验证。
`dist/BUILD.json` 记录打包时使用的上游提交与静态库。

构建基线是 iPadOS 17、arm64，关闭 GTK、OpenMP、外部进程启动及部分可选文件格式和网络功能。
桌面 GTK 界面需要逐项接入原生界面。

主要文件：

- `native/siril-ipados.patch`：上游 Siril 的最初 iPadOS 构建适配。
- `native/SirilCore.c`：串行化调用上游内核的 C 接口。
- `tools/build-ipados-deps.py`：固定版本目标依赖与 Apple 框架适配。
- `tools/embed-siril.py`：把 C 接口及完整链接检查接入上游构建。
- `tools/package-siril.py`：把实际参与链接的目标静态库打包为 XCFramework。
- `app/`：调用内核的原生 iPad 界面。

新增接口及界面使用 GPL-3.0-or-later，Siril 和第三方依赖保留各自原有许可证。
