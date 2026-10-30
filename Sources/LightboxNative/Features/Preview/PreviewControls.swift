import SwiftUI

struct PreviewControls: View {
    @EnvironmentObject private var appState: AppState
    var asset: LightboxAsset
    @LightboxViewState private var metadata: PreviewMetadata?
    @LightboxViewState private var metadataID = ""
    @Binding var showsInfo: Bool
    /// Shows the image at 100%; nil for files without full pixels to show.
    var onZoom: (() -> Void)? = nil

    private var loadID: String { "\(asset.id)|\(asset.contentModifiedAt?.timeIntervalSince1970 ?? 0)|\(asset.fileSize ?? 0)" }
    private var details: PreviewMetadata? { metadataID == loadID ? metadata : nil }


    private var colorTags: [MacColorTag] {
        MacColorTag.all.filter { asset.tags.contains($0.name) }
    }

    var body: some View {
        // Three lines at most (name, capture, file) so the block fits the
        // space PreviewGeometry leaves below the image and never rides up onto it.
        VStack(spacing: 3) {
            HStack(spacing: 8) {
                Text(asset.originalName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LightboxColorTokens.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if !colorTags.isEmpty {
                    HStack(spacing: MacTagDotMetrics.previewInfoSpacing) {
                        ForEach(colorTags) { tag in
                            Circle()
                                .fill(tag.color.opacity(0.94))
                                .frame(
                                    width: MacTagDotMetrics.previewInfoDotDiameter,
                                    height: MacTagDotMetrics.previewInfoDotDiameter
                                )
                                .overlay {
                                    Circle()
                                        .stroke(.white.opacity(0.48), lineWidth: MacTagDotMetrics.previewInfoStrokeWidth)
                                }
                                .accessibilityLabel(tag.name)
                        }
                    }
                    .fixedSize()
                }
                Button { showsInfo.toggle() } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: LightboxControlMetrics.iconSize, weight: .medium))
                        .frame(width: LightboxControlMetrics.iconButtonSize, height: LightboxControlMetrics.iconButtonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(LightboxButtonHoverStyle(shape: RoundedRectangle(cornerRadius: LightboxControlMetrics.cornerRadius)))
                .help(localized("Image information"))
                .accessibilityLabel(localized("Image information"))
                .popover(isPresented: $showsInfo, arrowEdge: .bottom) { informationPanel }
                if let onZoom {
                    Button(action: onZoom) {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.system(size: LightboxControlMetrics.iconSize, weight: .medium))
                            .frame(width: LightboxControlMetrics.iconButtonSize, height: LightboxControlMetrics.iconButtonSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(LightboxButtonHoverStyle(shape: RoundedRectangle(cornerRadius: LightboxControlMetrics.cornerRadius)))
                    .help(CullText(appState.appLanguage).zoomButton)
                    .accessibilityLabel(CullText(appState.appLanguage).zoomButton)
                }
            }
            if let captureLine {
                HStack(spacing: 6) {
                    captureLine
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(LightboxColorTokens.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if details?.hasCameraRawSettings == true {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(LightboxColorTokens.secondaryText)
                            .help(localized("Edited in Camera Raw"))
                            .accessibilityLabel(localized("Edited in Camera Raw"))
                    }
                }
            }
            Text(summary)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(LightboxColorTokens.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(minWidth: 188, maxWidth: 560, alignment: .center)
        .padding(.horizontal, 22)
        .padding(.vertical, 2)
        .task(id: loadID) {
            let id = loadID
            metadata = nil
            metadataID = id
            guard let url = asset.sourceURL else { metadata = PreviewMetadata(); return }
            let work = Task.detached(priority: .utility) { PreviewMetadata.read(url: url) }
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: { work.cancel() }
            guard !Task.isCancelled, id == loadID else { return }
            metadata = result
        }
    }

    private var summary: String { asset.fileSummaryText }

    /// "Sony ILCE-7CM2 · ƒ/4 · 1/1250 s · ISO 250 · 44 mm", camera in bold.
    /// A line of its own made the block too tall for the space below the image.
    private var captureLine: Text? {
        let camera = details?.capture.first(where: { $0.label == "Camera" })?.value ?? ""
        let exposure = details?.exposureSummary ?? ""
        let showsCameraRaw = details?.hasCameraRawSettings == true
        guard !camera.isEmpty || !exposure.isEmpty || showsCameraRaw else { return nil }
        var line = Text(camera).fontWeight(.semibold).foregroundColor(LightboxColorTokens.primaryText)
        if !camera.isEmpty, !exposure.isEmpty { line = line + Text(" · ") }
        line = line + Text(exposure)
        if camera.isEmpty, exposure.isEmpty { line = Text(localized("Edited in Camera Raw")) }
        return line
    }

    private var informationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized("Image information")).font(.headline)
            Text(asset.originalName).font(.subheadline).textSelection(.enabled)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let details {
                        if !details.capture.isEmpty { section("Capture", entries: details.capture) }
                        section("Image", entries: [.init(label: "Dimensions", value: dimensionsText),
                            .init(label: "Megapixels", value: "\(PreviewMetadata.decimal(Double(asset.width * asset.height) / 1_000_000)) MP")] + details.image)
                        if !details.file.isEmpty { section("File", entries: details.file) }
                        if !asset.tags.isEmpty { section("Tags", entries: [.init(label: "Tags", value: asset.tags.map { appState.localizedColorTagName($0) }.joined(separator: ", "))]) }
                        if !details.imagePropertiesAvailable {
                            Text(localized("No embedded image metadata available"))
                                .font(.caption).foregroundStyle(LightboxColorTokens.secondaryText)
                        }
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 380, height: 460)
    }

    private func section(_ title: String, entries: [PreviewMetadata.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(localized(title)).font(.system(size: 12, weight: .semibold))
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: 12) {
                    Text(localized(entry.label)).foregroundStyle(LightboxColorTokens.secondaryText).frame(width: 92, alignment: .leading)
                    Text(localized(entry.value)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func localized(_ key: String) -> String {
        let labels: [String: (String, String, String)] = [
            "Image information": ("图片信息", "画像情報", "圖片信息"), "Capture": ("拍摄信息", "撮影情報", "拍攝信息"),
            "Image": ("图像规格", "画像仕様", "圖像規格"), "File": ("文件信息", "ファイル情報", "檔案信息"),
            "Camera": ("相机", "カメラ", "相機"), "Lens": ("镜头", "レンズ", "鏡頭"), "Aperture": ("光圈", "絞り", "光圈"),
            "Shutter": ("快门", "シャッター", "快門"), "Sensitivity": ("感光度", "ISO感度", "感光度"),
            "Focal length": ("焦距", "焦点距離", "焦距"), "35 mm equivalent": ("35 mm 等效", "35 mm 換算", "35 mm 等效"),
            "Exposure bias": ("曝光补偿", "露出補正", "曝光補償"), "Captured": ("拍摄时间", "撮影日時", "拍攝時間"),
            "Color profile": ("色彩配置", "カラープロファイル", "色彩配置"), "Color model": ("色彩模型", "カラーモデル", "色彩模型"),
            "Bit depth": ("位深", "ビット深度", "位深"), "Print resolution": ("打印分辨率", "印刷解像度", "列印解析度"),
            "Software": ("处理软件", "ソフトウェア", "處理軟體"), "Author": ("作者", "作成者", "作者"),
            "Copyright": ("版权", "著作権", "版權"), "Format": ("格式", "形式", "格式"), "File size": ("文件大小", "ファイルサイズ", "檔案大小"),
            "Created": ("创建时间", "作成日時", "建立時間"), "Modified": ("修改时间", "変更日時", "修改時間"),
            "Path": ("完整路径", "パス", "完整路徑"), "Dimensions": ("像素尺寸", "ピクセル寸法", "像素尺寸"),
            "Megapixels": ("像素总量", "画素数", "像素總量"), "Tags": ("标签", "タグ", "標籤"),
            "Has develop settings": ("已调整", "現像設定あり", "已調整"),
            "Edited in Camera Raw": ("已在 Camera Raw 中调整", "Camera Raw で調整済み", "已在 Camera Raw 中調整"),
            "No embedded image metadata available": ("未读取到内嵌图像元数据", "埋め込み画像メタデータを取得できません", "未讀取到內嵌圖像中繼資料")
        ]
        guard let value = labels[key] else { return key }
        switch appState.appLanguage.resolved {
        case .english: return key
        case .simplifiedChinese: return value.0
        case .traditionalChinese: return value.2
        case .japanese: return value.1
        }
    }

    private var dimensionsText: String { asset.dimensionsText }
}

extension LightboxAsset {
    /// "6,000 × 4,000 px", as the preview and comparison show it.
    var dimensionsText: String {
        func formatted(_ value: CGFloat) -> String { Int(value).formatted(.number.grouping(.automatic)) }
        return "\(formatted(width)) × \(formatted(height)) px"
    }

    /// "6,000 × 4,000 px · JPG · 10.4 MB".
    var fileSummaryText: String {
        var values = [dimensionsText]
        if let ext = sourceURL?.pathExtension, !ext.isEmpty { values.append(ext.uppercased()) }
        if let fileSize { values.append(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)) }
        return values.joined(separator: " · ")
    }
}
