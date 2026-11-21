import SwiftUI
import ARKit

@main
struct FloorScanApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var store = ProjectStore()
    @State private var path: [ProjectHandle] = []
    @State private var showNew = false
    @State private var newName = ""
    @State private var scanning: ProjectHandle?
    @State private var justScanned: ProjectHandle?
    @State private var errorText: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !ARWorldTrackingConfiguration.isSupported {
                    Text("此裝置不支援 AR 掃描").foregroundStyle(.red)
                } else if !ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                    Text("此裝置沒有 LiDAR，定位精度會較低").foregroundStyle(.orange)
                }
                if store.projects.isEmpty {
                    Section {
                        Text("還沒有掃描紀錄。按右上角「＋」開始新的掃描。")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(store.projects) { p in
                    NavigationLink(value: p) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.model.name).font(.headline)
                            Text("\(p.model.photos.count) 張照片 · \(p.model.created.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets { store.delete(store.projects[i]) }
                }
            }
            .navigationTitle("地板掃描")
            .navigationDestination(for: ProjectHandle.self) { p in
                ProjectDetailView(project: p)
            }
            .toolbar {
                Button {
                    newName = ""
                    showNew = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            .alert("新的掃描", isPresented: $showNew) {
                TextField("名稱，例如：3F 樓板 A 區", text: $newName)
                Button("開始掃描") { startScan() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("請在灌漿前掃描，手機離地約 1 公尺、鏡頭朝下。")
            }
            .alert("錯誤", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("好") {}
            } message: {
                Text(errorText ?? "")
            }
            .fullScreenCover(item: $scanning, onDismiss: {
                store.reload()
                if let p = justScanned, let fresh = store.projects.first(where: { $0.dir == p.dir }),
                   !fresh.model.photos.isEmpty {
                    path = [fresh]
                }
                justScanned = nil
            }) { p in
                ScanView(project: p)
            }
        }
    }

    private func startScan() {
        do {
            let p = try store.create(name: newName)
            justScanned = p
            scanning = p
        } catch {
            errorText = error.localizedDescription
        }
    }
}
