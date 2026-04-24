# 輝度センサー連動 — 将来実装用の設計メモ

> **ステータス**: UI は削除済み（2026-04-24）。機能自体は未実装。
> 将来実装する際はこのドキュメントを参照して UI / ロジックを復活させる。

## UI 削除の経緯
- 2026-04-24: `BrightnessView` の「自動輝度（センサー連動）」トグルはダミーで動作しなかったため、ユーザー判断で UI から削除。
- ただし **要件としては将来実装する前提**なので、このノートに仕様と実装方針を保存する。

## 概要
照度センサーで環境光を測定し、MSD300 の輝度を自動調整する。

## MSD300 側で必要なこと
**結論: MSD300 自体に照度センサー入力機能はない**（キャプチャ解析でも該当レジスタ無し）。
したがって、外部デバイスでセンサー値を取得し、そこから `setBrightness()` 相当のコマンドを送る必要がある。

## 実装方式の選択肢

### 方式A: Mac 内蔵センサー → Mac アプリ → MSD300 (推奨度: 低)
- 接続: `AppleLMUController` (IOKit) → NovaController → CP210x → MSD300
- 利点: 追加ハードウェア不要
- 課題: デスクトップ Mac には非搭載、センサー位置が LED パネルと離れる

### 方式B: 外部 I²C センサー + USB Arduino/ESP32 → Mac → MSD300 (推奨度: 高)
- 接続: BH1750 → Arduino/ESP32 → USB Serial → Mac アプリ → CP210x → MSD300
- 利点: Mac アプリでスケジュールや輝度カーブと統合可能、センサー位置は自由
- 課題: Mac の常時起動が必要
- **推奨実装**: `SensorSerialReader` クラスを USBManager とは別に作り、定期的に lux 値を読み取って `USBManager.shared.setBrightness()` を呼ぶ

### 方式C: ESP32 単体で MSD300 に直結 (Mac 不要)
- 接続: ESP32-S3 (USB Host) → CP210x → MSD300
- 利点: Mac 不要でスタンドアロン動作
- 課題: Mac アプリと同時接続不可（シリアルポート排他）、ESP32 側で輝度コマンド実装が必要

## MSD300 輝度コマンド (確定済み, 参考)

### パケット1: グローバル輝度
```
55 AA [seq_hi seq_lo] FE 00 01 FF FF FF 01 00 01 00 00 02 01 00 [brightness] [chk_lo chk_hi]
```
- brightness: 0x00 (0%) 〜 0xFF (100%)

### パケット2: RGB 輝度 (毎回セットで送信)
```
55 AA [seq_hi seq_lo] FE 00 01 FF FF FF 01 00 E3 01 00 02 04 00 F0 F0 F0 00 [chk_lo chk_hi]
```
- RGB = 0xF0, 0xF0, 0xF0 (輝度変更時は固定値)

### チェックサム計算
```
checksum = (0x5555 + sum(bytes[2:-2])) & 0xFFFF   # LE 格納
```

### シリアル設定
- 115200 baud, 8N1, フロー制御なし
- CP210x USB-UART (VID:0x10C4, PID:0xEA60)

## ESP32 直接制御のファームウェア要件 (方式C)
1. USB Host 初期化 (CP210x ドライバ)
2. シリアル設定: 115200/8N1
3. I²C 照度センサー読み取り (BH1750: アドレス 0x23)
4. lux → brightness (0x00-0xFF) 変換テーブル
5. 輝度コマンド 2 パケット生成・送信
6. シーケンス番号管理 (送信ごとに+1)
7. 送信間隔: 変化検出時のみ、最小間隔 500 ms 程度

## 推奨センサー
| 型番 | I/F | レンジ | 特徴 |
|---|---|---|---|
| BH1750 | I²C | 1-65535 lux | 安価、ライブラリ豊富 |
| TSL2561 | I²C | 広ダイナミックレンジ | 赤外線補正対応 |
| VEML7700 | I²C | 16bit | 低消費電力 |

## 未確定の設計事項
- lux → brightness の変換カーブ (線形 / 対数 / シグモイド)
- ヒステリシス (チラつき防止の不感帯幅)
- 最小/最大輝度のリミッター
- Mac / ESP32 のどちらで最終実装するか

## 再実装するときに復活させる UI (BrightnessView)
削除した `SettingsSection(title: "自動輝度")` ブロックの骨子:

```swift
SettingsSection(title: "自動輝度") {
    Toggle("センサー連動", isOn: $autoMode)
        .font(.system(size: 12))
    if autoMode {
        Text("外部センサーに連動して自動的に輝度を調整します")
            .font(.system(size: 10))
            .foregroundColor(.secondary)
    }
}
```

`@State private var autoMode: Bool = false` を戻し、`autoMode` が `true` のとき
スライダ / ±ボタン / プリセットを `disabled` にする処理を併せて復活させる。
