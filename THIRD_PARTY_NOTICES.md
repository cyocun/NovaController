# Third-Party Notices

NovaController は以下のサードパーティプロジェクトを参考にしています。
これらのプロジェクトはそれぞれ元のライセンスの下で配布されています。

---

## sarakusha/novastar

- リポジトリ: <https://github.com/sarakusha/novastar>
- ライセンス: MIT License
- 著作権: Copyright (c) 2019 Andrei Sarakeev

### 同梱ファイル
- `tools/wireshark/novastar.lua`
- `tools/wireshark/addressMapping.lua`
- `tools/wireshark/wireshark.lua`

上記は sarakusha/novastar の `wireshark/` ディレクトリからそのまま取得したもので、
開発時のプロトコル解析補助として同梱しています。変更は加えていません。

### 参照のみ
NovaStar デバイスのプロトコル仕様、受信カード監視 (`HWStatus`) のレジスタマップ、
および関連 API 構造体の参考に使用しています。該当部分を Swift に移植する際は、
該当ソースファイルの冒頭にも NOTICE コメントを記載します。

```
MIT License

Copyright (c) 2019 Andrei Sarakeev

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## dietervansteenwegen/Novastar_MCTRL300_basic_controller

- リポジトリ: <https://github.com/dietervansteenwegen/Novastar_MCTRL300_basic_controller>
- 参照用のプロトコル調査の比較対象として使用しています（コード流用はなし）。
