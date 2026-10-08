import AppKit
import SwiftUI

struct ImageAnalysisPanel: View {
    @ObservedObject var model: ImageAnalysisModel
    @State private var unavailableReason = ImageAnalysisService.modelUnavailableReason

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.targets.isEmpty ? "先在图库中选择图片" : "已选择 \(model.targets.count) 张图片")
                    .font(.headline)
                Spacer()
                if model.isRunning {
                    ProgressView().controlSize(.small)
                    Button("取消") { model.cancel() }
                } else {
                    Button("识别文字") { model.run(.text) }.disabled(model.targets.isEmpty)
                    Button("生成描述与标签") { model.run(.describe) }
                        .disabled(model.targets.isEmpty || unavailableReason != nil)
                }
            }
            if let unavailableReason { Text(unavailableReason).font(.callout).foregroundStyle(.secondary) }
            if !model.progress.isEmpty { Text(model.progress).font(.callout).foregroundStyle(.secondary) }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            TextField("搜索已分析图片的名称、标签或文字", text: $model.query)
                .textFieldStyle(.roundedBorder)
            List(model.visibleRecords) { record in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(record.name).font(.headline).lineLimit(1)
                        Spacer()
                        Button("复制") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(([record.result.summary, record.result.tags.joined(separator: "、"), record.result.text]
                                .filter { !$0.isEmpty }).joined(separator: "\n\n"), forType: .string)
                        }
                        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.path)]) }
                    }
                    Text(record.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if !record.result.summary.isEmpty { Text(record.result.summary).textSelection(.enabled) }
                    if !record.result.tags.isEmpty { Text(record.result.tags.joined(separator: " · ")).foregroundStyle(.secondary).textSelection(.enabled) }
                    if !record.result.text.isEmpty { Text(record.result.text).textSelection(.enabled) }
                    if record.result.summary.isEmpty && record.result.text.isEmpty { Text("未识别到文字").foregroundStyle(.secondary) }
                }
                .padding(.vertical, 8)
            }
            .overlay {
                if model.visibleRecords.isEmpty {
                    Text(model.query.isEmpty ? "分析结果会保存在这里" : "没有匹配的分析结果").foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            unavailableReason = ImageAnalysisService.modelUnavailableReason
        }
        .onDisappear { model.cancel() }
    }
}
