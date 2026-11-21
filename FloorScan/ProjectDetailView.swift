import SwiftUI
import UIKit

struct ProjectDetailView: View {
    @ObservedObject var project: ProjectHandle
    @State private var resolution: Double = 2.0
    @State private var rendering = false
    @State private var info: MosaicInfo?
    @State private var errorText: String?
    @State private var zipURL: URL?
    @State private var zipping = false

    private var pngURL: URL { project.outputDir.appendingPathComponent(MosaicRenderer.pngName) }
    private var pdfURL: URL { project.outputDir.appendingPathComponent(MosaicRenderer.pdfName) }

    var body: some View {
        List {
            Section("掃描資訊") {
                LabeledContent("照片", value: "\(project.model.photos.count) 張")
                LabeledContent("建立時間", value: project.model.created.formatted(date: .abbreviated, time: .shortened))
                if project.model.floorY == nil {
                    Text("這次掃描沒有設定地板，無法產生平面圖").foregroundStyle(.red)
                }
            }

            Section {
                Picker("解析度", selection: $resolution) {
                    Text("1 mm/px（最清楚，較慢）").tag(1.0)
                    Text("2 mm/px（建議）").tag(2.0)
                    Text("4 mm/px（較快）").tag(4.0)
                }
                Button {
                    render()
                } label: {
                    HStack {
                        Text(rendering ? "產生中…" : (info == nil ? "產生平面圖" : "重新產生平面圖"))
                        if rendering { Spacer(); ProgressView() }
                    }
                }
                .disabled(rendering || project.model.photos.isEmpty || project.model.floorY == nil)

                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }

                if let info, !rendering {
                    NavigationLink("檢視平面圖") {
                        ZoomableImageView(url: pngURL)
                            .ignoresSafeArea(edges: .bottom)
                            .navigationTitle("平面圖")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    ShareLink(item: pngURL) { Label("分享 / 儲存 PNG", systemImage: "photo") }
                    ShareLink(item: pdfURL) { Label("分享 / 儲存 PDF（A3 比例圖）", systemImage: "doc.richtext") }
                    Text(info.summary).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("平面圖")
            } footer: {
                Text("平面圖方向以開始掃描時手機的朝向為準。格線間距 1 公尺。")
            }

            Section {
                Button {
                    exportZip()
                } label: {
                    HStack {
                        Text("打包原始資料（照片＋定位）")
                        if zipping { Spacer(); ProgressView() }
                    }
                }
                .disabled(zipping)
                if let zipURL {
                    ShareLink(item: zipURL) { Label("分享 zip", systemImage: "archivebox") }
                }
            } header: {
                Text("原始資料")
            } footer: {
                Text("需要協助除錯或改善成果時，可以把 zip 傳給開發者。")
            }
        }
        .navigationTitle(project.model.name)
        .onAppear {
            if info == nil { info = MosaicRenderer.loadInfo(projectDir: project.dir) }
        }
    }

    private func render() {
        rendering = true
        errorText = nil
        let model = project.model
        let dir = project.dir
        let mm = resolution
        Task.detached(priority: .userInitiated) {
            do {
                let result = try MosaicRenderer.render(project: model, projectDir: dir, mmPerPixel: mm)
                await MainActor.run {
                    info = result
                    rendering = false
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    errorText = message
                    rendering = false
                }
            }
        }
    }

    private func exportZip() {
        zipping = true
        let dir = project.dir
        Task.detached(priority: .userInitiated) {
            let url = try? zipFolder(dir)
            await MainActor.run {
                zipURL = url
                zipping = false
                if url == nil { errorText = "打包失敗" }
            }
        }
    }
}

/// 可縮放、拖曳的大圖檢視
struct ZoomableImageView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> ZoomScrollView {
        ZoomScrollView(image: UIImage(contentsOfFile: url.path))
    }

    func updateUIView(_ uiView: ZoomScrollView, context: Context) {}
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var configuredFor: CGSize = .zero

    init(image: UIImage?) {
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .black
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        imageView.image = image
        if let image {
            imageView.frame = CGRect(origin: .zero, size: image.size)
            contentSize = image.size
        }
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let img = imageView.image, img.size.width > 0, bounds.width > 0, bounds.size != configuredFor else {
            centerImage()
            return
        }
        configuredFor = bounds.size
        let fit = min(bounds.width / img.size.width, bounds.height / img.size.height)
        minimumZoomScale = fit
        maximumZoomScale = max(fit * 20, 2)
        zoomScale = fit
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    private func centerImage() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }
}
