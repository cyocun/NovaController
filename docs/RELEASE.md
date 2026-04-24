# リリース手順

NovaController のリリース運用ガイド。Sparkle による自動アップデートを前提にしている。

## 初回セットアップ (一度だけ)

### 1. EdDSA 鍵ペアを生成

Sparkle SPM が提供する `generate_keys` を使う（プロジェクトを一度 Xcode で開く / `xcodebuild build` 実行後に SPM 成果物が取得される）。

```bash
SPARKLE_BIN="$HOME/Library/Developer/Xcode/DerivedData/NovaController-etbqxnqvoegqekeapnuhotcqtemj/SourcePackages/artifacts/sparkle/Sparkle/bin"
$SPARKLE_BIN/generate_keys
```

- 秘密鍵は macOS Keychain に自動登録される（アクセス許可を求められたら許可）
- 公開鍵が標準出力に表示される（Base64 の文字列）

### 2. 公開鍵を Info.plist にセット

`NovaController/NovaController/Info.plist` の `SUPublicEDKey` を、上で得た公開鍵で置き換える。

```xml
<key>SUPublicEDKey</key>
<string>（ここに公開鍵）</string>
```

### 3. SUFeedURL を実サイトに合わせる

デフォルトは `https://cyocun.github.io/novaCLT4Mac/appcast.xml` を前提にしている。
GitHub Pages を有効化していない場合は設定する:

- GitHub リポジトリの Settings → Pages
- Source: `main` branch / `docs` folder を選択して Save
- しばらくすると上記 URL が有効になる

SUFeedURL を別 URL に変える場合は Info.plist を更新。

### 4. 既存秘密鍵を別マシンに移す場合

```bash
$SPARKLE_BIN/generate_keys -x private.key
# private.key を安全な方法で転送
$SPARKLE_BIN/generate_keys -f private.key
rm private.key
```

## 毎回のリリース

### 1. プロジェクトの MARKETING_VERSION を更新

`NovaController/NovaController.xcodeproj/project.pbxproj` 内の
`MARKETING_VERSION = x.y.z` を新しい版に書き換え、commit しておく。

### 2. リリーススクリプト実行

```bash
scripts/release.sh 0.1.1
```

スクリプトは以下を自動で行う:

1. Release build を実行
2. `NovaController-v0.1.1-macOS.zip` を生成
3. `sign_update` で EdDSA 署名
4. git tag + push
5. `gh release create` で GitHub Release 作成 & zip 添付
6. `appcast.xml` に追加すべき `<item>` エントリを標準出力に表示

### 3. appcast.xml を更新

スクリプトの最後に表示された `<item>` ブロックを
`docs/appcast.xml` の `<channel>` 内先頭に貼り付け、commit & push する:

```bash
git add docs/appcast.xml
git commit -m "appcast: release v0.1.1"
git push
```

GitHub Pages が数分で再ビルドされ、既存ユーザーは次回の自動チェック
（既定 24 時間間隔、またはメニュー「アップデートを確認…」）で更新を受け取る。

## ビルド番号 (CURRENT_PROJECT_VERSION)

リリース毎に `CURRENT_PROJECT_VERSION` を +1 すると丁寧（Sparkle は
`sparkle:version` を見るので必須ではないが、Finder の「Get Info」で
正しく区別できる）。

## トラブルシューティング

### sign_update が "no private key found"
`generate_keys` が Keychain に書いた鍵が見つからない。以下を確認:
- 別ユーザーアカウントで実行していないか
- Keychain Access で "ed25519 private key" エントリがあるか

### Sparkle がサンドボックスで警告
サンドボックスでは XPC 無しの installer を使うため、
`com.apple.security.network.client` Entitlement が必要。
`NovaController.entitlements` に追加済み。

### 「アップデートを確認」メニューがグレー
`Info.plist` の `SUFeedURL` / `SUPublicEDKey` が未設定 or 無効。
鍵ペア生成と公開鍵の貼り替えを再確認。
