# CHANGELOG

本ファイルに各リリースの変更点を記録する。
バージョン番号は [Semantic Versioning](https://semver.org/) に準拠。

## [0.1.8] - 2026-04-24

### 修正
- **Sparkle インストーラエラーを修正**: v0.1.7 でアップデート検出まで
  は動いたが、Installer 実行時に「インストーラを起動中にエラー」で
  失敗していた。原因は App Sandbox 下での Sparkle Installer XPC の
  動作制限。Sandbox を無効化することで自動更新が完結するようにした。
- 個人配布 (App Store 非公開) のため Sandbox のメリット < 実利。
  CP210x シリアルアクセスも自由になる。
- `com.apple.security.app-sandbox` / `device.usb` / `device.serial`
  entitlement を削除。network.client も不要。

## [0.1.7] - 2026-04-24

### 修正
- **自動アップデート判定の不具合を修正**: v0.1.1〜v0.1.6 は全て
  `CFBundleVersion` が `1` で生成されていたため、Sparkle のバージョン
  比較で appcast の `<sparkle:version>0.1.X</sparkle:version>` と
  アプリ側の `1` が比較され、"1 > 0.1.X" と判定されて
  「最新版です」と誤表示されていた。
- `scripts/release.sh` でリリース毎に `CURRENT_PROJECT_VERSION` を
  Unix 時刻 (単調増加) で注入するよう変更し、appcast の
  `<sparkle:version>` にも同じ値を入れるよう修正。
- `<sparkle:shortVersionString>` には従来どおり `0.1.X` を入れる
  (ユーザー向けの表示はこちら)。

## [0.1.6] - 2026-04-24

### その他
- 新 Pages URL での自動アップデート動作検証。機能追加なし。

## [0.1.5] - 2026-04-24

### Changed
- UI テキストを英語をメインに変更 (sidebar / buttons / labels / menus /
  error messages / notifications)。日本語ローカライズは今後 String Catalog で
  対応する余地を残す。
- README を英語メインに。日本語版は `README.ja.md` に移動。

### Infrastructure
- GitHub リポジトリを `novaCLT4Mac` → `NovaController` に rename。
  プロジェクト名と揃えた。
- Sparkle SUFeedURL を新 Pages URL
  (`https://cyocun.github.io/NovaController/appcast.xml`) に更新。
- **旧 URL は 404 になるため、v0.1.4 以前のユーザーは自動アップデートを
  受け取れません。v0.1.5 以降は手動で zip をダウンロードして置き換えてください。**

## [0.1.4] - 2026-04-24

### その他
- 自動アップデート動作検証用のバージョン更新。機能追加なし。

## [0.1.3] - 2026-04-24

### 修正
- **起動クラッシュを修正**: v0.1.1 / v0.1.2 は ad-hoc 署名で
  Sparkle.framework との Team ID が食い違い dyld に拒否されて
  起動できなかった。`scripts/release.sh` で
  Sparkle.framework と内部 XPC / Autoupdate / Updater.app を
  階層的に ad-hoc 再署名し、その後アプリ本体も再署名するように修正。
- `scripts/release.sh`: pubDate の ロケール強制を
  `LC_TIME` から `LC_ALL` に変更 (macOS の LC_ALL=ja_JP.UTF-8 環境で
  LC_TIME=C が上書きされて日本語化されていた問題を解消)。

### 既知の問題
- **v0.1.1 / v0.1.2 は起動不可** です。既にインストール済みの方は
  自動アップデートが届かないので、本リリースの zip を手動で
  ダウンロードして `/Applications/NovaController.app` を置き換えてください。

## [0.1.2] - 2026-04-24

### 追加
- `CHANGELOG.md` を新設。以降のリリースはここに差分を記録する。

### 修正
- `scripts/release.sh` の `pubDate` 生成で `LC_TIME=C` を指定し、
  日本語ロケール環境で `pubDate` が Sparkle パースエラーになる問題を修正。

## [0.1.1] - 2026-04-24

### 追加
- Sparkle による自動アップデート機構を導入
  - アプリメニューに「アップデートを確認…」
  - 24 時間間隔で自動チェック
  - EdDSA 署名検証付き
- テストパターンタブ (⌘0–8 キーボードショートカット対応)
- ディスプレイモード切替 (通常 / フリーズ / ブラック、⌘⇧F/B/N)
- RGB ホワイトバランス調整
- パネル別輝度送信 (対象ボード選択)
- 接続時に実機から DeviceInfo (カード数 / 画面サイズ / 機種ID) を自動取得
- 監視タブの拡張: 温度・電圧の 24h 履歴、閾値設定、macOS 通知連携

### 変更
- SwiftUI View 層を `@Observable` マクロに移行
- Info.plist を手動管理に切り替え (`GENERATE_INFOPLIST_FILE = NO`)

## [0.1.0] - 2026-04-24

### 追加
- 初回プレビューリリース
- 輝度調整 UI (ドラッグ対応 270° ゲージ、プリセット、スケジュール UI)
- レイアウトプリセット (4×1 L→R / 4×1 R→L / 2×4 S字)
- 受信カード監視タブ (実機検証未完)
- 起動時の USB 自動接続、エラーバナー
