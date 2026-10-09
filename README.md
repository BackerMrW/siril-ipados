# Siril iPadOS 移植

使用真实 Siril 上游源码构建 iPadOS arm64 内核，再通过 C 接口连接 SwiftUI 界面。
固定上游提交：`6c0f8f3207b9cb712f7e04249217123a8ca66915`。

当前原生界面已接入：

- 多张 FITS 导入，亮场 / 暗场 / 平场 / 偏置 / 暗平场分类，勾选本次使用的文件，图库恢复。
- 上游 `readfits` 读取、图像信息、自动 MTF 预览，以及 FITS 结果导出。
- 原始 Siril 命令执行器：逐行同步运行 `.ssf` / 手动命令，显示原始日志，错误立即停止，可请求中止。
- 自动生成主校准帧、亮场校准、CFA 去马赛克、星点配准、Winsorized 剔除或中值叠加脚本。
- 单张背景提取、降噪和应用自动拉伸的脚本入口。
- 从实际编译的上游命令表生成可搜索的命令及参数列表，可插入脚本。

所有处理使用固定提交的 Siril 算法，在 iPad 本地完成。
这仍是原生移植测试版；桌面 GTK 窗口、在线星表服务、外部工具及部分可选格式尚未适配。
命令列表表示该内核的脚本入口，并不表示每个可选功能都已在 iPad 验证。

构建由 GitHub Actions 的 macOS 机器完成，本地可以只有 Windows 和 iPad。
工作流先编译目标依赖，再编译 Siril，并要求整个编译内核链接通过，最后生成
`SirilCore-iPadOS-arm64` 和 `SirilPad-unsigned` 两个构建产物。成功生成安装包后，
可在 Windows 上通过 [Sideloadly](https://sideloadly.io/) 本地签名并安装到连接的 iPad。
Apple 账号只用于本地签名，云端构建不需要 Apple 密码。

已验证：

- [0.2 真机目标构建](https://github.com/BackerMrW/siril-ipados/actions/runs/37982952528)：完整内核链接、原生 App 编译、未签名 IPA 生成。
- [0.2 iPad 模拟器运行](https://github.com/BackerMrW/siril-ipados/actions/runs/37982956515)：FITS 信息与读写、16 位像素归一化、原始命令转换序列、暗场与非均匀主平场校准、精确叠加像素数值、全局星点平移配准、自动 MTF 像素导出及错误停止。
- 同一模拟器中，Swift actor 运行界面生成的主偏置 / 主暗场 / 主平场、亮场校准与叠加脚本，恢复保存的图库，并在 SwiftUI 中显示结果。
- 物理 iPad、系统文件选择器、多张真实相机大图、CFA 去马赛克和全部命令仍需进一步实机验证；背景提取、降噪入口目前完成编译与接线，未逐项完成数值回归。

真机内存预算来自 `os_proc_available_memory`，当前处理使用可用预算的一半。
Apple 模拟器该 API 返回 0，回归测试改用保守的 512 MiB 可用预算，实际叠加预算为 256 MiB。
iPad 存储检查使用可用容量，而不依赖桌面文件系统类型说明。

使用批处理：

1. 在图库顶部选择帧类型，再分组导入各类 FITS；默认勾选新导入的文件。
2. 勾选同一目标、同一拍摄模式的亮场和匹配的校准帧。处理结果默认不参与下一次批处理。
3. 点“处理”，选择是否 CFA 去马赛克、星点配准、异常值剔除，再生成脚本并运行。
4. 运行期间保持 App 在前台；日志实时显示。完成后点结果名称预览，或用分享按钮导出 FITS。
5. 后期处理时只勾选一张图像或结果，生成单张处理脚本。自动拉伸预览不改变原始像素；后期脚本中的 `autostretch` 会改变新输出的像素。

自动流程不缩放暗场：暗场与亮场需相同曝光，温度、增益、偏置及拍摄模式也需匹配。
平场需偏置或暗平场；暗平场需与平场相同曝光。完整流程可编辑为其他 Siril 原生脚本。
主暗场保留偏置信号，亮场有主暗场时不会再重复扣偏置；平场优先用主暗平场，否则扣主偏置。

每次任务在 `Documents/Jobs/<UUID>` 创建独立目录，复制勾选文件并保存 `processing.ssf`、`processing.log`、输出和中间文件。
“文件”App 的 Siril iPad 目录可直接访问这些文件。中止或失败保留已经生成的结果。
脚本初始工作目录包含 `lights`、`darks`、`flats`、`biases`、`flatdarks`、`results` 和 `process`；
外部 `.ssf` 的文件路径需要对应这些目录。`exit`、后台实时叠加和 `@` 启动脱离管理的脚本不在嵌入入口开放。

安装真机测试版：

1. 打开成功的真机目标构建，在页面底部下载 **SirilPad-unsigned**，解压取得 `.ipa`。
2. 在 Windows 安装 Sideloadly，用 USB 连接 iPad 并选择“信任此电脑”。
3. 把 `.ipa` 拖进 Sideloadly，选择 iPad，使用自己的 Apple ID 本地签名安装。
4. 按 iPad 提示信任开发者；如提示需要开发者模式，在“设置 → 隐私与安全 → 开发者模式”开启并重启。

免费 Apple ID 签名通常有效 7 天，之后需要重新签名。

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
