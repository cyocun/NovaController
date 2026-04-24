# Wireshark Dissector for NovaStar Protocol

NovaStar シリアルプロトコルを Wireshark で自動デコードするための Lua dissector。
キャプチャした USB / シリアルトラフィックを `novastar` プロトコルとして認識し、
各フィールド (header / seq / device type / port / board / register / data / checksum) を
展開して表示する。新しい機能のリバースエンジニアリング時に強力。

## 起源 / ライセンス

これらのファイルは [sarakusha/novastar](https://github.com/sarakusha/novastar) の
`wireshark/` ディレクトリから取得したもの（MIT License, Copyright (c) 2019 Andrei Sarakeev）。
リポジトリ内で変更は加えていない。ライセンス全文は [`../../THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md) を参照。

## ファイル構成

| ファイル | 用途 |
|---|---|
| `novastar.lua` | プロトコル dissector 本体（Wireshark にロード） |
| `addressMapping.lua` | レジスタアドレスから名称を引くテーブル |
| `wireshark.lua` | Wireshark Lua API の型定義（EmmyLua 形式、エディタ補完用、実行には不要） |

## セットアップ (macOS)

### 1. Wireshark をインストール
```bash
brew install --cask wireshark
```

### 2. Lua プラグインを有効化
個人プラグインフォルダを作成してシンボリックリンクを張る:

```bash
mkdir -p ~/.local/lib/wireshark/plugins
ln -sf "$(pwd)/tools/wireshark/novastar.lua" ~/.local/lib/wireshark/plugins/
ln -sf "$(pwd)/tools/wireshark/addressMapping.lua" ~/.local/lib/wireshark/plugins/
```

### 3. Wireshark を再起動
「Analyze → Reload Lua Plugins」でも OK。

## 使い方

1. Mac で USB キャプチャを取得（Apple の `PacketLogger.app` か、
   `/Applications/Utilities/Console.app` + `tcpdump -i XHC20` など。
   Windows なら USBPcap が簡単）。
2. `.pcap` / `.pcapng` を Wireshark で開く。
3. フィルタに `novastar` と入れると、NovaStar パケットだけが残る。
4. 各パケットを選択すると、展開ツリーに以下のフィールドが表示される:
   - Header (Request / Response)
   - Sequence No.
   - Source / Destination
   - Device Type / Port / Board Index
   - Register (名称込み)
   - Data 長 / Data
   - CRC

## 推奨プロファイル

Wireshark の「Profile」を **Classic** または **No Reassembly** に切り替えておくと、
デフォルトの再組立て処理と干渉せずに見やすくなる（sarakusha 公式 README の推奨）。

## 参考

- 元リポジトリの説明: <https://github.com/sarakusha/novastar#wireshark-luadissector->
