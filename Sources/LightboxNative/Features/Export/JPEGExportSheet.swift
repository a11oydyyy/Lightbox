import AppKit
import SwiftUI

/// Bridge's Image Processor, in short: where the JPEGs go, their quality,
/// sRGB and an optional long edge. Photoshop does the work
/// (`PhotoshopJPEGExport`); the last choices are kept.
struct JPEGExportSheet: View {
    @ObservedObject var appState: AppState
    let request: JPEGExportRequest

    private enum Destination: Hashable { case subfolder, folder, choose }

    @State private var options: JPEGExportOptions
    @State private var destination: Destination
    @State private var limitsLongEdge: Bool
    @State private var longEdge: Int

    init(appState: AppState, request: JPEGExportRequest) {
        self.appState = appState
        self.request = request
        let saved = JPEGExportOptions.load(defaults: appState.libraryDefaults)
        _options = State(initialValue: saved)
        _destination = State(initialValue: saved.folderPath == nil ? .subfolder : .folder)
        _limitsLongEdge = State(initialValue: saved.longEdge != nil)
        _longEdge = State(initialValue: saved.longEdge ?? 2048)
    }

    private var text: ExportText { appState.exportText }

    var body: some View {
        VStack(alignment: .leading, spacing: RenameSheetMetrics.sectionSpacing) {
            Text(text.title(count: request.assets.count, name: request.assets.first?.originalName ?? ""))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    label(text.location)
                    Picker("", selection: $destination) {
                        Text(text.subfolder(options.subfolderName)).tag(Destination.subfolder)
                        if let folderPath = options.folderPath {
                            Text(FileManager.default.displayName(atPath: folderPath)).tag(Destination.folder)
                        }
                        Divider()
                        Text(text.chooseFolder).tag(Destination.choose)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: destination) { choice in
                        if choice == .choose { chooseFolder() }
                    }
                }
                GridRow {
                    label(text.quality)
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { Double(options.quality) },
                                              set: { options.quality = Int($0.rounded()) }),
                               in: 0...12, step: 1)
                        // Sized for the longest value, so the slider never moves.
                        ZStack(alignment: .leading) {
                            Text(text.qualityValue(12)).hidden()
                            Text(text.qualityValue(options.quality))
                        }
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(LightboxColorTokens.secondaryText)
                        .lineLimit(1)
                        .fixedSize()
                    }
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(text.convertToSRGB, isOn: $options.convertsToSRGB)
                        HStack(spacing: 6) {
                            Toggle(text.limitLongEdge, isOn: $limitsLongEdge)
                            TextField("", value: $longEdge, format: .number.grouping(.never))
                                .frame(width: 64)
                                .multilineTextAlignment(.trailing)
                                .disabled(!limitsLongEdge)
                            Text(text.pixels)
                                .foregroundStyle(limitsLongEdge ? LightboxColorTokens.secondaryText : LightboxColorTokens.mutedText)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                }
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(text.cancelButton) { appState.jpegExportRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button(text.exportButton, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(limitsLongEdge && longEdge < 1)
            }
            .controlSize(.regular)
        }
        .padding(RenameSheetMetrics.padding)
        .frame(width: RenameSheetMetrics.width)
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(LightboxColorTokens.secondaryText)
            .gridColumnAlignment(.trailing)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = text.exportButton
        panel.directoryURL = options.folderPath.map { URL(fileURLWithPath: $0) }
            ?? request.assets.first?.sourceURL?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            options.folderPath = url.standardizedFileURL.path
            destination = .folder
        } else {
            destination = options.folderPath == nil ? .subfolder : .folder
        }
    }

    private func submit() {
        var chosen = options
        if destination == .subfolder { chosen.folderPath = nil }
        chosen.longEdge = limitsLongEdge ? max(1, longEdge) : nil
        appState.exportJPEG(request, options: chosen)
    }
}
