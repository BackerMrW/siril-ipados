// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import SirilCore

struct StarAnalysisView: View {
    let file: FITSRecord
    @Binding var selection: ImageSelection?
    @Environment(\.dismiss) private var dismiss
    @State private var engine = ImageAnalysisEngine()
    @State private var image: UIImage?
    @State private var edit = StarEdit()
    @State private var history: StarHistory?
    @State private var selected: Set<UUID> = []
    @State private var selecting = true
    @State private var automatic = true
    @State private var busy = false
    @State private var message = ""
    @State private var sortColumn = 9
    @State private var ascending = true
    @State private var exports: [URL] = []
    @State private var summary = ""
    private let columns = ["Channel", "B", "A", "x0", "y0", "RA", "Dec", "FWHMx px", "FWHMy px", "Mag", "Beta", "r", "Angle °", "RMSE"]
    private var sorted: [StarMeasurement] {
        edit.stars.sorted { a, b in
            if a.fields[sortColumn] == b.fields[sortColumn] { return a.id.uuidString < b.id.uuidString }
            return ascending ? a.fields[sortColumn] < b.fields[sortColumn] : a.fields[sortColumn] > b.fields[sortColumn]
        }
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                Group {
                    if geometry.size.width > 800 {
                        HStack(spacing: 0) { imagePanel; controls.frame(width: 420) }
                    } else { VStack(spacing: 0) { imagePanel.frame(height: geometry.size.height * 0.4); controls } }
                }
            }
            .navigationTitle("动态 PSF 与测光").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(busy) } }
            .task { await open() }
            .onChange(of: automatic) { _, _ in Task { await preview() } }
            .onChange(of: edit.settings.channel) { _, _ in Task { await preview() } }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }
    private var imagePanel: some View {
        VStack(spacing: 8) {
            if let image {
                ZoomableImageCanvas(image: image, samples: edit.stars.enumerated().map { i, star in
                    SampleMarker(id: i, x: star.x, y: star.y, size: max(star.fwhmX, star.fwhmY) * 3, median: [])
                }, imageWidth: Double(file.width), imageHeight: Double(file.height),
                    selected: edit.stars.firstIndex { selected.contains($0.id) }, region: selection,
                    selecting: selecting && !busy,
                    onSelection: { selection = $0 }, onTap: { x, y in
                        guard !busy else { return }
                        if let star = edit.stars.min(by: { hypot($0.x - x, $0.y - y) < hypot($1.x - x, $1.y - y) }),
                           hypot(star.x - x, star.y - y) <= max(10, star.fwhmX * 2) { selected = [star.id] }
                    }).background(.black)
            } else { ProgressView("读取原始图像").frame(maxWidth: .infinity, maxHeight: .infinity) }
            HStack { Toggle("框选星点", isOn: $selecting); Toggle("自动拉伸", isOn: $automatic) }.padding(.horizontal).disabled(busy)
            Text(selection?.description ?? "整图检测 · 框选后可拟合单颗星")
                .font(.caption.monospaced())
            HStack {
                Button("清除选区") { selection = nil }.disabled(busy || selection == nil)
                Button("撤销") { stepHistory(redo: false) }.disabled(busy || history?.past.isEmpty != false)
                Button("重做") { stepHistory(redo: true) }.disabled(busy || history?.future.isEmpty != false)
            }
            Text("单指框选，双指缩放和平移；轻点星点选中对应行。坐标为像素中心，首个像素中心为 0.5。")
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
        }
    }
    private var controls: some View {
        Form {
            StarSettingsControls(settings: $edit.settings, channels: file.channels).disabled(busy)
            Section("计算") {
                Button("检测选区 / 整图星点") { Task { await calculate(find: true) } }
                Button(edit.settings.photometry ? "拟合选区并进行测光" : "拟合选区星点") { Task { await calculate(find: false) } }.disabled(selection == nil)
                Button("恢复原版默认参数") { edit.settings = StarSettings() }
            }.disabled(busy)
            Section("星表 · \(edit.stars.count) 颗") {
                HStack { Button("全选") { selected = Set(edit.stars.map(\.id)) }; Button("取消选择") { selected = [] } }
                HStack {
                    Button("删除所选", role: .destructive) { removeSelected() }.disabled(selected.isEmpty)
                    Button("清空星表", role: .destructive) { selected = Set(edit.stars.map(\.id)); removeSelected() }.disabled(edit.stars.isEmpty)
                }
                Button("所选星点平均 PSF") { averageSelected() }.disabled(selected.isEmpty)
                if !summary.isEmpty { Text(summary).font(.caption.monospaced()).textSelection(.enabled) }
                ScrollView(.horizontal) {
                    VStack(alignment: .leading) {
                        HStack(spacing: 0) {
                            Text("选择").frame(width: 44)
                            ForEach(columns.indices, id: \.self) { i in Button(columns[i]) {
                                if sortColumn == i { ascending.toggle() } else { sortColumn = i; ascending = true }
                            }.frame(width: 92) }
                        }
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(sorted) { star in
                                    HStack(spacing: 0) {
                                        Button(selected.contains(star.id) ? "☑" : "☐") {
                                            if selected.contains(star.id) { selected.remove(star.id) } else { selected.insert(star.id) }
                                        }.frame(width: 44)
                                        ForEach(columns.indices, id: \.self) { i in
                                            Text((i == 5 || i == 6) && !star.hasWCS ? "--" : String(format: "%.6g", star.fields[i])).frame(width: 92)
                                        }
                                    }.foregroundStyle(selected.contains(star.id) ? Color.yellow : Color.primary)
                                }
                            }
                        }.frame(height: 180)
                    }.font(.system(size: 11, design: .monospaced))
                }
                if let star = edit.stars.first(where: { selected.contains($0.id) }) { starDetails(star) }
            }.disabled(busy)
            Section("保存与导出") {
                Button("保存参数与星表") { commit(edit) }
                Button("复制 CSV") { UIPasteboard.general.string = csv }
                Button("导出 CSV、原版 .lst 与 FITS 星表") { Task { await export() } }.disabled(edit.stars.isEmpty)
                ForEach(exports, id: \.self) { url in ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "square.and.arrow.up") } }
                Text("编辑记录保存在源文件的 stars.json；撤销/重做跨关闭保留，随源文件删除和恢复。导出位于“文件”中的 Siril iPad / Exports。")
                    .font(.caption2).foregroundStyle(.secondary)
            }.disabled(busy)
            if busy { Section { ProgressView("原版 Siril 正在计算") } }
            if !message.isEmpty { Section { Text(message).foregroundStyle(.red).textSelection(.enabled) } }
        }
    }
    private func starDetails(_ star: StarMeasurement) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("FWHM：\(String(format: "%.5f × %.5f px", star.fwhmX, star.fwhmY))")
            if star.angularX > 0 && star.angularY > 0 { Text(String(format: "角半高宽：%.5f × %.5f arcsec", star.angularX, star.angularY)) }
            Text(star.photometryValid ? String(format: "有效孔径测光：m=%.6f ± %.6f，SNR=%.4f dB", star.magnitude, star.magnitudeError, star.snr) : "无有效孔径测光；表中 Mag 为拟合/像素估算星等。")
            if star.photometryError != 0 { Text("原版测光状态：" + String(cString: siril_psf_error_message(Int32(star.photometryError)))) }
            if star.saturated { Text("饱和星：平均 PSF 时排除。") }
        }.font(.caption).textSelection(.enabled)
    }
    private var csv: String {
        var lines = ["# source=\(file.displayName.replacingOccurrences(of: "\n", with: " ")) id=\(file.id)"]
        lines.append(columns.joined(separator: ",") + ",angular_x_arcsec,angular_y_arcsec,saturated,photometry_valid,magnitude_error,snr_dB,photometry_error")
        for star in sorted {
            let extra: [Double] = [star.angularX, star.angularY, star.saturated ? 1.0 : 0.0,
                star.photometryValid ? 1.0 : 0.0, star.magnitudeError, star.snr, Double(star.photometryError)]
            let values: [Double] = star.fields + extra
            let row = values.map { String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: ",")
            lines.append(row)
        }
        return lines.joined(separator: "\n") + "\n"
    }
    @MainActor private func commit(_ value: StarEdit) {
        guard var h = history else { return }
        h.record(value)
        do { try h.save(for: file); history = h; edit = value; summary = "" }
        catch { message = error.localizedDescription }
    }
    @MainActor private func stepHistory(redo: Bool) {
        guard var h = history else { return }
        if redo { h.redo() } else { h.undo() }
        do { try h.save(for: file); history = h; edit = h.current; selected = []; summary = ""; Task { await preview() } }
        catch { message = error.localizedDescription }
    }
    @MainActor private func removeSelected() { var value = edit; value.stars.removeAll { selected.contains($0.id) }; commit(value); selected = [] }
    @MainActor private func averageSelected() {
        let rows = edit.stars.filter { selected.contains($0.id) }, valid = rows.filter { !$0.saturated }
        guard let first = valid.first else { message = "所选星点均已饱和或没有选择"; return }
        guard rows.allSatisfy({ $0.channel == first.channel && $0.profile == first.profile && ($0.angularX > 0) == (first.angularX > 0) }) else { message = "原版平均 PSF 要求相同通道、模型与单位"; return }
        func mean(_ key: KeyPath<StarMeasurement, Double>) -> Double { valid.map { $0[keyPath: key] }.reduce(0, +) / Double(valid.count) }
        let fx = mean(\.fwhmX), fy = mean(\.fwhmY)
        summary = String(format: "有效 %d / %d · B=%.6g A=%.6g\nFWHM=%.5f × %.5f px · r=%.5f\nAngle=%.5f° β=%.5f RMSE=%.5g", valid.count, rows.count, mean(\.background), mean(\.amplitude), fx, fy, fy / fx, mean(\.angle), mean(\.beta), mean(\.rmse))
        if first.angularX > 0 { summary += String(format: "\nFWHM=%.5f × %.5f arcsec", mean(\.angularX), mean(\.angularY)) }
    }
    @MainActor private func open() async {
        busy = true; defer { busy = false }
        do {
            _ = try await engine.open(file.url)
            history = try StarHistory.load(for: file); edit = history!.current
            image = try await engine.preview(channel: edit.settings.channel, automatic: automatic).uiImage
            if ProcessInfo.processInfo.environment["SIRIL_ANALYSIS_VIEW_CHECK"] == "1" {
                guard let region = selection else { throw EngineError.failed("Missing star selection") }
                var value = edit; value.stars = [try await engine.fitStar(region: region, settings: edit.settings)]
                commit(value); selected = Set(value.stars.map(\.id))
                guard image != nil else { throw EngineError.failed("PSF view missing source image") }
                let marker = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("simulator-analysis-ready.txt")
                try "PASS: native analysis workspace tab 3 loaded original star fit, overlays, parameters and star table.\n".write(to: marker, atomically: true, encoding: .utf8)
            }
        } catch { message = error.localizedDescription }
    }
    @MainActor private func preview() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { image = try await engine.preview(channel: edit.settings.channel, automatic: automatic).uiImage }
        catch { message = error.localizedDescription }
    }
    @MainActor private func calculate(find: Bool) async {
        guard !busy else { return }; busy = true; message = ""
        UIApplication.shared.isIdleTimerDisabled = true
        defer { busy = false; UIApplication.shared.isIdleTimerDisabled = false }
        do {
            var value = edit
            if find { value.stars = try await engine.findStars(region: selection, settings: edit.settings) }
            else if let region = selection { value.stars.append(try await engine.fitStar(region: region, settings: edit.settings)) }
            commit(value); selected = value.stars.last.map { [$0.id] } ?? []
        } catch { message = error.localizedDescription }
    }
    @MainActor private func export() async {
        guard !busy else { return }; busy = true; message = ""; defer { busy = false }
        var written: [URL] = []
        do {
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Exports")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let base = root.appendingPathComponent("dynamic-psf-" + UUID().uuidString)
            let csvURL = base.appendingPathExtension("csv"); try csv.write(to: csvURL, atomically: true, encoding: .utf8); written.append(csvURL)
            for table in [false, true] {
                let url = base.appendingPathExtension(table ? "fits" : "lst")
                try await engine.saveStars(sorted, settings: edit.settings, to: url, fitsTable: table); written.append(url)
            }
            exports = written; commit(edit)
        } catch { for url in written { try? FileManager.default.removeItem(at: url) }; message = error.localizedDescription }
    }
}
