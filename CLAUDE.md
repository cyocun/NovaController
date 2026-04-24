# NovaController - Claude Code ガイド

## プロジェクト概要
NovaStar MSD300 LEDコントローラーをmacOSから操作するSwiftUIネイティブアプリ。
MSD300 専用。将来の他機種対応は未定だが、`ReadControllerModelId` (addr=2, 2B)
で厳密に機種判別する余地は残してある。

## 技術スタック
- Swift / SwiftUI
- macOS 14 Sonoma以降
- Xcode 15以降
- IOKit (シリアル通信 via CP210x USB-UART)

## プロジェクト構成
```
NovaController/
├── NovaController.xcodeproj/
└── NovaController/
    ├── NovaControllerApp.swift   # エントリポイント
    ├── ContentView.swift          # メインレイアウト+サイドバー
    ├── LayoutView.swift           # キャビネット配置エディター+スキャン方向+共有コンポーネント
    ├── BrightnessView.swift       # 輝度調整UI
    ├── Extensions.swift           # Color(hex:) 拡張
    ├── USBManager.swift           # シリアル通信マネージャー（IOKit + CP210x）
    ├── NovaController.entitlements # App Sandbox + USB権限
    └── Assets.xcassets/           # アプリアイコン、AccentColor
captures/                          # USBPcapキャプチャファイル (.pcap)
analysis/                          # プロトコル解析スクリプト
novastar-msd300-notes.md           # プロトコルリバースエンジニアリングノート
```

## カラーパレット
- サイドバー背景: `#16213e` / ヘッダー: `#1a1a2e`
- アクセント: `#0f3460` / グラデーション終端: `#e94560`
- コンテンツ背景: `#f5f6fa` / グリッド背景: `#e8ecf0`
- 成功: `#27ae60` / ボーダー: `#b2bec3`

## ビルド
```bash
xcodebuild -project NovaController/NovaController.xcodeproj -scheme NovaController build
```

## MSD300 通信プロトコル (USBPcapキャプチャで確認済み)
- **接続**: Silicon Labs CP210x USB-UART (VID:0x10C4, PID:0xEA60)
- **シリアル設定**: 115200 baud, 8N1, フロー制御なし
- **パケット**: `55 AA` ヘッダー + 2B シーケンス番号 + レジスタR/W
- **チェックサム**: `0x5555 + sum(payload)` のLE16格納
- **詳細**: `novastar-msd300-notes.md` 参照

## 参考ライブラリ
- **[sarakusha/novastar](https://github.com/sarakusha/novastar)** (TypeScript, MIT)
  - NovaLCT の .NET バイナリをデコンパイルして自動生成した包括的な API ラッパー
  - `packages/native/generated/AddressMapping.ts` に全レジスタ名・アドレス・Occupancy が列挙されている
  - 新機能を足すときはキャプチャを取る前にまずここを引くと時短
  - Wireshark dissector (`wireshark/novastar.lua`) も同梱、本プロジェクトの `tools/wireshark/` と併用可

## レジスタ名対応表 (キャプチャ ↔ 公式 = sarakusha/novastar)
| アドレス | 用途 | 公式 AddressMapping 名 |
|---|---|---|
| `0x02000001` | 全体輝度 (1B) | `GlobalBrightnessAddr` |
| `0x020001E3` | R/G/B/V 輝度 (4B) | `FourSystemAdaptiveBrightnessAddr` |
| `0x02000017` | キャビネット幅 (受信カード側) | `ControlWidthAddr` |
| `0x02000019` | キャビネット高さ (受信カード側) | `ControlHeightAddr` |
| `0x02000024/26` | Area1 幅/高さ (送信カード側) | `DviWidthAddr` / `DviHeightAddr` |
| `0x02000028/2A` | Area1 オフセット X/Y | `DviOffsetXAddr` / `DviOffsetYAddr` |
| `0x0200002C` | Area1 stride | `RealDviWidthAddr` |
| `0x02000050` | Area3 ポート有効 | `PortEnableAddr` |
| `0x02000051/53` | Area3 ポート幅/高さ | `PortWidthAddr` / `PortHeightAddr` |
| `0x02000055/57` | Area3 ポート X/Y | `PortOffsetXAddr` / `PortOffsetYAddr` |
| `0x020000F0` | 仮想マップ (1B) | `VirtualMapAddrNew` |
| `0x020001EC` | 画面全体サイズ (4B) | `SenderVideoEnclosingAddr` |
| `0x02020020` | マッピング前アロケート (64B) | `SenderFunctionAddr` |
| `0x03000000` | マッピングテーブル base | `Sender_scannerCoordinateBase` / `EthernetPortScannerXAddr` |
| `0x03100000` | カード数 (cols × rows) | `Sender_NetworkInterfaceCardNumber` |
| `0x01000012` | パラメータ再計算コマンド `[0xAA]` | `RecaculateParameterAddr` ← **「設定確定」だった** |
| `0x01000088` | スキャンマッピング系 | `ScannerMappingAddr` |

マッピングテーブル: 4B/エントリ `[X_LE16][Y_LE16]`、1 ポート分 = `EthernetPortOccupancy = 0x1000` = 1024 エントリ。256B×16 ブロックで書き込むのは実装都合。

## 実装状況
- [x] UIレイアウト（サイドバー+コンテンツ）
- [x] キャビネット配置グリッドエディター
- [x] スキャン方向選択UI（左→右/右→左/上→下/S字）
- [x] 輝度調整メーター+スライダー
- [x] USBManager シリアル通信（IOKit, CP210x自動検出）
- [x] USBManager のView統合（ConnectionStatusView/LayoutView/BrightnessView接続済み）
- [x] 実機でのVendor/Product ID確認 (VID:0x10C4, PID:0xEA60)
- [x] MSD300プロトコル実装 — 輝度コマンド (キャプチャ検証済み)
- [x] MSD300プロトコル実装 — チェックサムアルゴリズム (5パケット検証済み)
- [x] レイアウトコマンド動的生成 (setLayout) — 任意のcols/rows/方向に対応
- [x] レイアウトキャプチャ — 4×1 左→右 / 4×1 右→左 / 2×4 S字パターン
- [x] マッピングテーブル解析 — 4B/エントリ形式、座標パターン確認済み
- [x] スキャン方向対応 — L→R / R→L / 上→下 / S字 (キャプチャ検証済み)
- [ ] エラーハンドリング（接続断時のUI表示）
- [ ] 実機テスト（macOS + MSD300接続）
- [ ] 自動輝度（センサー連動） — UI削除済み。実装方針は `analysis/brightness_sensor_notes.md` 参照
