import Foundation
import simd

struct CellKey: Hashable, Codable {
    let i: Int
    let j: Int
}

/// 地板網格：記錄哪些格子已被 LiDAR 掃到（scanned）、哪些已有合格照片（covered）
final class CoverageGrid {
    let cellSize: Float
    private(set) var scanned = Set<CellKey>()
    private(set) var covered = Set<CellKey>()

    init(cellSize: Float) {
        self.cellSize = cellSize
    }

    /// 掃到但還沒有照片的格子（畫面上的紅色）
    var missing: Set<CellKey> { scanned.subtracting(covered) }

    var coverage: Double {
        scanned.isEmpty ? 0 : Double(covered.count) / Double(scanned.count)
    }

    func reset() {
        scanned.removeAll()
        covered.removeAll()
    }

    /// 中心點落在多邊形內的格子
    func cells(in poly: [SIMD2<Float>]) -> [CellKey] {
        guard poly.count >= 3 else { return [] }
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude, maxZ = -Float.greatestFiniteMagnitude
        for p in poly {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minZ = min(minZ, p.y); maxZ = max(maxZ, p.y)
        }
        let i0 = Int((minX / cellSize).rounded(.down)), i1 = Int((maxX / cellSize).rounded(.down))
        let j0 = Int((minZ / cellSize).rounded(.down)), j1 = Int((maxZ / cellSize).rounded(.down))
        guard i1 >= i0, j1 >= j0, (i1 - i0 + 1) * (j1 - j0 + 1) <= 400_000 else { return [] }

        var out: [CellKey] = []
        for i in i0...i1 {
            for j in j0...j1 {
                let c = SIMD2<Float>((Float(i) + 0.5) * cellSize, (Float(j) + 0.5) * cellSize)
                if Geo.contains(poly, c) { out.append(CellKey(i: i, j: j)) }
            }
        }
        return out
    }

    @discardableResult
    func markScanned(_ poly: [SIMD2<Float>]) -> Int {
        var added = 0
        for c in cells(in: poly) {
            if scanned.insert(c).inserted { added += 1 }
        }
        return added
    }

    /// 標記已拍照的格子，回傳新增的格數
    @discardableResult
    func markCovered(_ poly: [SIMD2<Float>]) -> Int {
        var added = 0
        for c in cells(in: poly) {
            scanned.insert(c)
            if covered.insert(c).inserted { added += 1 }
        }
        return added
    }

    func countNew(_ poly: [SIMD2<Float>]) -> Int {
        cells(in: poly).reduce(0) { $0 + (covered.contains($1) ? 0 : 1) }
    }
}
