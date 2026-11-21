import ARKit
import RealityKit
import SwiftUI
import CoreImage
import ImageIO
import UIKit

/// 小地圖用的快照
struct MapSnapshot {
    var missing: [CellKey] = []
    var covered: [CellKey] = []
    var cellSize: Float = 0.1
    var camera: SIMD2<Float>?
    var heading: SIMD2<Float>?
}

/// 掃描流程核心：AR 追蹤、地板偵測、覆蓋網格、拍照存檔
@MainActor
final class ScanSession: NSObject, ObservableObject {
    @Published var trackingText = "啟動中…"
    @Published var trackingOK = false
    @Published var floorY: Float?
    @Published var photoCount = 0
    @Published var coveragePercent = 0.0
    @Published var autoCapture = true
    @Published var hint: String?
    @Published var toast: String?
    @Published var map = MapSnapshot()
    @Published var isCapturing = false

    let project: ProjectHandle
    let hasLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    /// 自動拍照的門檻：這張照片至少要新增幾格（0.1 m 一格）
    static let minNewCellsForAuto = 15

    private weak var arView: ARView?
    private let grid: CoverageGrid
    private let overlayAnchor = AnchorEntity(world: .zero)
    private let missingEntity = ModelEntity()
    private let coveredEntity = ModelEntity()
    private let ciContext = CIContext()
    private let ioQueue = DispatchQueue(label: "floorscan.io", qos: .userInitiated)

    private var overlayDirty = false
    private var lastOverlay: TimeInterval = 0
    private var lastPlanes: TimeInterval = 0
    private var lastAuto: TimeInterval = 0
    private var lastMap: TimeInterval = 0
    private var lastCaptureTime: CFTimeInterval = 0
    private var prevPos: SIMD3<Float>?
    private var prevFwd: SIMD3<Float>?
    private var toastToken = 0

    init(project: ProjectHandle) {
        self.project = project
        self.grid = CoverageGrid(cellSize: project.model.cellSize)
        super.init()
        self.photoCount = project.model.photos.count
        self.map.cellSize = project.model.cellSize
    }

    // MARK: - 啟動 / 停止

    func start(on view: ARView) {
        arView = view
        view.session.delegate = self
        view.renderOptions.insert(.disableMotionBlur)
        overlayAnchor.addChild(missingEntity)
        overlayAnchor.addChild(coveredEntity)
        view.scene.addAnchor(overlayAnchor)

        guard ARWorldTrackingConfiguration.isSupported else {
            trackingText = "此裝置不支援 AR"
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        if hasLiDAR { config.sceneReconstruction = .mesh }
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = format
        }
        view.session.run(config)
        if !hasLiDAR { showToast("此裝置沒有 LiDAR，定位精度會較低") }
    }

    func stop() {
        arView?.session.pause()
        project.save()
    }

    // MARK: - 地板

    func setFloorFromCenter() {
        guard let arView else { return }
        guard photoCount == 0 else {
            showToast("已有照片，無法更改地板高度")
            return
        }
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        if let hit = arView.raycast(from: center, allowing: .estimatedPlane, alignment: .horizontal).first {
            setFloor(y: hit.worldTransform.columns.3.y, auto: false)
        } else {
            showToast("找不到地板，請對準地板並緩慢移動後再試")
        }
    }

    private func setFloor(y: Float, auto: Bool) {
        floorY = y
        project.model.floorY = y
        project.save()
        grid.reset()
        overlayDirty = true
        showToast(auto ? "已自動偵測地板（可按「重設地板」修正）" : "地板已設定，開始拍攝")
    }

    // MARK: - 拍照

    func capture(manual: Bool) {
        guard let session = arView?.session, floorY != nil, !isCapturing else { return }
        isCapturing = true
        session.captureHighResolutionFrame { [weak self] frame, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let f = frame ?? self.arView?.session.currentFrame {
                    self.handleCaptured(f, manual: manual)
                }
                self.isCapturing = false
                self.lastCaptureTime = CACurrentMediaTime()
            }
        }
    }

    private func handleCaptured(_ frame: ARFrame, manual: Bool) {
        guard let floorY else { return }
        let cam = frame.camera
        guard case .normal = cam.trackingState else {
            if manual { showToast("追蹤不穩定，這張未儲存") }
            return
        }
        let size = SIMD2<Float>(Float(cam.imageResolution.width), Float(cam.imageResolution.height))
        switch Geo.footprint(K: cam.intrinsics, T: cam.transform, imageSize: size, floorY: floorY) {
        case .failure(let issue):
            if manual { showToast(issue.message) }
        case .success(let fp):
            let newCells = grid.countNew(fp.corners)
            if !manual && newCells < Self.minNewCellsForAuto / 2 { return }
            grid.markCovered(fp.corners)
            savePhoto(frame: frame, footprint: fp)
            overlayDirty = true
            UIImpactFeedbackGenerator(style: manual ? .medium : .light).impactOccurred()
            showToast("已拍第 \(photoCount) 張（新增 \(newCells) 格）")
        }
    }

    private func savePhoto(frame: ARFrame, footprint fp: Footprint) {
        let cam = frame.camera
        let index = project.model.photos.count + 1
        let file = String(format: "IMG_%04d.jpg", index)
        let url = project.photosDir.appendingPathComponent(file)
        let record = PhotoRecord(file: file,
                                 width: Int(cam.imageResolution.width),
                                 height: Int(cam.imageResolution.height),
                                 intrinsics: cam.intrinsics.flat,
                                 transform: cam.transform.flat,
                                 timestamp: Date(),
                                 heightAboveFloor: fp.height,
                                 tiltDegrees: fp.tiltDegrees)
        project.model.photos.append(record)
        photoCount = project.model.photos.count
        project.save()

        let buffer = frame.capturedImage
        let ctx = ciContext
        ioQueue.async {
            let image = CIImage(cvPixelBuffer: buffer)
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            if let data = ctx.jpegRepresentation(of: image, colorSpace: colorSpace, options: [quality: 0.9]) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - 每一幀

    fileprivate func onFrame(_ frame: ARFrame) {
        let now = frame.timestamp
        updateTracking(frame.camera.trackingState)

        let T = frame.camera.transform
        let pos = SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z)
        let fwd = -SIMD3<Float>(T.columns.2.x, T.columns.2.y, T.columns.2.z)

        if now - lastPlanes > 0.5 {
            lastPlanes = now
            updatePlanes(frame.anchors)
        }
        if overlayDirty && now - lastOverlay > 0.5 {
            lastOverlay = now
            overlayDirty = false
            rebuildOverlay()
            publishStats()
        }
        if now - lastMap > 0.25 {
            lastMap = now
            map.camera = SIMD2<Float>(pos.x, pos.z)
            let h = SIMD2<Float>(fwd.x, fwd.z)
            map.heading = simd_length(h) > 0.05 ? simd_normalize(h) : nil
        }

        guard floorY != nil else {
            hint = "將畫面中央十字對準地板，按「設定地板」"
            return
        }
        guard autoCapture, now - lastAuto > 0.4 else { return }
        lastAuto = now
        evaluateAuto(frame: frame, pos: pos, fwd: fwd)
        prevPos = pos
        prevFwd = fwd
    }

    private func evaluateAuto(frame: ARFrame, pos: SIMD3<Float>, fwd: SIMD3<Float>) {
        guard let floorY else { return }
        guard case .normal = frame.camera.trackingState else { hint = nil; return }
        let cam = frame.camera
        let size = SIMD2<Float>(Float(cam.imageResolution.width), Float(cam.imageResolution.height))
        switch Geo.footprint(K: cam.intrinsics, T: cam.transform, imageSize: size, floorY: floorY) {
        case .failure(let issue):
            hint = issue.message
        case .success(let fp):
            let newCells = grid.countNew(fp.corners)
            if newCells < Self.minNewCellsForAuto {
                hint = grid.missing.isEmpty ? "此處已拍好，往未拍的區域移動" : "請移到紅色區域"
                return
            }
            let steady: Bool
            if let pp = prevPos, let pf = prevFwd {
                steady = simd_distance(pp, pos) < 0.05 && simd_dot(pf, fwd) > 0.998
            } else {
                steady = false
            }
            if !steady {
                hint = "請保持手機穩定"
            } else if !isCapturing && CACurrentMediaTime() - lastCaptureTime > 0.6 {
                hint = nil
                capture(manual: false)
            }
        }
    }

    private func updateTracking(_ state: ARCamera.TrackingState) {
        let text: String
        let ok: Bool
        switch state {
        case .normal:
            text = "追蹤正常"; ok = true
        case .notAvailable:
            text = "追蹤無法使用"; ok = false
        case .limited(let reason):
            ok = false
            switch reason {
            case .initializing: text = "初始化中，請緩慢移動手機"
            case .excessiveMotion: text = "移動太快，請放慢"
            case .insufficientFeatures: text = "畫面特徵不足，請增加光線"
            case .relocalizing: text = "重新定位中"
            @unknown default: text = "追蹤受限"
            }
        }
        if text != trackingText { trackingText = text }
        if ok != trackingOK { trackingOK = ok }
    }

    private func updatePlanes(_ anchors: [ARAnchor]) {
        let planes = anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .horizontal }
        if floorY == nil, let floorPlane = planes.first(where: { plane in
            if case .floor = plane.classification { return true }
            return false
        }) {
            setFloor(y: floorPlane.transform.columns.3.y, auto: true)
        }
        guard let floorY else { return }
        var added = 0
        for p in planes where abs(p.transform.columns.3.y - floorY) < 0.12 {
            let poly: [SIMD2<Float>] = p.geometry.boundaryVertices.map { v in
                let w = p.transform * SIMD4<Float>(v.x, v.y, v.z, 1)
                return SIMD2<Float>(w.x, w.z)
            }
            added += grid.markScanned(poly)
        }
        if added > 0 { overlayDirty = true }
    }

    // MARK: - AR 疊加的紅綠格

    private func rebuildOverlay() {
        guard let floorY else {
            missingEntity.model = nil
            coveredEntity.model = nil
            return
        }
        let y = floorY + 0.01
        missingEntity.model = makeModel(cells: grid.missing, y: y, color: .systemRed, opacity: 0.45)
        coveredEntity.model = makeModel(cells: grid.covered, y: y, color: .systemGreen, opacity: 0.25)
    }

    private func makeModel(cells: Set<CellKey>, y: Float, color: UIColor, opacity: Float) -> ModelComponent? {
        guard !cells.isEmpty else { return nil }
        let s = grid.cellSize
        let gap = s * 0.08
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(cells.count * 4)
        indices.reserveCapacity(cells.count * 6)
        for c in cells {
            let x0 = Float(c.i) * s + gap, x1 = Float(c.i + 1) * s - gap
            let z0 = Float(c.j) * s + gap, z1 = Float(c.j + 1) * s - gap
            let base = UInt32(positions.count)
            positions.append(SIMD3<Float>(x0, y, z0))
            positions.append(SIMD3<Float>(x1, y, z0))
            positions.append(SIMD3<Float>(x1, y, z1))
            positions.append(SIMD3<Float>(x0, y, z1))
            // 逆時針（從上往下看）使法向量朝上
            indices.append(contentsOf: [base, base + 2, base + 1, base, base + 3, base + 2])
        }
        var desc = MeshDescriptor(name: "cells")
        desc.positions = MeshBuffers.Positions(positions)
        desc.primitives = .triangles(indices)
        guard let mesh = try? MeshResource.generate(from: [desc]) else { return nil }
        var material = UnlitMaterial(color: color)
        material.blending = .transparent(opacity: PhysicallyBasedMaterial.Opacity(scale: opacity))
        return ModelComponent(mesh: mesh, materials: [material])
    }

    private func publishStats() {
        coveragePercent = grid.coverage * 100
        map.missing = Array(grid.missing)
        map.covered = Array(grid.covered)
        map.cellSize = grid.cellSize
    }

    func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        toast = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if self?.toastToken == token { self?.toast = nil }
        }
    }
}

extension ScanSession: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // delegateQueue 未指定時 ARKit 在主執行緒回呼
        MainActor.assumeIsolated { self.onFrame(frame) }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { self.trackingText = "AR 錯誤：\(message)" }
    }
}
