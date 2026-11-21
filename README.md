# floor-scan 地板掃描

灌漿前用 iPhone（LiDAR）掃描樓板，產生**有比例尺的正上方俯視平面圖**，記錄埋在混凝土裡的管路位置。

## 功能（v0.1）

- **LiDAR 定位拍照**：每張照片都記錄手機在空間中的位置與朝向
- **補拍提示**：地板切成 10 cm 網格
  - 🟥 紅色：LiDAR 掃到、但還沒有合格照片
  - 🟩 綠色：已拍好
  - 畫面上直接疊加紅綠格，右上角有小地圖
- **自動拍照**：手機穩定、鏡頭朝下、且畫面有足夠的新區域時自動拍
- **產生平面圖**：所有照片投影到地板平面，拼成俯視圖
  - PNG：含 1 m 格線、刻度、比例尺
  - PDF：A3 固定比例（例如 1:50），列印時選「實際大小」即可用比例尺量測
- **原始資料匯出**：照片＋定位資料打包成 zip

## 使用方式

1. 開啟 App → 右上角「＋」→ 輸入名稱 → 開始掃描
2. 畫面中央十字對準地板 → 按「設定地板」（有時會自動偵測）
3. 手機離地約 1 公尺、鏡頭朝下，慢慢走，把紅色格子拍成綠色
4. 按「完成」→「產生平面圖」→ 分享或儲存 PNG / PDF

**拍攝建議**：光線充足、走慢一點、避免強烈反光。

## 限制

- 平面圖方向以開始掃描時的手機朝向為準（不是正北）
- 高出地板的物體（例如架高的鋼筋、管線）在俯視圖上會有些微位移，越靠近照片邊緣越明顯
- 一次掃描須一次完成，目前無法中斷後接續
- 大面積掃描時定位誤差會累積

## 安裝（Windows + Sideloadly，免費 Apple ID）

### 1. 下載安裝檔
1. 打開本 repo 的 **Actions** 分頁
2. 點最新一次成功（綠勾）的 **Build IPA**
3. 下方 **Artifacts** 下載 `FloorScan-ipa`，解壓縮得到 `FloorScan.ipa`

### 2. 準備 Windows 電腦
1. 從 Apple 官網安裝 **iTunes** 和 **iCloud**（不要用 Microsoft Store 版本）
2. 安裝 **Sideloadly**：https://sideloadly.io

### 3. 安裝到 iPhone
1. 用傳輸線連接 iPhone，iPhone 上按「信任這部電腦」
2. 打開 Sideloadly，把 `FloorScan.ipa` 拖進去
3. 輸入你的 Apple ID → 按 **Start**
4. iPhone：**設定 → 隱私權與安全性 → 開發者模式** → 開啟（需重新開機）
5. iPhone：**設定 → 一般 → VPN 與裝置管理** → 信任你的 Apple ID

> 免費 Apple ID 安裝的 App **每 7 天**要用 Sideloadly 重新安裝一次（資料會保留）。

## 開發

- SwiftUI + ARKit + RealityKit + Core Image，iOS 17 以上
- 專案檔由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 從 `project.yml` 產生
- GitHub Actions（macOS）自動編譯未簽章的 `.ipa`，Sideloadly 安裝時再簽章

| 檔案 | 用途 |
|---|---|
| `FloorScan/ScanSession.swift` | AR 追蹤、地板偵測、自動拍照、紅綠格疊加 |
| `FloorScan/Geometry.swift` | 相機射線與地板交點、照片投影範圍 |
| `FloorScan/CoverageGrid.swift` | 覆蓋網格 |
| `FloorScan/MosaicRenderer.swift` | 照片拼接、PNG / PDF 輸出 |
| `FloorScan/ScanView.swift` | 掃描畫面與小地圖 |
| `FloorScan/ProjectDetailView.swift` | 專案頁、平面圖檢視與分享 |
