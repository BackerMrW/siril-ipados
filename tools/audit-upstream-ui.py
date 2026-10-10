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
    state = "交互界面已接入（序列应用仍待接入）" if action == "win.background-extr-processing" else "简化参数界面，未达到原版完整功能" if action.removeprefix("win.") in partial else "待移植或待逐项验证"
    entries.append({"id": action, "title": title, "group": group, "status": state})

value = {"upstreamRevision": "6c0f8f3207b9cb712f7e04249217123a8ca66915", "entries": entries,
         "panels": panels, "note": "Every status requires parameter, interaction, algorithm, and device verification. A command catalog is not a completion claim."}
out = root / "app/Resources/UpstreamFeatures.json"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
lines = ["# Siril iPad 完整移植核对表", "", "目标是原版功能、参数、图像交互和文件格式完整对应。当前 App 尚未达到该目标。", "",
         "固定原版源码：`" + value["upstreamRevision"] + "`（1.5 开发版）。不是与用户电脑上的任意版本自动一致。", "",
         f"从原版主窗口提取 {len(entries)} 个不同动作，扫描 {len(panels)} 个 UI 文件；控件、信号、范围和默认值记录在 `app/Resources/UpstreamFeatures.json`。",
         "这是自动发现的基线，不能替代代码路径、插件、脚本、序列以及实际交互核对。", "",
         "## 当前必须补齐的跨工具能力", "",
         "- 原版工作区：颜色通道、显示模式、直方图、像素读数、矩形/多边形选择、ROI、撤销重做、蒙版及对比预览。",
         "- 序列：浏览/排除帧、质量图、全部配准模式与参数、叠加方法/归一化/剔除和校准高级参数。",
         "- 颜色与分析：PCC/SPCC、星表/联网、解算与标注、测光与光变、PSF、像差/倾斜及图像统计。",
         "- 完整单张工具：原版每个工具的参数、交互输入、应用/取消、作用于序列、蒙版和预览。",
         "- 格式和依赖：RAW、TIFF、JPEG、PNG、HEIF、JPEG XL、XISF、FFmpeg/FFMS2、curl/SQLite。当前对应 Siril 构建选项关闭。",
         "- 平台接口：StarNet 等外部程序、Python/插件、在线下载、文件权限、内存、后台生命周期。需要真正适配，不能把空按钮算完成。",
         "", "## 原版动作逐项状态", "", "| 原版动作 | 名称 | 当前状态 |", "| --- | --- | --- |"]
for entry in entries:
    lines.append("| " + entry["id"] + " | " + entry["title"].replace("|", "/").replace("\n", " ") + " | " + entry["status"] + " |")
lines += ["", "## 完成标准", "", "每项需有原版入口对应、参数与默认值对应、真实算法输出校验、原生交互校验和 iPad 验证记录。未通过者保持未完成。",
          "背景提取已接入原版采样和图像 hook：增删/选择采样、自动/随机采样、RBF/1–4 阶多项式、减法/除法、抖动、自动渐变完整参数、原图/模型/结果预览与另存。序列应用、拖动采样点和共享撤销仍待补齐。", ""]
(root / "docs/FUNCTIONAL-PARITY.md").write_text("\n".join(lines))
print(f"Inventoried {len(entries)} actions and {len(panels)} UI files")
