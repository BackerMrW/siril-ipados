#!/usr/bin/env python3
"""Inventory pinned Siril UI controls; compiling a command is not GUI parity."""
import argparse
import json
from pathlib import Path
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
ui = args.source / "src/gui-gtk4/uifiles"
panels = []
for path in sorted(ui.glob("*.ui")):
    tree = ET.parse(path)
    controls = []
    titles = []
    for obj in tree.iter("object"):
        properties = {p.get("name"): p.text or "" for p in obj.findall("property")}
        if properties.get("title"):
            titles.append(properties["title"])
        if obj.get("class") in {"GtkSpinButton", "GtkScale", "GtkCheckButton", "GtkDropDown", "GtkEntry", "GtkButton", "GtkAdjustment"}:
            controls.append({"id": obj.get("id", ""), "kind": obj.get("class"), "properties": properties,
                             "signals": [s.attrib for s in obj.findall("signal")]})
    panels.append({"file": path.name, "titles": titles, "controls": controls})

main = ET.parse(ui / "siril.ui")
parents = {child: parent for parent in main.iter() for child in parent}
entries = []
seen = set()
partial = {"saturation-processing", "asinh-processing", "histo-processing", "denoise-processing", "rotation-processing", "rotation90-processing", "rotation270-processing", "crop"}
for obj in main.iter("object"):
    props = {p.get("name"): p.text or "" for p in obj.findall("property")}
    action = props.get("action-name", "")
    if not action.startswith("win.") or action in seen:
        continue
    seen.add(action)
    title = props.get("label") or props.get("tooltip-text") or action.removeprefix("win.")
    group = "工作区与分析"
    parent = obj
    while parent in parents:
        parent = parents[parent]
        if parent.get("class") == "GtkStackPage":
            names = {p.get("name"): p.text or "" for p in parent.findall("property")}
            group = names.get("name", group)
            break
    connected = {
        "win.undo": "单张处理结果和序列帧选择撤销已接入（采样/参数编辑等仍待接入）",
        "win.redo": "单张处理结果和序列帧选择重做已接入（采样/参数编辑等仍待接入）",
        "win.align-global": "原版两遍全局星点配准、Drizzle / Bayer Drizzle 与实际应用已接入（畸变与外部参考仍待接入）",
        "win.background-extr-processing": "交互界面已接入（序列应用仍待接入）",
        "win.statistics": "原版单张/选区/CFA 和序列统计已接入（测光等仍待接入）",
        "win.seq-list": "序列帧浏览/排除/参考帧、真实质量图与选择撤销已接入（仍非完整序列功能）",
        "win.fits-header": "完整文件头查看与搜索已接入（编辑仍待接入）",
        "win.image-information": "只读元数据已接入（原版编辑仍待接入）",
        "win.histo_display": "直方图分析窗口已接入（工作区叠加仍待接入）",
    }
    state = connected.get(action, "简化参数界面，未达到原版完整功能" if action.removeprefix("win.") in partial else "待移植或待逐项验证")
    entries.append({"id": action, "title": title, "group": group, "status": state})

value = {"upstreamRevision": "6c0f8f3207b9cb712f7e04249217123a8ca66915", "entries": entries,
         "panels": panels, "note": "Every status requires parameter, interaction, algorithm, and device verification. A command catalog is not a completion claim."}
out = root / "app/Resources/UpstreamFeatures.json"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
lines = ["# Siril iPad 完整移植核对表", "", "目标是原版功能、参数、图像交互和文件格式完整对应。当前 App 尚未达到该目标。", "",
         "固定原版源码：`" + value["upstreamRevision"] + "`（1.5 开发版）。目标采用最新开发版；2026-10-10 核对上游 HEAD 与此提交一致。", "",
         f"从原版主窗口提取 {len(entries)} 个不同动作，扫描 {len(panels)} 个 UI 文件；控件、信号、范围和默认值记录在 `app/Resources/UpstreamFeatures.json`。",
         "这是自动发现的基线，不能替代代码路径、插件、脚本、序列以及实际交互核对。", "",
         "## 当前必须补齐的跨工具能力", "",
         "- 原版工作区：颜色通道、显示模式、直方图、像素读数、矩形/多边形选择、ROI、撤销重做、蒙版及对比预览。",
         "- 序列：基础浏览/排除帧/质量图/参考帧与选择撤销已接入；其他配准模式、畸变和外部参考仍待补齐；全局一遍/两遍配准、主要叠加算法和校准高级选项已接入，仍非完整序列工作区。",
         "- 颜色与分析：PCC/SPCC、星表/联网、解算与标注、测光与光变、PSF、像差/倾斜；单张/选区/CFA 和序列图像统计已接入，测光等仍待接入。",
         "- 完整单张工具：原版每个工具的参数、交互输入、应用/取消、作用于序列、蒙版和预览。",
         "- 格式和依赖：RAW、TIFF、JPEG、PNG、HEIF、JPEG XL、XISF、FFmpeg/FFMS2、curl/SQLite。当前对应 Siril 构建选项关闭。",
         "- 平台接口：StarNet 等外部程序、Python/插件、在线下载、文件权限、内存、后台生命周期。需要真正适配，不能把空按钮算完成。",
         "", "## 原版动作逐项状态", "", "| 原版动作 | 名称 | 当前状态 |", "| --- | --- | --- |"]
for entry in entries:
    lines.append("| " + entry["id"] + " | " + entry["title"].replace("|", "/").replace("\n", " ") + " | " + entry["status"] + " |")
lines += ["", "## 完成标准", "", "每项需有原版入口对应、参数与默认值对应、真实算法输出校验、原生交互校验和 iPad 验证记录。未通过者保持未完成。",
          "批处理已接入：单/多张校准输入、暗场不缩放/最小化噪声/曝光缩放、主暗场坏点修正、CFA/去马赛克/平场 CFA 均衡/X-Trans 修复入口；全局一遍/两遍配准及实际应用、参考亮场、4 种变换、6 种插值、星对/星数/通道/缩放/钳位和两遍输出范围；5 种叠加方法、7 种剔除算法、5 种归一化选择、4 种权重、剔除图及5项质量筛选。Drizzle / Bayer Drizzle 的6种核、像素比例、输出倍率、主平场初始权重与8/32位权重已接入一遍/两遍流程。所有处理调用固定上游算法；界面参数与输入列表随任务保存，实际执行以 processing.ssf 为准。", "",
          "序列工作区已接入原版逐帧读取、缩放/通道显示、单帧/范围参与切换、参考帧、12种质量/统计轴、原版两遍配准测量、序列统计和CSV；选择/参考帧支持跨重启撤销重做及中断恢复；重新叠加保留旧结果并复用输入。", "",
          "批处理仍缺：其他原版序列交互/测光、PSF/DFT/KOMBAT 配准、畸变/外部参考、合成偏置和 BPM 文件入口、偏移合成/重叠归一化/羽化/叠加时放大，以及全部 GUI 默认值对应。真实相机数据上的坏点修正、X-Trans 和 CFA 均衡仍需专项验证；不能把命令参数接出视为全功能完成。", "",
          "共享分析工作区已接入矩形选区、完整分辨率像素读数、原版 STATS_MAIN 八项统计及归一化/CFA 开关、原版整图/选区直方图和完整文件头查看/搜索/复制。选区目前用于分析；处理 ROI、蒙版、多边形选择、关键字编辑、文件信息编辑和直方图变换仍待移植。", "",
          "背景提取已接入原版采样和图像 hook：增删/选择采样、自动/随机采样、RBF/1–4 阶多项式、减法/除法、抖动、自动渐变完整参数、原图/模型/结果预览与另存。校正结果已支持共享 FITS 撤销/重做；序列应用、拖动采样点和采样/参数编辑撤销仍待补齐。", ""]
(root / "docs/FUNCTIONAL-PARITY.md").write_text("\n".join(lines))
print(f"Inventoried {len(entries)} actions and {len(panels)} UI files")
