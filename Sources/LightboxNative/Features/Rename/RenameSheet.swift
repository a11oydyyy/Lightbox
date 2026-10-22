import AppKit
import SwiftUI

/// Renames one file (its name, with the part before the extension selected)
/// or several (Finder's replace / add / format rules, with a live preview).
struct RenameSheet: View {
    @ObservedObject var appState: AppState
    let request: RenameRequest

    private enum Mode: Hashable { case replace, add, format }

    @State private var name: String
    @State private var mode: Mode = .replace
    @State private var find = ""
    @State private var replacement = ""
    @State private var addition = ""
    @State private var addsAtEnd = true
    @State private var formatName: String
    @State private var startNumber = 1
    @State private var isRenaming = false
    /// Why the last attempt failed on disk; cleared by the next edit.
    @State private var diskIssue: FileRenameIssue?

    init(appState: AppState, request: RenameRequest) {
        self.appState = appState
        self.request = request
        _name = State(initialValue: request.assets.first?.originalName ?? "")
        _formatName = State(initialValue: appState.currentFolderURL.lastPathComponent)
    }

    private var text: RenameText { appState.renameText }
    private var isBatch: Bool { request.assets.count > 1 }

    private var rule: BatchRenameRule {
        switch mode {
        case .replace: .replace(find: find, with: replacement)
        case .add: .add(text: addition, atEnd: addsAtEnd)
        case .format: .format(name: formatName.trimmingCharacters(in: .whitespaces), start: startNumber)
        }
    }

    private var items: [FileRenameItem] {
        let urls = request.assets.compactMap(\.sourceURL)
        let names = isBatch ? FileRenamer.names(for: urls.map(\.lastPathComponent), rule: rule) : [name]
        return zip(urls, names).map { FileRenameItem(url: $0, newName: $1) }
    }

    private var changes: Bool { items.contains { $0.newName != $0.url.lastPathComponent } }
    private var issue: FileRenameIssue? { diskIssue ?? (changes ? FileRenamer.issue(in: items) : nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: RenameSheetMetrics.sectionSpacing) {
            Text(text.title(count: request.assets.count, name: request.assets.first?.originalName ?? ""))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            if isBatch { batchFields } else { singleField }

            footer
        }
        .padding(RenameSheetMetrics.padding)
        .frame(width: RenameSheetMetrics.width)
        .onChange(of: items) { _ in diskIssue = nil }
    }

    private var singleField: some View {
        VStack(alignment: .leading, spacing: 8) {
            RenameNameField(text: $name, onSubmit: submit)
                .frame(height: 22)
                .accessibilityLabel(text.newName)
            let old = FileRenamer.split(request.assets.first?.originalName ?? "").ext
            let new = FileRenamer.split(name).ext
            if issue == nil, old.lowercased() != new.lowercased() {
                note(text.extensionChange(from: old, to: new), isError: false)
            }
        }
    }

    private var batchFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $mode) {
                Text(text.replaceMode).tag(Mode.replace)
                Text(text.addMode).tag(Mode.add)
                Text(text.formatMode).tag(Mode.format)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                switch mode {
                case .replace:
                    row(text.find) { TextField("", text: $find) }
                    row(text.replaceWith) { TextField("", text: $replacement) }
                case .add:
                    row(text.text) { TextField("", text: $addition) }
                    row("") {
                        Picker("", selection: $addsAtEnd) {
                            Text(text.beforeName).tag(false)
                            Text(text.afterName).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                case .format:
                    row(text.customName) { TextField("", text: $formatName) }
                    row(text.startNumber) {
                        TextField("", value: $startNumber, format: .number.grouping(.never))
                            .frame(width: 72)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)

            preview
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(LightboxColorTokens.secondaryText)
                .gridColumnAlignment(.trailing)
            content()
        }
    }

    /// The first few results, old name over new.
    private var preview: some View {
        let shown = items.prefix(RenameSheetMetrics.previewCount)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    Text(item.url.lastPathComponent)
                        .foregroundStyle(LightboxColorTokens.mutedText)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LightboxColorTokens.mutedText)
                    Text(item.newName)
                        .foregroundStyle(LightboxColorTokens.primaryText)
                }
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            }
            if items.count > shown.count {
                Text(text.moreItems(items.count - shown.count))
                    .font(.system(size: 11))
                    .foregroundStyle(LightboxColorTokens.mutedText)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LightboxColorTokens.primaryText.opacity(FileTileMetrics.fillOpacity),
                    in: RoundedRectangle(cornerRadius: RadiusTokens.control, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let issue {
                note(text.message(for: issue), isError: true)
            }
            Spacer(minLength: 0)
            Button(text.cancelButton) { appState.renameRequest = nil }
                .keyboardShortcut(.cancelAction)
            Button(text.renameButton, action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(!changes || issue != nil || isRenaming)
        }
        .controlSize(.regular)
    }

    private func note(_ message: String, isError: Bool) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(isError ? Color(nsColor: .systemRed) : LightboxColorTokens.mutedText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func submit() {
        guard changes, issue == nil, !isRenaming else { return }
        isRenaming = true
        appState.rename(items) { issue in
            isRenaming = false
            if let issue {
                diskIssue = issue
            } else {
                appState.renameRequest = nil
            }
        }
    }
}

/// Renames one folder, its whole name selected.
struct RenameFolderSheet: View {
    @ObservedObject var appState: AppState
    let request: FolderRenameRequest

    @State private var name: String
    @State private var isRenaming = false
    @State private var diskIssue: FileRenameIssue?

    init(appState: AppState, request: FolderRenameRequest) {
        self.appState = appState
        self.request = request
        _name = State(initialValue: request.folder.url.lastPathComponent)
    }

    private var text: RenameText { appState.renameText }
    private var item: FileRenameItem { FileRenameItem(url: request.folder.url, newName: name) }
    private var changes: Bool { name != request.folder.url.lastPathComponent }
    private var issue: FileRenameIssue? { diskIssue ?? (changes ? FileRenamer.issue(in: [item]) : nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: RenameSheetMetrics.sectionSpacing) {
            Text(text.title(count: 1, name: request.folder.url.lastPathComponent))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            RenameNameField(text: $name, selectsWholeName: true, onSubmit: submit)
                .frame(height: 22)
                .accessibilityLabel(text.newName)
            HStack(spacing: 10) {
                if let issue {
                    Text(text.message(for: issue))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(text.cancelButton) { appState.folderRenameRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button(text.renameButton, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!changes || issue != nil || isRenaming)
            }
        }
        .padding(RenameSheetMetrics.padding)
        .frame(width: RenameSheetMetrics.width)
        .onChange(of: name) { _ in diskIssue = nil }
    }

    private func submit() {
        guard changes, issue == nil, !isRenaming else { return }
        isRenaming = true
        appState.renameFolder(item) { issue in
            isRenaming = false
            if let issue {
                diskIssue = issue
            } else {
                appState.folderRenameRequest = nil
            }
        }
    }
}

/// Names a new folder in the folder on screen, then creates it.
struct NewFolderSheet: View {
    @ObservedObject var appState: AppState
    let request: NewFolderRequest

    @State private var name: String
    @State private var isCreating = false
    @State private var diskIssue: FileRenameIssue?

    init(appState: AppState, request: NewFolderRequest) {
        self.appState = appState
        self.request = request
        _name = State(initialValue: appState.renameText.untitledFolder)
    }

    private var text: RenameText { appState.renameText }
    private var issue: FileRenameIssue? { diskIssue ?? FileRenamer.issue(inName: name) }

    var body: some View {
        VStack(alignment: .leading, spacing: RenameSheetMetrics.sectionSpacing) {
            Text(text.newFolderTitle(in: request.parent.lastPathComponent))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            RenameNameField(text: $name, selectsWholeName: true, onSubmit: submit)
                .frame(height: 22)
                .accessibilityLabel(text.newName)
            HStack(spacing: 10) {
                if let issue {
                    Text(text.message(for: issue))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(text.cancelButton) { appState.newFolderRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button(text.createButton, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(issue != nil || isCreating)
            }
        }
        .padding(RenameSheetMetrics.padding)
        .frame(width: RenameSheetMetrics.width)
        .onChange(of: name) { _ in diskIssue = nil }
    }

    private func submit() {
        guard issue == nil, !isCreating else { return }
        isCreating = true
        appState.createFolder(named: name, in: request.parent) { issue in
            isCreating = false
            if let issue {
                diskIssue = issue
            } else {
                appState.newFolderRequest = nil
            }
        }
    }
}

enum RenameSheetMetrics {
    static let width: CGFloat = 440
    static let padding: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
    static let previewCount = 3
}

/// A text field that starts focused with the name before its extension
/// selected (or all of it), as Finder does, and submits on Return.
private struct RenameNameField: NSViewRepresentable {
    @Binding var text: String
    var selectsWholeName = false
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 13)
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        let base = selectsWholeName ? text : FileRenamer.split(text).base
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base as NSString).length)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameNameField
        init(_ parent: RenameNameField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }
}
