import UIKit
import CoreImage
import simd

struct MosaicInfo: Codable {
    let widthPx: Int
    let heightPx: Int
    let mmPerPixel: Double
    let widthM: Double
    let heightM: Double
    let photoCount: Int
    let pdfScale: Int
    let created: Date

    var summary: String {
        String(format: "範圍 %.2f × %.2f m · 解析度 %.1f mm/px · 使用 %ld 張照片 · PDF 比例 1:%ld（A3）",
               widthM, heightM, mmPerPixel, photoCount, pdfScale)
    }
}

enum MosaicError: LocalizedError {
    case noFloor, noUsablePhotos, renderFailed

    var errorDescription: String? {
        switch self {
        case .noFloor: return "這次掃描沒有設定地板高度"
        case .noUsablePhotos: return "沒有可用的照片"
        case .renderFailed: return "影像合成失敗（可能記憶體不足，請改用較低解析度）"
        }
    }
}

/// 把所有照片依 LiDAR 定位投影到地板平面，合成正上方俯視圖
enum MosaicRenderer {
    static let pngName = "floorplan.png"
    static let pdfName = "floorplan.pdf"
    static let infoName = "floorplan.json"

    static func loadInfo(projectDir: URL) -> MosaicInfo? {
        let url = projectDir.appendingPathComponent("output").appendingPathComponent(infoName)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? dec.decode(MosaicInfo.self, from: data)
    }

    static func render(project: ScanProject,
                       projectDir: URL,
                       mmPerPixel: Double,
                       maxDimension: Int = 6000) throws -> MosaicInfo {
        guard let floorY = project.floorY else { throw MosaicError.noFloor }
        let photosDir = projectDir.appendingPathComponent("photos")
        let outDir = projectDir.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        struct Item {
            let url: URL
            let corners: [SIMD2<Float>]
            let crop: CGRect
            let score: Float
        }

        var items: [Item] = []
        for p in project.photos {
            let url = photosDir.appendingPathComponent(p.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let size = SIMD2<Float>(Float(p.width), Float(p.height))
            guard case .success(let fp) = Geo.footprint(K: p.K, T: p.T, imageSize: size, floorY: floorY) else {
                continue
            }
            let m = CGFloat(Geo.photoInset)
            let w = CGFloat(p.width), h = CGFloat(p.height)
            // 四邊對稱內縮，所以在 CoreImage（左下原點）與像素座標（左上原點）中是同一個矩形
            let crop = CGRect(x: m * w, y: m * h, width: (1 - 2 * m) * w, height: (1 - 2 * m) * h)
            items.append(Item(url: url, corners: fp.corners, crop: crop, score: fp.score))
        }
        guard !items.isEmpty else { throw MosaicError.noUsablePhotos }

        // 範圍
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude, maxZ = -Float.greatestFiniteMagnitude
        for it in items {
            for c in it.corners {
                minX = min(minX, c.x); maxX = max(maxX, c.x)
                minZ = min(minZ, c.y); maxZ = max(maxZ, c.y)
            }
        }
        let margin: Float = 0.1
        minX -= margin; maxX += margin; minZ -= margin; maxZ += margin

        let extX = Double(maxX - minX), extZ = Double(maxZ - minZ)
        let res = max(mmPerPixel / 1000, max(extX, extZ) / Double(maxDimension)) // 公尺 / 像素
        let W = Int((extX / res).rounded(.up))
        let H = Int((extZ / res).rounded(.up))
        let canvasRect = CGRect(x: 0, y: 0, width: W, height: H)
        let originX = minX, originZ = minZ

        // 地板 (x, z) → 畫布（CoreImage 左下原點；z 向畫面下方）
        func toCanvas(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x: Double(p.x - originX) / res,
                    y: Double(H) - Double(p.y - originZ) / res)
        }

        let ctx = CIContext(options: [.cacheIntermediates: false])
        var canvas = CIImage(color: CIColor(red: 0.82, green: 0.82, blue: 0.82)).cropped(to: canvasRect)

        // 品質差的先畫，品質好的後畫（蓋在上面）
        let ordered = items.sorted { $0.score > $1.score }
        for (n, it) in ordered.enumerated() {
            autoreleasepool {
                guard let img = CIImage(contentsOf: it.url) else { return }
                let c = it.corners // 左上、右上、右下、左下
                let warped = img.cropped(to: it.crop).applyingFilter("CIPerspectiveTransform", parameters: [
                    "inputTopLeft": CIVector(cgPoint: toCanvas(c[0])),
                    "inputTopRight": CIVector(cgPoint: toCanvas(c[1])),
                    "inputBottomRight": CIVector(cgPoint: toCanvas(c[2])),
                    "inputBottomLeft": CIVector(cgPoint: toCanvas(c[3]))
                ])
                canvas = warped.composited(over: canvas).cropped(to: canvasRect)
                // 每 10 張先算成點陣，避免 CoreImage 處理圖過大
                if (n + 1) % 10 == 0, let cg = ctx.createCGImage(canvas, from: canvasRect) {
                    canvas = CIImage(cgImage: cg)
                }
            }
        }
        guard let base = ctx.createCGImage(canvas, from: canvasRect) else { throw MosaicError.renderFailed }

        let mmText = String(format: "%.1f mm/px", res * 1000)
        let dateText = DateFormatter.localizedString(from: project.created, dateStyle: .medium, timeStyle: .short)
        let annotated = annotate(base: base, metersPerPixel: res,
                                 caption: "\(project.name) · \(dateText) · \(mmText)")

        guard let png = annotated.pngData() else { throw MosaicError.renderFailed }
        try png.write(to: outDir.appendingPathComponent(pngName), options: .atomic)

        let widthM = Double(W) * res, heightM = Double(H) * res
        let scale = try writePDF(image: annotated,
                                 widthM: widthM, heightM: heightM,
                                 title: project.name,
                                 footer: "\(dateText) · 解析度 \(mmText) · \(items.count) 張照片 · 格線間距 1 m",
                                 to: outDir.appendingPathComponent(pdfName))

        let info = MosaicInfo(widthPx: W, heightPx: H, mmPerPixel: res * 1000,
                              widthM: widthM, heightM: heightM,
                              photoCount: items.count, pdfScale: scale, created: Date())
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = .prettyPrinted
        try enc.encode(info).write(to: outDir.appendingPathComponent(infoName), options: .atomic)
        return info
    }

    // MARK: - PNG 標註：1 m 格線、刻度、比例尺

    private static func annotate(base: CGImage, metersPerPixel res: Double, caption: String) -> UIImage {
        let size = CGSize(width: base.width, height: base.height)
        let pxPerM = CGFloat(1 / res)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { rc in
            let g = rc.cgContext
            UIImage(cgImage: base).draw(in: CGRect(origin: .zero, size: size))

            let lineWidth = max(1, 0.003 * pxPerM)
            let fontSize = max(12, 0.05 * pxPerM)
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: fontSize),
                .foregroundColor: UIColor.white,
                .strokeColor: UIColor.black,
                .strokeWidth: -3.0
            ]

            // 格線（從左上角起算，每 1 m）
            g.setStrokeColor(UIColor.white.withAlphaComponent(0.6).cgColor)
            g.setLineWidth(lineWidth)
            var k = 1
            while CGFloat(k) * pxPerM < size.width {
                let x = CGFloat(k) * pxPerM
                g.move(to: CGPoint(x: x, y: 0)); g.addLine(to: CGPoint(x: x, y: size.height))
                k += 1
            }
            k = 1
            while CGFloat(k) * pxPerM < size.height {
                let y = CGFloat(k) * pxPerM
                g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: size.width, y: y))
                k += 1
            }
            g.strokePath()

            // 刻度文字
            k = 1
            while CGFloat(k) * pxPerM < size.width {
                ("\(k) m" as NSString).draw(at: CGPoint(x: CGFloat(k) * pxPerM + lineWidth * 3, y: lineWidth * 3),
                                            withAttributes: labelAttrs)
                k += 1
            }
            k = 1
            while CGFloat(k) * pxPerM < size.height {
                ("\(k) m" as NSString).draw(at: CGPoint(x: lineWidth * 3, y: CGFloat(k) * pxPerM + lineWidth * 3),
                                            withAttributes: labelAttrs)
                k += 1
            }

            // 比例尺（左下）
            let barM: CGFloat = size.width / pxPerM >= 2.5 ? 1.0 : 0.5
            let barLen = barM * pxPerM
            let barH = max(6, 0.02 * pxPerM)
            let pad = max(10, 0.04 * pxPerM)
            let barOrigin = CGPoint(x: pad, y: size.height - pad - barH)
            let captionAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize * 0.8),
                .foregroundColor: UIColor.black
            ]
            let barLabel = barM >= 1 ? "1 m" : "0.5 m"
            let labelSize = (barLabel as NSString).size(withAttributes: captionAttrs)
            let captionSize = (caption as NSString).size(withAttributes: captionAttrs)
            let boxW = max(barLen + labelSize.width + pad * 1.5, captionSize.width + pad)
            let boxH = barH + captionSize.height + pad * 1.5
            let box = CGRect(x: barOrigin.x - pad / 2, y: size.height - pad / 2 - boxH,
                             width: boxW, height: boxH)
            UIColor.white.withAlphaComponent(0.85).setFill()
            UIBezierPath(roundedRect: box, cornerRadius: pad / 3).fill()

            (caption as NSString).draw(at: CGPoint(x: barOrigin.x, y: box.minY + pad / 3),
                                       withAttributes: captionAttrs)
            let segments = 4
            let segLen = barLen / CGFloat(segments)
            for s in 0..<segments {
                let r = CGRect(x: barOrigin.x + CGFloat(s) * segLen, y: barOrigin.y, width: segLen, height: barH)
                (s % 2 == 0 ? UIColor.black : UIColor.white).setFill()
                UIBezierPath(rect: r).fill()
            }
            UIColor.black.setStroke()
            let outline = UIBezierPath(rect: CGRect(x: barOrigin.x, y: barOrigin.y, width: barLen, height: barH))
            outline.lineWidth = max(1, barH / 6)
            outline.stroke()
            (barLabel as NSString).draw(at: CGPoint(x: barOrigin.x + barLen + pad / 3,
                                                    y: barOrigin.y + barH / 2 - labelSize.height / 2),
                                        withAttributes: captionAttrs)
        }
    }

    // MARK: - PDF（A3，固定比例，可直接列印量測）

    private static func writePDF(image: UIImage, widthM: Double, heightM: Double,
                                 title: String, footer: String, to url: URL) throws -> Int {
        let a3 = CGSize(width: 841.89, height: 1190.55)
        let page = widthM > heightM ? CGSize(width: a3.height, height: a3.width) : a3
        let margin: CGFloat = 36, headerH: CGFloat = 48, footerH: CGFloat = 60
        let availW = page.width - 2 * margin
        let availH = page.height - 2 * margin - headerH - footerH
        let ptsPerM = 72.0 / 0.0254

        let candidates = [10, 20, 25, 50, 75, 100, 150, 200, 250, 300, 400, 500, 750, 1000, 1500, 2000, 2500, 5000]
        var scale = candidates[candidates.count - 1]
        for n in candidates {
            let w = widthM * ptsPerM / Double(n), h = heightM * ptsPerM / Double(n)
            if w <= Double(availW) && h <= Double(availH) { scale = n; break }
        }
        let drawW = CGFloat(widthM * ptsPerM / Double(scale))
        let drawH = CGFloat(heightM * ptsPerM / Double(scale))

        // 縮到約 300 dpi，避免 PDF 過大
        let targetPxW = min(image.size.width, drawW / 72 * 300)
        var embed = image
        if targetPxW < image.size.width {
            let s = CGSize(width: targetPxW.rounded(), height: (image.size.height * targetPxW / image.size.width).rounded())
            let f = UIGraphicsImageRendererFormat()
            f.scale = 1
            f.opaque = true
            embed = UIGraphicsImageRenderer(size: s, format: f).image { _ in
                image.draw(in: CGRect(origin: .zero, size: s))
            }
        }
        if let jpeg = embed.jpegData(compressionQuality: 0.85), let j = UIImage(data: jpeg) { embed = j }

        let titleAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 18),
                                                         .foregroundColor: UIColor.black]
        let smallAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10),
                                                         .foregroundColor: UIColor.darkGray]

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: page))
        try renderer.writePDF(to: url) { ctx in
            ctx.beginPage()
            (title as NSString).draw(at: CGPoint(x: margin, y: margin), withAttributes: titleAttrs)
            ("比例 1:\(scale)（A3 列印時請選「實際大小」，不要縮放）" as NSString)
                .draw(at: CGPoint(x: margin, y: margin + 24), withAttributes: smallAttrs)

            let imgRect = CGRect(x: margin + (availW - drawW) / 2,
                                 y: margin + headerH + (availH - drawH) / 2,
                                 width: drawW, height: drawH)
            embed.draw(in: imgRect)
            UIColor.black.setStroke()
            let border = UIBezierPath(rect: imgRect)
            border.lineWidth = 0.5
            border.stroke()

            // 比例尺
            let barChoices: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50]
            let barM = barChoices.first(where: { $0 * ptsPerM / Double(scale) >= 60 }) ?? 50
            let barPts = CGFloat(barM * ptsPerM / Double(scale))
            let barY = page.height - margin - footerH + 14
            let segs = 4
            for s in 0..<segs {
                let r = CGRect(x: margin + CGFloat(s) * barPts / CGFloat(segs), y: barY,
                               width: barPts / CGFloat(segs), height: 6)
                (s % 2 == 0 ? UIColor.black : UIColor.white).setFill()
                UIBezierPath(rect: r).fill()
            }
            let outline = UIBezierPath(rect: CGRect(x: margin, y: barY, width: barPts, height: 6))
            outline.lineWidth = 0.5
            outline.stroke()
            let barLabel = barM < 1 ? String(format: "%.1f m", barM) : String(format: "%.0f m", barM)
            ("0" as NSString).draw(at: CGPoint(x: margin - 2, y: barY + 8), withAttributes: smallAttrs)
            (barLabel as NSString).draw(at: CGPoint(x: margin + barPts - 8, y: barY + 8), withAttributes: smallAttrs)

            (footer as NSString).draw(at: CGPoint(x: margin, y: page.height - margin - 14), withAttributes: smallAttrs)
        }
        return scale
    }
}
