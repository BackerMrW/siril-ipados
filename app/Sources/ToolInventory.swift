// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct UpstreamFeature: Decodable, Identifiable {
    let id: String
    let title: String
    let group: String
    let status: String
}
struct UpstreamInventory: Decodable {
    let entries: [UpstreamFeature]
    static var bundled: [UpstreamFeature] {
        guard let url = Bundle.main.url(forResource: "UpstreamFeatures", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return [] }
        return value.entries
    }
}

struct ToolInventoryView: View {
    let onBackground: () -> Void
    let onProcessing: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private let features = UpstreamInventory.bundled
    private var filtered: [UpstreamFeature] {
        features.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section("已接入的入口") {
                    Button("背景提取 · Background Extraction") { dismiss(); onBackground() }
                    Button("批处理与单张工具") { dismiss(); onProcessing() }
                }
                Section("原版功能对应情况") {
                    Text("下面按所移植的 Siril 1.5 源码列出原版动作。当前版本仍在移植，未完成的工具会显示真实状态。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(filtered) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.title).font(.headline)
                            Text(entry.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Link("查看完整功能核对表", destination: URL(string: "https://github.com/BackerMrW/siril-ipados/blob/main/docs/FUNCTIONAL-PARITY.md")!)
                }
            }
            .searchable(text: $query, prompt: "搜索原版工具")
            .navigationTitle("Siril 图像处理与分析")
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}
