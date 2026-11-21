import Foundation
import simd

/// 照片品質不合格的原因
enum FootprintIssue: Error {
    case tooHigh, tooLow, tooTilted, cornersMiss

    var message: String {
        switch self {
        case .tooHigh: return "手機太高，請降到離地 2.5 公尺以內"
        case .tooLow: return "手機太低，請抬高到離地 30 公分以上"
        case .tooTilted: return "鏡頭請更朝下（傾斜需小於 40°）"
        case .cornersMiss: return "鏡頭請更朝下，畫面四角都要拍到地板"
        }
    }
}

/// 一張照片投影到地板上的範圍
struct Footprint {
    /// 地板座標 (x, z)，順序：影像的左上、右上、右下、左下（已內縮 Geo.photoInset）
    let corners: [SIMD2<Float>]
    /// 相機離地高度（公尺）
    let height: Float
    /// 鏡頭與正下方的夾角（度）
    let tiltDegrees: Float
    /// 分數越低代表越清楚（越低、越正對地板）
    var score: Float { height * (1 + tiltDegrees / 30) }
}

enum Geo {
    /// 照片四邊各內縮的比例，邊緣變形較大故不使用
    static let photoInset: Float = 0.1
    static let maxHeight: Float = 2.5
    static let minHeight: Float = 0.3
    static let maxTilt: Float = 40
    static let maxRayDistance: Float = 5

    /// 從相機穿過影像像素的射線，與高度 floorY 的水平地板相交的位置 (x, z)
    /// - pixel: 影像像素座標（原點在左上，與 ARFrame.capturedImage 相同）
    static func floorHit(pixel: SIMD2<Float>, K: simd_float3x3, T: simd_float4x4, floorY: Float) -> SIMD2<Float>? {
        let fx = K[0][0], fy = K[1][1], cx = K[2][0], cy = K[2][1]
        // ARKit 相機座標：x 向右、y 向上、-z 為鏡頭前方
        let dirCam = SIMD4<Float>((pixel.x - cx) / fx, -(pixel.y - cy) / fy, -1, 0)
        let dw = T * dirCam
        let dir = simd_normalize(SIMD3<Float>(dw.x, dw.y, dw.z))
        let origin = SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z)
        guard dir.y < -1e-4 else { return nil }
        let t = (floorY - origin.y) / dir.y
        guard t > 0, t < maxRayDistance else { return nil }
        let p = origin + t * dir
        return SIMD2<Float>(p.x, p.z)
    }

    static func footprint(K: simd_float3x3,
                          T: simd_float4x4,
                          imageSize: SIMD2<Float>,
                          floorY: Float,
                          inset: Float = photoInset) -> Result<Footprint, FootprintIssue> {
        let height = T.columns.3.y - floorY
        if height > maxHeight { return .failure(.tooHigh) }
        if height < minHeight { return .failure(.tooLow) }

        // 鏡頭方向 = -columns.2，與 (0,-1,0) 的夾角
        let cosTilt = max(-1, min(1, T.columns.2.y))
        let tilt = acos(cosTilt) * 180 / Float.pi
        if tilt > maxTilt { return .failure(.tooTilted) }

        let w = imageSize.x, h = imageSize.y
        let pixels: [SIMD2<Float>] = [
            SIMD2<Float>(inset * w, inset * h),
            SIMD2<Float>((1 - inset) * w, inset * h),
            SIMD2<Float>((1 - inset) * w, (1 - inset) * h),
            SIMD2<Float>(inset * w, (1 - inset) * h)
        ]
        var corners: [SIMD2<Float>] = []
        for px in pixels {
            guard let hit = floorHit(pixel: px, K: K, T: T, floorY: floorY) else {
                return .failure(.cornersMiss)
            }
            corners.append(hit)
        }
        return .success(Footprint(corners: corners, height: height, tiltDegrees: tilt))
    }

    /// 點是否在多邊形內（射線法，可用於凹多邊形）
    static func contains(_ poly: [SIMD2<Float>], _ p: SIMD2<Float>) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) {
                let xCross = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                if p.x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

extension simd_float4x4 {
    var flat: [Float] {
        [columns.0.x, columns.0.y, columns.0.z, columns.0.w,
         columns.1.x, columns.1.y, columns.1.z, columns.1.w,
         columns.2.x, columns.2.y, columns.2.z, columns.2.w,
         columns.3.x, columns.3.y, columns.3.z, columns.3.w]
    }

    init(flat a: [Float]) {
        self.init(SIMD4<Float>(a[0], a[1], a[2], a[3]),
                  SIMD4<Float>(a[4], a[5], a[6], a[7]),
                  SIMD4<Float>(a[8], a[9], a[10], a[11]),
                  SIMD4<Float>(a[12], a[13], a[14], a[15]))
    }
}

extension simd_float3x3 {
    var flat: [Float] {
        [columns.0.x, columns.0.y, columns.0.z,
         columns.1.x, columns.1.y, columns.1.z,
         columns.2.x, columns.2.y, columns.2.z]
    }

    init(flat a: [Float]) {
        self.init(SIMD3<Float>(a[0], a[1], a[2]),
                  SIMD3<Float>(a[3], a[4], a[5]),
                  SIMD3<Float>(a[6], a[7], a[8]))
    }
}
