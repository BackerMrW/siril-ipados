# Siril iPad 完整移植核对表

目标是原版功能、参数、图像交互和文件格式完整对应。当前 App 尚未达到该目标。

固定原版源码：`6c0f8f3207b9cb712f7e04249217123a8ca66915`（1.5 开发版）。目标采用最新开发版；2026-10-10 核对上游 HEAD 与此提交一致。

从原版主窗口提取 102 个不同动作，扫描 73 个 UI 文件；控件、信号、范围和默认值记录在 `app/Resources/UpstreamFeatures.json`。
这是自动发现的基线，不能替代代码路径、插件、脚本、序列以及实际交互核对。

## 当前必须补齐的跨工具能力

- 原版工作区：颜色通道、显示模式、直方图、像素读数、矩形/多边形选择、ROI、撤销重做、蒙版及对比预览。
- 序列：基础浏览/排除帧/质量图/参考帧与选择撤销已接入；其他配准模式、畸变和外部参考仍待补齐；全局一遍/两遍配准、主要叠加算法和校准高级选项已接入，仍非完整序列工作区。
- 颜色与分析：PCC/SPCC、星表/联网、解算与标注、测光与光变、PSF、像差/倾斜；单张/选区/CFA 和序列图像统计已接入，测光等仍待接入。
- 完整单张工具：原版每个工具的参数、交互输入、应用/取消、作用于序列、蒙版和预览。
- 格式和依赖：RAW、TIFF、JPEG、PNG、HEIF、JPEG XL、XISF、FFmpeg/FFMS2、curl/SQLite。当前对应 Siril 构建选项关闭。
- 平台接口：StarNet 等外部程序、Python/插件、在线下载、文件权限、内存、后台生命周期。需要真正适配，不能把空按钮算完成。

## 原版动作逐项状态

| 原版动作 | 名称 | 当前状态 |
| --- | --- | --- |
| win.documentation | Siril Manual | 待移植或待逐项验证 |
| win.updates | Check For Updates | 待移植或待逐项验证 |
| win.shortcuts | Keyboard Shortcuts | 待移植或待逐项验证 |
| win.chain-chan | Link/unlink channels in autostretch viewer mode. Current state: linked. | 待移植或待逐项验证 |
| win.undo | Undo | 单张处理结果和序列帧选择撤销已接入（采样/参数编辑等仍待接入） |
| win.redo | Redo | 单张处理结果和序列帧选择重做已接入（采样/参数编辑等仍待接入） |
| win.psf | PSF | 待移植或待逐项验证 |
| win.seq-psf | PSF for the Sequence | 待移植或待逐项验证 |
| win.pickstar | Pick a Star | 待移植或待逐项验证 |
| win.crop | Crop | 简化参数界面，未达到原版完整功能 |
| win.rotation-processing | Rotate & Crop | 简化参数界面，未达到原版完整功能 |
| win.seq-crop | Crop Sequence... | 待移植或待逐项验证 |
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
| win.align-kombat | KOMBAT alignment (planetary/deep-sky) | 待移植或待逐项验证 |
| win.align-psf | One star registration (deep-sky) | 待移植或待逐项验证 |
| win.align-dft | Image pattern alignment (planetary/deep-sky) | 待移植或待逐项验证 |
| win.autostretch_mask | Autostretch Mask | 待移植或待逐项验证 |
| win.threshold_mask | Apply Thresholds to Mask | 待移植或待逐项验证 |
| win.blur_mask | Blur Mask | 待移植或待逐项验证 |
| win.feather_mask | Feather Mask | 待移植或待逐项验证 |
| win.invert_mask | Invert Mask | 待移植或待逐项验证 |
| win.scale_mask | Multiply mask | 待移植或待逐项验证 |
| win.mask_from_gradient | Gradient of mask | 待移植或待逐项验证 |
| win.saturation-processing | Color Saturation... | 简化参数界面，未达到原版完整功能 |
| win.remove-green-processing | Remove Green Noise... | 待移植或待逐项验证 |
| win.negative-processing | Negative Transformation | 待移植或待逐项验证 |
| win.background-extr-processing | Background Extraction... | 交互界面已接入（序列应用仍待接入） |
| win.linearmatch-processing | Linear Match... | 待移植或待逐项验证 |
| win.pixel-math | Pixel Math... | 待移植或待逐项验证 |
| win.asinh-processing | Asinh Transformation... | 简化参数界面，未达到原版完整功能 |
| win.curves-processing | Curves Transformation... | 待移植或待逐项验证 |
| win.histo-processing | Histogram Transformation... | 简化参数界面，未达到原版完整功能 |
| win.payne-processing | Generalised Hyperbolic Stretch Transformations... | 待移植或待逐项验证 |
| win.color-calib-processing | Color Calibration... | 待移植或待逐项验证 |
| win.pcc-processing | Photometric Color Calibration... | 待移植或待逐项验证 |
| win.spcc-processing | Spectrophotometric Color Calibration... | 待移植或待逐项验证 |
| win.rgb-compositing-processing | RGB Compositing... | 待移植或待逐项验证 |
| win.merge-cfa-processing | Merge CFA Channels... | 待移植或待逐项验证 |
| win.split-channel-processing | Split Channels... | 待移植或待逐项验证 |
| win.split-cfa-processing | Split CFA Channels... | 待移植或待逐项验证 |
| win.split-wavelets-processing | Wavelet Layers... | 待移植或待逐项验证 |
| win.star-remix-processing | Star Recomposition... | 待移植或待逐项验证 |
| win.star-desaturate | Desaturate Stars | 待移植或待逐项验证 |
| win.star-synthetic | Full Resynthesis | 待移植或待逐项验证 |
| win.dyn-psf | Open Dynamic PSF dialog. | 待移植或待逐项验证 |
| win.wavelets-processing | À trous Wavelets Transform... | 待移植或待逐项验证 |
| win.fix-banding-processing | Banding Reduction... | 待移植或待逐项验证 |
| win.clahe-processing | Contrast-Limited Adaptive Histogram Equalization... | 待移植或待逐项验证 |
| win.cosmetic-processing | Cosmetic Correction... | 待移植或待逐项验证 |
| win.deconvolution-processing | Deconvolution... | 待移植或待逐项验证 |
| win.epf-processing | Edge Preserving Filters... | 待移植或待逐项验证 |
| win.fft-processing | Fourier Transform... | 待移植或待逐项验证 |
| win.medianfilter-processing | Median Filter... | 待移植或待逐项验证 |
| win.denoise-processing | Noise Reduction... | 简化参数界面，未达到原版完整功能 |
| win.rgradient-processing | Rotational Gradient... | 待移植或待逐项验证 |
| win.unpurple-processing | Unpurple Filter... | 待移植或待逐项验证 |
| win.rotation90-processing | Rotate 90 degrees, clockwise | 简化参数界面，未达到原版完整功能 |
| win.rotation270-processing | Rotate 90 degrees, counter-clockwise | 简化参数界面，未达到原版完整功能 |
| win.mirrorx-processing | Horizontal Mirror | 待移植或待逐项验证 |
| win.mirrory-processing | Vertical Mirror | 待移植或待逐项验证 |
| win.binning-processing | Binning... | 待移植或待逐项验证 |
| win.resample-processing | Resample... | 待移植或待逐项验证 |
| win.snapshot | Save as unique file | 待移植或待逐项验证 |
| win.clipboard | Copy to clipboard | 待移植或待逐项验证 |
| win.icc-tool | Color Management... | 待移植或待逐项验证 |
| win.ccm-processing | Color Conversion Matrix... | 待移植或待逐项验证 |
| win.fits-header | FITS Header... | 完整文件头查看与搜索已接入（编辑仍待接入） |
| win.image-information | Image Information... | 只读元数据已接入（原版编辑仍待接入） |
| win.astrometry | Image Plate Solver... | 待移植或待逐项验证 |
| win.annotate-dialog | Annotate... | 待移植或待逐项验证 |
| win.statistics | Statistics... | 原版单张/选区/CFA 和序列统计已接入（测光等仍待接入） |
| win.evaluate-noise | Noise Estimation | 待移植或待逐项验证 |
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
| win.photometry | Switch to PSF/photometry mode. If a sequence is loaded, a right click on the displayed image applies the PSF/Photometry on the whole sequence. | 待移植或待逐项验证 |
| win.cut | Make an intensity profile cut, showing a graph of the pixel value along a line between two points | 待移植或待逐项验证 |
| win.zoom-out | Shrink the image | 待移植或待逐项验证 |
| win.zoom-in | Enlarge the image | 待移植或待逐项验证 |
| win.zoom-fit | Fit the image to the window | 待移植或待逐项验证 |
| win.zoom-one | Show the image at its normal size | 待移植或待逐项验证 |
| win.seq-list | Show/Hide list of images in the sequence with registration data | 序列帧浏览/排除/参考帧、真实质量图与选择撤销已接入（仍非完整序列功能） |

## 完成标准

每项需有原版入口对应、参数与默认值对应、真实算法输出校验、原生交互校验和 iPad 验证记录。未通过者保持未完成。
批处理已接入：单/多张校准输入、暗场不缩放/最小化噪声/曝光缩放、主暗场坏点修正、CFA/去马赛克/平场 CFA 均衡/X-Trans 修复入口；全局一遍/两遍配准及实际应用、参考亮场、4 种变换、6 种插值、星对/星数/通道/缩放/钳位和两遍输出范围；5 种叠加方法、7 种剔除算法、5 种归一化选择、4 种权重、剔除图及5项质量筛选。Drizzle / Bayer Drizzle 的6种核、像素比例、输出倍率、主平场初始权重与8/32位权重已接入一遍/两遍流程。所有处理调用固定上游算法；界面参数与输入列表随任务保存，实际执行以 processing.ssf 为准。

序列工作区已接入原版逐帧读取、缩放/通道显示、单帧/范围参与切换、参考帧、12种质量/统计轴、原版两遍配准测量、序列统计和CSV；选择/参考帧支持跨重启撤销重做及中断恢复；重新叠加保留旧结果并复用输入。可直接按参与帧与质量筛选应用已有配准，设置输出范围/倍率/插值/钳位或 Drizzle 核/像素比例/主平场/权重位深，打开独立输出序列继续叠加；任务整体删除恢复包含全部序列和权重。单份配准输出的独立删除和像素结果撤销尚待接入。

批处理仍缺：其他原版序列交互/测光、PSF/DFT/KOMBAT 配准、畸变/外部参考、合成偏置和 BPM 文件入口、偏移合成/重叠归一化/羽化/叠加时放大，以及全部 GUI 默认值对应。真实相机数据上的坏点修正、X-Trans 和 CFA 均衡仍需专项验证；不能把命令参数接出视为全功能完成。

共享分析工作区已接入矩形选区、完整分辨率像素读数、原版 STATS_MAIN 八项统计及归一化/CFA 开关、原版整图/选区直方图和完整文件头查看/搜索/复制。选区目前用于分析；处理 ROI、蒙版、多边形选择、关键字编辑、文件信息编辑和直方图变换仍待移植。

背景提取已接入原版采样和图像 hook：增删/选择采样、自动/随机采样、RBF/1–4 阶多项式、减法/除法、抖动、自动渐变完整参数、原图/模型/结果预览与另存。校正结果已支持共享 FITS 撤销/重做；序列应用、拖动采样点和采样/参数编辑撤销仍待补齐。
