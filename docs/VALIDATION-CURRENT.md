# Windows 本地接续验证记录

2026-10-13 接续；固定上游仍为 `2a724774dc4b2f9218d4d9055e81289b77ca9be3`。完整移植继续进行，未发布新版本。本地负责源码、依赖和原生界面修改，现有 macOS Actions 负责 Apple 两个 SDK 的构建与模拟器执行。

## 已有直接执行证据

- `11fbd02b5c130a5f6c50b21e0148c82bea70e304` 的[两个 SDK 任务](https://github.com/BackerMrW/siril-ipados/actions/runs/38350644889)均成功。原版解算器匹配独立 TAN 星表，RA/DEC 中心和 2 arcsec/pixel 比例通过严格检查，WCS 经 FITS 保存/读取保留；原版 LibRaw 读取独立 16-bit DNG 的尺寸、线性像素、方向、CFA 及 Swift 工作 FITS 往返通过。原有单张工具、序列、蒙版、撤销/存储和原生页面回归也通过。
- 原版 `fetch_url` 在本地 HTTPS 服务器上验证受信任证书，拒绝错误主机名和不受信任根证书。Apple SQLite 持久化测试通过；原版 SPCC 数据库的 15 个单色传感器、51 个彩色传感器和 147 份白参考，以及原版数组读取器通过。该证据不代表已实测所有远程星表服务。
- `2b0a63771d33a42d27a3f877ab7da08173e47278` 的[模拟器执行](https://github.com/BackerMrW/siril-ipados/actions/runs/38353299535)已通过完整 PCC 和 SPCC 数值检查：PCC 在两组不同通道增益的 25 星图上恢复一致颜色并中和背景；SPCC 从独立幂律光子谱、三段窄带积分和已知通道增益恢复预期颜色。另有解析光谱插值/积分、通道增益应用与无效系数不修改像素检查。此任务整体因后续 XISF 测试样本的大小写错误失败，不能算整轮回归成功。
- 上述 PCC 回归发现原版 `robust_median_f` 的自动区域使用全局 `gfit` 尺寸，已修正为传入图像尺寸；测试保留与全局图像不同尺寸的输入，验证真实问题。

- [d84cda0 的回归](https://github.com/BackerMrW/siril-ipados/actions/runs/38355186742)中真机目标构建成功，模拟器 C 层 XISF、SER、三种 CFA 格式的实际去马赛克颜色均通过；整体仍因 JPEG XL 导出预期未考虑原版默认颜色空间转换失败，后续 Swift 检查未执行。

- `bb7d00dfcb8b354be6cd21306ede4dd627fde5c2` 的[整轮回归](https://github.com/BackerMrW/siril-ipados/actions/runs/38356956324)两个 SDK 均成功：XISF/SER/CFA 与单色/RGB JPEG XL 独立导入、默认工作颜色空间转换及保留 ICC 无损导出均通过；完整 Swift、原有工具与原生页面检查通过。

- `040f9cff7f542989dd3274c29b30d4d765a2f14d` 的[整轮回归](https://github.com/BackerMrW/siril-ipados/actions/runs/38359411261)两个 SDK 均成功：HEIC/AVIF/无压缩16位 HEIF 全像素对照独立公开解码器，包含行填充、透明通道及 FITS 往返；原版 FITS 关键字新增/修改/重命名/删除/注释通过独立 CFITSIO 对照，已知元数据更新、受保护字段拒绝、源像素/文件头不变和 Swift 批量失败回滚通过。

- `0234a9e223160f7f74b00fc6e33e8b1c357368af` 的[两个 SDK 整轮回归](https://github.com/BackerMrW/siril-ipados/actions/runs/38361358448)成功：原版提取 LUT 的五种公式、显示范围、STF 与原有预览一致、CDF 与独立排名、逐像素反转和原图不变通过；Swift 七模式/RGB 独立 STF 与设置持久化通过；新增 FITS 关键字编辑页已实际打开并截图。

## 当前实现与待验证

- XISF：固定 libXISF `de757840b3973237172b932b14efd011cfc1151d` 和 zstd 1.5.7；原版读取器、UInt16 CFA 和 Float32 平面 RGB 像素、曝光与 FITS 往返已在模拟器执行通过。在 d84cda0 的模拟器任务中，交错存储/字节洗牌 zlib、压缩损坏/截断/非法几何拒绝以及原版去马赛克后的真实 RGB 已通过；完整 Swift 导入仍待整轮执行。原版 XISF 保持只读，工作输出用 FITS。
- SER：调用原版逐帧解码，保留原始副本，输出独立工作 FITS；支持原生取消与失败回滚。独立测试包含三帧 mono/CFA/RGB/BGR、8/16-bit、两个字节序、逐帧时间与曝光、截断序列和源文件保留；CFA 转换还检查去马赛克后的真实 RGB。d84cda0 的模拟器已通过上述 C 层像素/元数据与去马赛克颜色检查；Swift 取消/回滚等待整轮继续执行。
- JPEG XL：固定 0.12.0 `a7a9c787341cf703dede03c2009fa460cae5e5df`，Brotli/Highway 使用该提交固定子模块，LCMS 使用已有目标库；两个 Apple 目标已编译通过。已接入原版读写与质量/无损/计算量参数、32-bit float/8-bit 导出、设置记录；修复原版质量变量遮蔽、压缩输入泄漏和写出失败未传播。d84cda0 中独立公开 libjxl 编码器核对原版 RGB 导入通过；导出对比发现原版默认转换到工作颜色空间，原始像素不能直接作为转换后预期。已接入 sRGB/工作空间/保留图像 ICC 选项和持久化；分别用独立 LCMS 转换和原始像素检查默认导出与保留 ICC 导出，并扩展单色检查。上述 JPEG XL 检查已随 bb7d00d 整轮通过。
- HEIF/HEIC/AVIF：libheif 1.23.6、libde265 1.1.3、dav1d 1.5.4 静态构建已在两个 SDK 通过，原版导入与行步长/16-bit 修复已接入；首次内核编译发现内存预算 helper 缺少声明，已补头文件重新构建，像素/Swift 检查已在 040f9cf 整轮通过。
- 新增依赖的固定源码与许可证进入现有源码打包和 App 通知目录；Mozilla CA PEM 来源、日期、SHA-256 与 MPL-2.0 许可已记录。

- FITS 关键字：原版 API 已接入单张与批量界面、独立输出和参数记录；040f9cf 专项与整轮通过。新增编辑页截图的 a8208c7 模拟器任务因 GitLab 数据下载 HTTP 502 失败，重试又遇到上游源码 HTTP 503；后续 0234a9e 整轮已通过新增页检查。固定源码下载已加90秒超时、3次有界重试及 SHA 校验，避免把临时下载问题误报为编译通过。
- 共用显示：从固定原版 GTK 源码提取 LUT 算术，接入七种模式、低/高值、独立通道 STF、反转和显示设置持久化；原始像素保持不变，主图/分析的专项与原生界面已通过。工具、背景/模型、单张星点、序列浏览/背景/测光继续接通同一控制，并扩展独立 RGB STF 与所有背景视图/序列帧的检查；这些新接入仍待本轮验证。完整显示色彩管理/伪彩色/蒙版叠加仍需继续完成。

## 继续执行的缺口

其他视频、ROI/多边形/完整显示交互、剩余配准与序列工具、标准星/绝对测光与其他天文分析、FITS序列原生关键字编辑、Python/插件/StarNet 移动实现仍待补齐。实际远程星表端到端、真实大型相机文件、物理 iPad Air M4 和触摸仍未完成验收。
