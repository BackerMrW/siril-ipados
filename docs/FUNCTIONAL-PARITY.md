# Siril iPad 完整移植核对表

目标是原版功能、参数、图像交互和文件格式完整对应。当前 App 尚未达到该目标。

固定原版源码：`2a724774dc4b2f9218d4d9055e81289b77ca9be3`（1.5 开发版）。目标采用最新开发版；2026-10-12 核对上游 HEAD 与此提交一致。

从原版主窗口提取 102 个不同动作，扫描 73 个 UI 文件；控件、信号、范围和默认值记录在 `app/Resources/UpstreamFeatures.json`。
这是自动发现的基线，不能替代代码路径、插件、脚本、序列以及实际交互核对。

2026-10-15：13个工具的矩形选区预览、整图应用及重放通过两个 SDK 和完整模拟器回归（`a26050c`）。本轮补齐曲线范围显示/保留阶段、整数原图直方图/吸管，引导滤波外部同坐标裁剪/原始位深保留，以及反卷积整图 PSF 估计后选区预览/实际 PSF 导出；新增独立数值检查和实际页面目检通过。已对应固定源码 GUI 明确启用 ROI 的工具集合，仍不代表所有工具及完整工作区对应完成。

## 当前必须补齐的跨工具能力

- 原版工作区：基础颜色通道、显示模式、直方图、像素读数与13个工具的矩形 ROI 预览/整图应用已接入并回归；多边形/自由绘制、统一撤销重做、蒙版及对比预览等完整交互仍待补齐。
- 序列：基础浏览/排除帧/质量图/参考帧与选择撤销已接入；全局一遍/两遍、DFT/KOMBAT、固定/跟随单星配准及主要叠加/校准高级选项已接入。彗星／小行星双位置/时间戳、已有星点变换合成和独立输出/历史/恢复已通过两个 SDK 与完整模拟器回归（`2ab254b`）；原生 SER 的16位单色、8位 RGB 和16位大端 BGR 已补齐独立速度/矩阵、应用像素及历史恢复专项（`b3535b0`）；畸变和 Drizzle 输入仍待补齐。双星／三星 PSF 的手动多选区、平移/旋转和固定/逐帧跟随已通过两个 SDK 与完整模拟器回归（`4a7cbb6`），专项数值证据覆盖单色两种 ROWORDER；其他格式/畸变组合仍待验收。多点的原生自动分析/局部对齐/专用叠加、独立分析记录及主要参数已通过两个 SDK 与完整模拟器回归（`dbf4511`）；专项证据覆盖质心恒等、两种局部模式 RGB 数值关系及源保留，保存分析重开、参考图及 AP 浏览已通过两个 SDK、数值和页面检查（`e903227`）；手动 AP 编辑、30 步历史及独立分析/配准/叠加已通过两个 SDK、数值与页面检查（`1949324`），不含真机触控；高级参数持久化、密集网格历史与稠密形变/倍率 RGB 关系已通过回归（`21bbe74`）；叠加参数复用和固定纹理的 ±4 像素非零差分形变已通过专项（`f7b9d5a`/`77e90cf`）；逐帧原图位移叠加、全局 +5/+3 与局部形变组合已通过回归及页面目检（`f1518fc`）；裁剪后四角与框大小下界通过（`da12c4f`）。原生 SER 导入/恢复、直接 MPP，以及四种 Bayer 排列的 LMMSE/RCD 彩色输出与独立亮度参考检查通过（`6fbc284`/`e42a89b`）；全部参数、位深/视频组合和真机仍待验收。畸变和外部参考等仍待补齐，仍非完整序列工作区。
- 颜色与分析：原版解算、PCC/SPCC、HTTPS/SQLite 已接入；解算独立星表和PCC/SPCC完整数值回归已通过，远程星表端到端仍待验收；标注、像差/倾斜、标准星/其他分析仍待补。单张/选区/CFA和序列统计、动态PSF/孔径测光、原版序列PSF/差分光变已接入。
- 完整单张工具：原版每个工具的参数、交互输入、应用/取消、作用于序列、蒙版和预览。
- 格式和依赖：PNG/JPEG/TIFF原版读写与原版 LibRaw/DNG 回归已通过；curl/SQLite 已开启并通过 TLS 与持久化检查；JPEG XL、XISF、SER、HEIC/AVIF/16-bit HEIF 的独立像素与整轮回归已通过；FFmpeg/FFMS2 静态解码已连入并完成核心链接；原生视频转 SER、奇数宽度单色/RGB AVI、PNG MOV、H.264 RGB/BT.709 YUV420 MP4、VP9 RGB WebM、四种 Bayer 提示、取消重试及 AVIF 分流已通过两个 SDK、完整数值与页面回归（`5b9ee4f`）；长视频、其他编码/位深及真实相机仍待验收。直接证据与边界见 [当前验证记录](VALIDATION-CURRENT.md)。
- 平台接口：StarNet 等外部程序、Python/插件、在线下载、文件权限、内存、后台生命周期。需要真正适配，不能把空按钮算完成。

## 原版动作逐项状态

| 原版动作 | 名称 | 当前状态 |
| --- | --- | --- |
| win.documentation | Siril Manual | 待移植或待逐项验证 |
| win.updates | Check For Updates | 待移植或待逐项验证 |
| win.shortcuts | Keyboard Shortcuts | 待移植或待逐项验证 |
| win.chain-chan | Link/unlink channels in autostretch viewer mode. Current state: linked. | 待移植或待逐项验证 |
| win.undo | Undo | 单张结果、序列帧选择和背景采样/参数撤销已接入（蒙版等仍待接入） |
| win.redo | Redo | 单张结果、序列帧选择和背景采样/参数重做已接入（蒙版等仍待接入） |
| win.psf | PSF | 原版单星Gaussian/Moffat拟合与孔径测光已接入（其他交互/真机待验证） |
| win.seq-psf | PSF for the Sequence | 原版序列PSF、选区跟踪、参与帧测光/报告与差分光变已接入（其他GUI细节待补） |
| win.pickstar | Pick a Star | 待移植或待逐项验证 |
| win.crop | Crop | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.rotation-processing | Rotate & Crop | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.seq-crop | Crop Sequence... | 普通/FITSEQ/Drizzle 参与帧裁剪、矩形选区、参考帧、权重/加权叠加及撤销/回滚已随1e36552两个 SDK 整轮通过；真机未验收 |
| win.mask_from_image | Mask from current image | 待移植或待逐项验证 |
| win.mask_from_color | Mask from color | 待移植或待逐项验证 |
| win.mask_from_stars | Mask from stars | 待移植或待逐项验证 |
| win.mask_from_file | Mask from image file | 待移植或待逐项验证 |
| win.mask_add_from_poly | Add freehand to mask | 待移植或待逐项验证 |
| win.mask_clear_from_poly | Subtract freehand from mask | 待移植或待逐项验证 |
| win.clear_mask | Clear mask | 待移植或待逐项验证 |
| win.set_roi | Set ROI to selection | 待移植或待逐项验证 |
| win.clear_roi | Clear ROI | 待移植或待逐项验证 |
| win.align-global | 2-pass global star alignment (deep-sky) | 原版两遍全局星点配准、Drizzle / Bayer Drizzle 与实际应用已接入（畸变与外部参考仍待接入） |
| win.align-kombat | KOMBAT alignment (planetary/deep-sky) | 原版矩形图案、5–100%移动范围、矩阵/参考帧、实际应用像素与失败元数据恢复已随1e36552整轮通过；真机未验收 |
| win.align-psf | One star registration (deep-sky) | 原版固定/跟随选区 PSF、双 ROWORDER 独立位移/FWHM/像素及无星回滚已随0778941整轮通过；质量切换补充待验证，真机未验收 |
| win.align-dft | Image pattern alignment (planetary/deep-sky) | 原版 DFT、正方形选区、参考/排除帧、独立矩阵及实际应用像素与失败元数据恢复已随1e36552整轮通过；真机未验收 |
| win.autostretch_mask | Autostretch Mask | 待移植或待逐项验证 |
| win.threshold_mask | Apply Thresholds to Mask | 待移植或待逐项验证 |
| win.blur_mask | Blur Mask | 待移植或待逐项验证 |
| win.feather_mask | Feather Mask | 待移植或待逐项验证 |
| win.invert_mask | Invert Mask | 待移植或待逐项验证 |
| win.scale_mask | Multiply mask | 待移植或待逐项验证 |
| win.mask_from_gradient | Gradient of mask | 待移植或待逐项验证 |
| win.saturation-processing | Color Saturation... | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.remove-green-processing | Remove Green Noise... | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.negative-processing | Negative Transformation | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.background-extr-processing | Background Extraction... | 交互界面与序列应用已接入（真机大图验证待完成） |
| win.linearmatch-processing | Linear Match... | 原版参考图/上下限、单色/RGB全像素拟合、私有结果/重放、历史与失败拒绝已随1e36552整轮通过；真机未验收 |
| win.pixel-math | Pixel Math... | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.asinh-processing | Asinh Transformation... | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.curves-processing | Curves Transformation... | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.histo-processing | Histogram Transformation... | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.payne-processing | Generalised Hyperbolic Stretch Transformations... | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.color-calib-processing | Color Calibration... | 原版背景中和、白参考、手动 RGB 系数、独立全部像素与任务重放已随0778941整轮通过；界面分组/未选参考拒绝补充待验证，真机未验收 |
| win.pcc-processing | Photometric Color Calibration... | 原版工作区/参数/历史已接入，完整测光与独立通道增益数值回归通过；远程星表/真机待验收 |
| win.spcc-processing | Spectrophotometric Color Calibration... | 原版工作区/光谱模型/参数/历史已接入，完整光谱测光与独立窄带颜色数值回归通过；远程星表/真机待验收 |
| win.rgb-compositing-processing | RGB Compositing... | 待移植或待逐项验证 |
| win.merge-cfa-processing | Merge CFA Channels... | 待移植或待逐项验证 |
| win.split-channel-processing | Split Channels... | 待移植或待逐项验证 |
| win.split-cfa-processing | Split CFA Channels... | 待移植或待逐项验证 |
| win.split-wavelets-processing | Wavelet Layers... | 待移植或待逐项验证 |
| win.star-remix-processing | Star Recomposition... | 待移植或待逐项验证 |
| win.star-desaturate | Desaturate Stars | 待移植或待逐项验证 |
| win.star-synthetic | Full Resynthesis | 待移植或待逐项验证 |
| win.dyn-psf | Open Dynamic PSF dialog. | 原版星点检测、动态PSF表格/排序/多选/均值与导出、所选星点到反卷积、持久化删除撤销已接入（其他交互待补） |
| win.wavelets-processing | À trous Wavelets Transform... | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.fix-banding-processing | Banding Reduction... | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.clahe-processing | Contrast-Limited Adaptive Histogram Equalization... | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.cosmetic-processing | Cosmetic Correction... | 待移植或待逐项验证 |
| win.deconvolution-processing | Deconvolution... | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.epf-processing | Edge Preserving Filters... | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.fft-processing | Fourier Transform... | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.medianfilter-processing | Median Filter... | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.denoise-processing | Noise Reduction... | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.rgradient-processing | Rotational Gradient... | 原版极坐标差分、中心/径向/旋转参数、Gaussian中心拟合、全RGB像素/三深度蒙版/历史与原生页已随1e36552整轮通过；真机未验收 |
| win.unpurple-processing | Unpurple Filter... | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.rotation90-processing | Rotate 90 degrees, clockwise | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.rotation270-processing | Rotate 90 degrees, counter-clockwise | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.mirrorx-processing | Horizontal Mirror | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.mirrory-processing | Vertical Mirror | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.binning-processing | Binning... | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.resample-processing | Resample... | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.snapshot | Save as unique file | 待移植或待逐项验证 |
| win.clipboard | Copy to clipboard | 待移植或待逐项验证 |
| win.icc-tool | Color Management... | 原版 ICC 分配/转换/移除、内置/自定义目标、四种意图、ICC 导出和 D50 色域图已接入；独立数值、持久化重放与原生页已随563e882整轮通过 |
| win.ccm-processing | Color Conversion Matrix... | 原版工具参数、全分辨率预览/另存与编辑历史已接入（完整GUI/ROI/序列对应仍需补齐，真机未验证） |
| win.fits-header | FITS Header... | 完整文件头查看/搜索、单张/批量及普通/FITSEQ 参与帧编辑已接入；独立输出/源字节、配准/参考帧、已有蒙版/输入快照与失败回滚已随88d39eb整轮通过 |
| win.image-information | Image Information... | 只读元数据已接入（原版编辑仍待接入） |
| win.astrometry | Image Plate Solver... | 原版解算工作区/参数/历史已接入，独立 TAN 星表、中心/比例及 WCS FITS 往返通过；远程星表/真机待验收 |
| win.annotate-dialog | Annotate... | 待移植或待逐项验证 |
| win.statistics | Statistics... | 原版单张/选区/CFA 和序列统计已接入（测光等仍待接入） |
| win.evaluate-noise | Noise Estimation | 原版统计/选区/CFA和复制报告、独立Gaussian RGB/8/16位噪声幅度、渐变与源像素检查已随1e36552整轮通过；真机未验收 |
| win.ccd-inspector | Aberration Inspector | 待移植或待逐项验证 |
| win.show-tilt | Show Tilt | 待移植或待逐项验证 |
| win.show-disto | Show Distortions | 待移植或待逐项验证 |
| win.compstars | Create Comparison Stars File ... | 待移植或待逐项验证 |
| win.catmag | Calibrate magnitudes ... | 待移植或待逐项验证 |
| win.nina_light_curve | Automated Light Curve... | 待移植或待逐项验证 |
| win.cwd | Change current working directory | 待移植或待逐项验证 |
| win.livestacking | Start livestacking session | 待移植或待逐项验证 |
| win.panel | Hide the control panel to show only the image panel (toggle). | 待移植或待逐项验证 |
| win.negative-view | Switch to normal and negative view | 待移植或待逐项验证 |
| win.color-map | Switch to normal and rainbow colormap (false color rendering) | 待移植或待逐项验证 |
| win.histo_display | Show/hide histogram overlay | 直方图分析窗口已接入（工作区叠加仍待接入） |
| win.annotate-object | Left-click to show object names if WCS information is available. Right-click to display a list of astro catalogs to choose from. | 待移植或待逐项验证 |
| win.wcs-grid | Show celestial grid if WCS information is available | 待移植或待逐项验证 |
| win.photometry | Switch to PSF/photometry mode. If a sequence is loaded, a right click on the displayed image applies the PSF/Photometry on the whole sequence. | 单张孔径测光与序列原版PSF/差分光变已接入（标准星与其他分析交互待补） |
| win.cut | Make an intensity profile cut, showing a graph of the pixel value along a line between two points | 待移植或待逐项验证 |
| win.zoom-out | Shrink the image | 待移植或待逐项验证 |
| win.zoom-in | Enlarge the image | 待移植或待逐项验证 |
| win.zoom-fit | Fit the image to the window | 待移植或待逐项验证 |
| win.zoom-one | Show the image at its normal size | 待移植或待逐项验证 |
| win.seq-list | Show/Hide list of images in the sequence with registration data | 序列帧浏览/排除/参考帧、真实质量图与选择撤销已接入（仍非完整序列功能） |

## 完成标准

每项需有原版入口对应、参数与默认值对应、真实算法输出校验、原生交互校验和 iPad 验证记录。未通过者保持未完成。
批处理已接入：单/多张校准输入、暗场不缩放/最小化噪声/曝光缩放、主暗场坏点修正、CFA/去马赛克/平场 CFA 均衡/X-Trans 修复入口；全局一遍/两遍配准及实际应用、参考亮场、4 种变换、6 种插值、星对/星数/通道/缩放/钳位和两遍输出范围；5 种叠加方法、7 种剔除算法、5 种归一化选择、4 种权重、剔除图及5项质量筛选。Drizzle / Bayer Drizzle 的6种核、像素比例、输出倍率、主平场初始权重与8/32位权重已接入一遍/两遍流程。所有处理调用固定上游算法；界面参数与输入列表随任务保存，实际执行以 processing.ssf 为准。

序列工作区已接入原版逐帧读取、缩放/通道显示、单帧/范围参与切换、参考帧、12种质量/统计轴、原版两遍配准测量、序列统计和CSV；选择/参考帧支持跨重启撤销重做及中断恢复；重新叠加保留旧结果并复用输入。可直接按参与帧与质量筛选应用已有配准，设置输出范围/倍率/插值/钳位或 Drizzle 核/像素比例/主平场/权重位深，打开独立输出序列继续叠加；任务整体删除恢复包含全部序列和权重。单份配准/Drizzle/背景输出可独立删除、撤销、恢复与永久清理，使用原版文件名并包含权重和编辑历史，保护源/其他输出/叠加结果和后续依赖；中断删除回滚，中断恢复继续。配准/Drizzle/背景处理结果支持30步跨关闭撤销/重做，按来源记录恢复原图/输出链，真实切换整组像素、尺寸与通道，保留权重；新处理清除重做分支；删除当前输出回退到可用前序，恢复后可重做。叠加结果切换与蒙版撤销仍待接入。

批处理仍缺：其他原版序列交互/测光、其他配准交互、三星彩准/彗星/多点、畸变/外部参考、合成偏置和 BPM 文件入口、偏移合成/重叠归一化/羽化/叠加时放大，以及全部 GUI 默认值对应。真实相机数据上的坏点修正、X-Trans 和 CFA 均衡仍需专项验证；不能把命令参数接出视为全功能完成。

共享分析工作区已接入矩形选区、完整分辨率像素读数、原版 STATS_MAIN 九项统计（含 bgNoise）及归一化/CFA 开关、原版整图/选区直方图和完整文件头查看/搜索/复制，单张与批量关键字编辑及失败回滚已验证。选区目前用于分析；处理 ROI、多边形选择、文件信息编辑和完整直方图变换交互仍待补齐；普通/FITSEQ 序列关键字编辑及普通/FITSEQ/Drizzle 裁剪已通过独立像素与整轮回归。

原生工具工作区已有42个原版图像工具通过整轮回归（0778941），包含颜色校准：MTF/反向MTF、Asinh、GHS/反向GHS、修正Asinh及反向、线性/自动MTF/自动GHS、饱和度/SCNR/负片/去紫/CCM、中值/高斯/反锐化/CLAHE/条纹/双边/引导/NL-Bayes/小波、裁剪/任意角旋转/直角旋转/镜像/合并像素/重采样、曲线/像素数学、FFT正向/逆向、反卷积/PSF、ICC、线性匹配与旋转梯度。具备未改动输入快照、完整分辨率原版计算、原图/结果/蒙版比较、另存、30步跨关闭参数历史及共享图像结果撤销。原版亮度/通道/颜色/星点/外部图像蒙版与阈值/模糊/羽化/反转/乘法已接入；保存的蒙版随图像、几何变换和删除恢复保留。处理ROI、多边形、所有原版GUI细节和序列应用仍未完成。

背景提取已接入原版采样和图像 hook：增删/选择采样、自动/随机采样、RBF/1–4 阶多项式、减法/除法、抖动、自动渐变完整参数、原图/模型/结果预览与另存。校正结果支持共享 FITS 撤销/重做；采样点可拖动并重读原图中值，采样/参数修改支持30步跨重启撤销/重做、分支清除与滑块/拖动合并。编辑记录随图库文件删除/恢复/永久清理。序列应用接入原版 GUI worker：每帧重新采样、Bayer 四子通道处理、完整采样/自动模型参数、减法/除法与抖动；预览调用相同序列 hook，新输出独立命名并检查全部参与帧，部分失败保留日志与输出但不报全部完成。序列参数30步撤销/重做跨关闭保存，随任务删除恢复；单份输出独立删除/撤销/恢复已接入存储管理；关闭校正页切换到完成输出，整组结果支持30步跨关闭撤销/重做，重复从同一来源应用不会混成串行链；删除当前结果回退，恢复后可重做。
