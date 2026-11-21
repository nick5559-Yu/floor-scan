import SwiftUI
import RealityKit
import ARKit

struct ARViewContainer: UIViewRepresentable {
    let session: ScanSession

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        session.start(on: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

struct ScanView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: ScanSession

    init(project: ProjectHandle) {
        _session = StateObject(wrappedValue: ScanSession(project: project))
    }

    var body: some View {
        ZStack {
            ARViewContainer(session: session)
                .ignoresSafeArea()

            // 畫面中央十字
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white)
                .shadow(radius: 2)

            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    statusPanel
                    Spacer()
                    MiniMapView(map: session.map)
                        .frame(width: 140, height: 140)
                }
                .padding(.horizontal)

                Spacer()

                if let toast = session.toast {
                    Text(toast)
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(.white)
                }

                controls
                    .padding(.bottom, 8)
            }
            .padding(.top, 8)
        }
        .statusBarHidden()
        .onDisappear { session.stop() }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(session.trackingText,
                  systemImage: session.trackingOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(session.trackingOK ? Color.green : Color.yellow)
            if session.floorY == nil {
                Text("尚未設定地板")
            } else {
                Text("照片 \(session.photoCount) 張 · 覆蓋 \(Int(session.coveragePercent))%")
            }
            if let hint = session.hint {
                Text(hint).foregroundStyle(.orange)
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var controls: some View {
        if session.floorY == nil {
            VStack(spacing: 10) {
                Button {
                    session.setFloorFromCenter()
                } label: {
                    Label("設定地板", systemImage: "square.dashed")
                        .font(.headline)
                        .padding(.horizontal, 28).padding(.vertical, 14)
                        .background(.blue, in: Capsule())
                        .foregroundStyle(.white)
                }
                Button("取消") { dismiss() }
                    .foregroundStyle(.white)
            }
        } else {
            HStack(alignment: .center) {
                VStack(spacing: 8) {
                    Button {
                        session.autoCapture.toggle()
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: session.autoCapture ? "bolt.circle.fill" : "bolt.slash.circle")
                                .font(.title2)
                            Text(session.autoCapture ? "自動拍照：開" : "自動拍照：關")
                                .font(.caption2)
                        }
                        .foregroundStyle(session.autoCapture ? Color.yellow : Color.white)
                    }
                    if session.photoCount == 0 {
                        Button("重設地板") { session.setFloorFromCenter() }
                            .font(.caption)
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 100)

                Spacer()

                Button {
                    session.capture(manual: true)
                } label: {
                    ZStack {
                        Circle().fill(.white).frame(width: 72, height: 72)
                        Circle().stroke(.white, lineWidth: 4).frame(width: 84, height: 84)
                        if session.isCapturing { ProgressView() }
                    }
                }
                .disabled(session.isCapturing)

                Spacer()

                Button {
                    session.stop()
                    dismiss()
                } label: {
                    Text("完成")
                        .font(.headline)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(.green, in: Capsule())
                        .foregroundStyle(.white)
                }
                .frame(width: 100)
            }
            .padding(.horizontal)
        }
    }
}

/// 右上角小地圖：紅色＝掃到但沒照片，綠色＝已拍照，藍點＝手機位置
struct MiniMapView: View {
    let map: MapSnapshot

    var body: some View {
        Canvas { ctx, size in
            let s = CGFloat(map.cellSize)
            var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
            var minZ = CGFloat.greatestFiniteMagnitude, maxZ = -CGFloat.greatestFiniteMagnitude
            func include(_ x: CGFloat, _ z: CGFloat) {
                minX = min(minX, x); maxX = max(maxX, x)
                minZ = min(minZ, z); maxZ = max(maxZ, z)
            }
            for c in map.missing { include(CGFloat(c.i) * s, CGFloat(c.j) * s); include(CGFloat(c.i + 1) * s, CGFloat(c.j + 1) * s) }
            for c in map.covered { include(CGFloat(c.i) * s, CGFloat(c.j) * s); include(CGFloat(c.i + 1) * s, CGFloat(c.j + 1) * s) }
            if let cam = map.camera { include(CGFloat(cam.x), CGFloat(cam.y)) }
            guard minX <= maxX else { return }

            let pad: CGFloat = 8
            let spanX = max(maxX - minX, 0.5), spanZ = max(maxZ - minZ, 0.5)
            let scale = min((size.width - 2 * pad) / spanX, (size.height - 2 * pad) / spanZ)
            let ox = pad + ((size.width - 2 * pad) - spanX * scale) / 2
            let oz = pad + ((size.height - 2 * pad) - spanZ * scale) / 2
            func pt(_ x: CGFloat, _ z: CGFloat) -> CGPoint {
                CGPoint(x: ox + (x - minX) * scale, y: oz + (z - minZ) * scale)
            }
            let cell = CGSize(width: s * scale, height: s * scale)

            var red = Path()
            for c in map.missing { red.addRect(CGRect(origin: pt(CGFloat(c.i) * s, CGFloat(c.j) * s), size: cell)) }
            ctx.fill(red, with: .color(.red.opacity(0.85)))

            var green = Path()
            for c in map.covered { green.addRect(CGRect(origin: pt(CGFloat(c.i) * s, CGFloat(c.j) * s), size: cell)) }
            ctx.fill(green, with: .color(.green.opacity(0.85)))

            if let cam = map.camera {
                let p = pt(CGFloat(cam.x), CGFloat(cam.y))
                if let h = map.heading {
                    var line = Path()
                    line.move(to: p)
                    line.addLine(to: CGPoint(x: p.x + CGFloat(h.x) * 14, y: p.y + CGFloat(h.y) * 14))
                    ctx.stroke(line, with: .color(.cyan), lineWidth: 2)
                }
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.cyan))
            }
        }
        .background(Color.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
