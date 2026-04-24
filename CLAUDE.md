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
| `0x02000100` | ブラックアウト (1B) | — |
| `0x02000101` | テストパターン (1B) | — |
| `0x02000102` | フリーズ (1B) | — |
| `0x00000002` | コントローラ機種ID (2B) | `ReadControllerModelId` |
| `0x020001EC` | 画面サイズ W,H LE16 (4B) | `SenderVideoEnclosingAddr` |

## プロトコル詳細 (実機ログから確定)

### 応答パケット形式 (mctrl300.py 準拠)
```
AA 55 [ack] [serno_low] FE [src] [devtype] [port] [board_lo board_hi]
[dir] [reserved] [reg LE 4B] [len LE 2B] [data...] [chk_lo chk_hi]
```
- `bytes[2]` = **ACK バイト** (0x00 = 成功 / 非ゼロ = エラー)。**seq の上位バイトではない**
- `bytes[3]` = serno の下位 1 バイト (送信時 UInt16 serno の下位を返す)
- 送信時 serno マッチングは bytes[3] と `(serno & 0xFF)` で行う

### Read コマンドの board アドレス
- **送信カード側レジスタを Read するときは board=0x0000 必須**
- board=0xFFFF (Write 時のデフォルト) で Read を投げると ACK=0x05 (エラー) が返る
- 例: brightness Read を board=0xFFFF で送るとエラー応答、board=0x0000 で正常応答

### ストリーム受信処理
- UART は本来ストリーム。応答が連結/分割されて届くため、`rxBuffer: [UInt8]` に蓄積し
  ヘッダ AA 55 + 長さフィールド (`bytes[16..17]`) で 1 パケットずつ切り出す
- **`Data.removeFirst(n)` は内部 startIndex を進めるだけで、その後 `data[0]` が範囲外
  アクセス → クラッシュ**。バッファは `[UInt8]` 配列で持つこと

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
- [x] テストパターン (9種: 赤/緑/青/白/横縞/縦縞/斜線/グレー/解除)
  - reg `0x02000101` に 1 バイト書込み (companion-module / MCTRL300 Python 解析)
- [x] ディスプレイモード (通常/フリーズ/ブラック)
  - blackout `0x02000100` / freeze `0x02000102`、Normal は連続 3 バイトで一括クリア
- [x] RGB ホワイトバランス + パネル別輝度送信
  - `setBrightness(_:r:g:b:board:)`。`board` 指定時は dest=受信カード、deviceType=0x01 で送る
- [x] 接続時の輝度自動読み戻し (`currentBrightness` / `currentRGB` を Observable で公開)
- [x] キーボードショートカット (⌘0–8 = パターン / ⌘⇧F/B/N = モード) — 「表示」メニュー
- [x] 監視タブ拡張
  - 24 時間の温度・電圧履歴 (in-memory、`HealthMonitor`)
  - カード行に温度スパークライン (閾値超過時は赤線)
  - 閾値はユーザー設定可 (温度上限 / 電圧範囲 / モジュールエラー通知トグル)、`UserDefaults` に永続化
  - 閾値超過で macOS 通知センターに通知。同一異常継続中は再通知しない (アラート解消後の再発で再通知)
- [x] 接続時に実機から DeviceInfo (cards/screen/modelId) を自動取得 — 表示に反映
- [ ] エラーハンドリング（接続断時のUI表示）
- [ ] 実機テスト（macOS + MSD300接続）
- [ ] 受信カード監視 (`readCardHealth`) の応答が来ない問題
  - 現状: reg=`0x0A000000` (`Scanner_AllMonitorDataAddr`) に dest=0xFF + devtype=0x01 +
    board=N + port=0x00 + len=82 で投げているが、実機 (MSD300 + 受信カード 1 枚接続) で
    応答が一切返らない。 ACK エラーすらなく完全沈黙
  - 候補: (a) レジスタ番地違い (b) 受信カード監視機能が機種依存 (c) 別フォーマット必要
  - 解決には NovaLCT で実機の Card Monitor 機能を操作したキャプチャが必要
- [ ] 自動輝度（センサー連動） — UI削除済み。実装方針は `analysis/brightness_sensor_notes.md` 参照
- [ ] フレーム遅延補正（受信カード別にフレーム遅延を加算して同期ズレを解消）
  - NovaLCT の Screen Settings → Advanced にある "Frame Delay" 相当
  - レジスタ未解析。NovaLCT で該当操作を USBPcap キャプチャ → `analysis/` で diff 取る流れ
  - `sarakusha/novastar` の `AddressMapping.ts` を先に grep して候補アドレス絞ると時短
  - 用途: 板ごとに 1〜数フレーム遅れているパネルの辻褄合わせ
