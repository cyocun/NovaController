# NovaController - Claude Code ガイド

## プロジェクト概要
NovaStar MSD300 LEDコントローラーをmacOSから操作するSwiftUIネイティブアプリ。

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
