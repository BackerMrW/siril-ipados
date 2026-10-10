// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import SirilCore

struct LicenseDocument: Identifiable {
    let url: URL
    let title: String
    var id: URL { url }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var document: LicenseDocument?
    private var licenses: [LicenseDocument] {
        guard let root = Bundle.main.url(forResource: "ThirdPartyLicenses", withExtension: nil),
              let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return files.compactMap { element -> LicenseDocument? in
            guard let url = element as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return LicenseDocument(url: url, title: String(url.path.dropFirst(root.path.count + 1)))
        }.sorted { $0.title < $1.title }
    }
    var body: some View {
        NavigationStack {
            List {
                Section("Siril iPad " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")) {
                    Text(String(cString: siril_core_version()))
                    Text("原始 Siril 内核与 SwiftUI 原生界面，在 iPad 本地处理天文图像。")
                    Link("项目源码与构建脚本", destination: URL(string: "https://github.com/BackerMrW/siril-ipados")!)
                    Link("版本下载与完整源码包", destination: URL(string: "https://github.com/BackerMrW/siril-ipados/releases")!)
                    Link("Siril 上游项目", destination: URL(string: "https://gitlab.com/free-astro/siril")!)
                    if let url = Bundle.main.url(forResource: "LICENSE", withExtension: "md") {
                        Button("GNU GPL 第 3 版") { document = LicenseDocument(url: url, title: "GNU GPL 第 3 版") }
                    }
                }
                Section("开源组件许可与版权") {
                    ForEach(licenses) { license in Button(license.title) { document = license } }
                }
            }
            .navigationTitle("关于与源码")
            .toolbar { Button("完成") { dismiss() } }
            .sheet(item: $document) { license in
                LicenseView(document: license)
            }
        }
    }
}

struct LicenseView: View {
    let document: LicenseDocument
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    var body: some View {
        NavigationStack {
            ScrollView { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding() }
                .navigationTitle(document.title)
                .toolbar { Button("完成") { dismiss() } }
                .task { text = (try? String(contentsOf: document.url, encoding: .utf8)) ?? "无法读取此文件" }
        }
    }
}
