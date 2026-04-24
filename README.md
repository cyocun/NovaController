# NovaController

NovaStar **MSD300** LED コントローラーを macOS からネイティブに操作する SwiftUI アプリ。

Windows 専用の公式ツール **NovaLCT** を使わずに、Mac だけでレイアウトと輝度を設定できる。USBPcap で取得した通信ログをリバースエンジニアリングして独自に実装。

## 機能

- **レイアウトプリセット** — キャプチャ実機検証済みの 3 パターン
  - 4×1 左→右
  - 4×1 右→左
  - 2×4 S字
- **輝度調整** — 0-100% のドラッグ式 270° ゲージ、プリセット（0/25/50/75/100%）、スケジュール
- **自動 USB 接続** — 起動時に CP210x を検出してシリアルポートを開く
- **ネイティブ macOS UI** — SwiftUI で実装、リサイズ可能ウィンドウ

## 要件

- macOS 14 Sonoma 以降
- Xcode 15 以降（ビルドする場合）
- NovaStar MSD300 本体
- Silicon Labs CP210x VCP ドライバ（macOS 10.13 以降は標準搭載）

## ビルド

```bash
xcodebuild -project NovaController/NovaController.xcodeproj -scheme NovaController build
```

または `NovaController/NovaController.xcodeproj` を Xcode で開いて Run。

## プロジェクト構成

```
NovaController/
├── NovaController.xcodeproj/
└── NovaController/
    ├── NovaControllerApp.swift   # エントリポイント
    ├── ContentView.swift          # サイドバー・エラーバナー・接続ステータス
    ├── LayoutView.swift           # レイアウトプリセット UI + プレビュー
    ├── BrightnessView.swift       # 輝度調整 UI（円弧ゲージ）
    ├── USBManager.swift           # IOKit + CP210x シリアル通信、パケット組立
    └── Extensions.swift           # Color(hex:) 拡張
captures/                          # USBPcap キャプチャ (.pcap / .txt)
analysis/                          # プロトコル解析スクリプトとノート
novastar-msd300-notes.md           # パケット仕様 / レジスタマップ
```

## プロトコル概要

- 接続: Silicon Labs CP210x USB-UART Bridge (VID: `0x10C4`, PID: `0xEA60`)
- シリアル設定: 115200 baud, 8N1, フロー制御なし
- パケット: `55 AA` ヘッダ + 2B シーケンス + レジスタ R/W
- チェックサム: `(0x5555 + sum(payload)) & 0xFFFF` を LE 格納

詳細は [`novastar-msd300-notes.md`](./novastar-msd300-notes.md) と [`analysis/layout_protocol_analysis.md`](./analysis/layout_protocol_analysis.md) を参照。

## ステータス

| 機能 | 状態 | 備考 |
|------|------|------|
| 輝度調整 | ✅ 実装済み | 5 パケット検証済み |
| レイアウトプリセット | ✅ 実装済み | 3 パターン、キャプチャ完全一致 |
| 温度 / healthy 監視 | 🔲 未実装 | 要追加キャプチャ |
| 自動輝度（センサー連動） | 🔲 未実装 | 設計方針は `analysis/brightness_sensor_notes.md` |

## 関連リソース

- NovaStar 公式: <https://www.novastar.tech/>
- 参考実装:
  - [sarakusha/novastar](https://github.com/sarakusha/novastar)
  - [dietervansteenwegen/Novastar_MCTRL300_basic_controller](https://github.com/dietervansteenwegen/Novastar_MCTRL300_basic_controller)
