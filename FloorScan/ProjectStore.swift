import Foundation
import simd

struct PhotoRecord: Codable, Identifiable {
    var id: String { file }
    let file: String
    let width: Int
    let height: Int
    /// 相機內參 3x3（column-major）
    let intrinsics: [Float]
    /// 相機在世界座標的位置姿態 4x4（column-major）
    let transform: [Float]
    let timestamp: Date
    let heightAboveFloor: Float
    let tiltDegrees: Float

    var K: simd_float3x3 { simd_float3x3(flat: intrinsics) }
    var T: simd_float4x4 { simd_float4x4(flat: transform) }
}

struct ScanProject: Codable {
    var name: String
    var created: Date
    /// 地板在 AR 世界座標中的高度（y）
    var floorY: Float?
    var cellSize: Float
    var photos: [PhotoRecord]

    init(name: String, created: Date = Date()) {
        self.name = name
        self.created = created
        self.floorY = nil
        self.cellSize = 0.1
        self.photos = []
    }
}

final class ProjectHandle: ObservableObject, Identifiable, Hashable {
    let dir: URL
    @Published var model: ScanProject

    var id: URL { dir }
    var photosDir: URL { dir.appendingPathComponent("photos", isDirectory: true) }
    var outputDir: URL { dir.appendingPathComponent("output", isDirectory: true) }
    var jsonURL: URL { dir.appendingPathComponent("project.json") }

    init(dir: URL, model: ScanProject) {
        self.dir = dir
        self.model = model
    }

    static func == (a: ProjectHandle, b: ProjectHandle) -> Bool { a.dir == b.dir }
    func hash(into hasher: inout Hasher) { hasher.combine(dir) }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(model) {
            try? data.write(to: jsonURL, options: .atomic)
        }
    }

    static func load(dir: URL) -> ProjectHandle? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("project.json")),
              let model = try? dec.decode(ScanProject.self, from: data) else { return nil }
        return ProjectHandle(dir: dir, model: model)
    }
}

final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [ProjectHandle] = []

    static var rootDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Projects", isDirectory: true)
    }

    init() { reload() }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.rootDir, withIntermediateDirectories: true)
        let dirs = (try? fm.contentsOfDirectory(at: Self.rootDir, includingPropertiesForKeys: nil)) ?? []
        projects = dirs.compactMap { ProjectHandle.load(dir: $0) }
            .sorted { $0.model.created > $1.model.created }
    }

    func create(name: String) throws -> ProjectHandle {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "未命名" : trimmed
        let safe = display.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = Self.rootDir.appendingPathComponent("\(f.string(from: Date()))_\(safe)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("photos", isDirectory: true),
                                                withIntermediateDirectories: true)
        let p = ProjectHandle(dir: dir, model: ScanProject(name: display))
        p.save()
        reload()
        return p
    }

    func delete(_ p: ProjectHandle) {
        try? FileManager.default.removeItem(at: p.dir)
        reload()
    }
}

/// 把資料夾壓成 zip（系統內建，不需第三方套件）
func zipFolder(_ dir: URL) throws -> URL {
    var result: URL?
    var innerError: Error?
    var coordError: NSError?
    NSFileCoordinator().coordinate(readingItemAt: dir, options: [.forUploading], error: &coordError) { tmp in
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(dir.lastPathComponent + ".zip")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: tmp, to: dest)
            result = dest
        } catch {
            innerError = error
        }
    }
    if let e = coordError { throw e }
    if let e = innerError { throw e }
    guard let r = result else { throw CocoaError(.fileWriteUnknown) }
    return r
}
