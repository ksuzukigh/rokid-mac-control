# Rokid Control

Rokid AI Glasses RV101の画面をMacに表示し、Macのマウスとキーボードで操作するアプリです。

![MacからRokid AI Glassesを操作するイメージ](docs/images/mac-control-overview.png)

最初にUSBケーブルで接続の準備をすると、次回からはWi-Fiで使えます。

## できること

- Rokidの画面をMacへ表示
- MacのマウスとキーボードでRokidを操作
- Wi-Fi接続と開発用USB接続の両方に対応

## あらかじめ用意するもの

- Rokid AI Glasses RV101
- macOS 11以降のMac（Apple Silicon、Intelの両方に対応）
- Rokid専用の開発用USBケーブル（5ピン）
- MacとRokidを同じネットワークへ接続できるWi-Fi環境
- Rokidのスマホアプリをインストールしたスマートフォン

Rokidを再起動した後もUSBケーブルを使わずに接続したい場合は、別アプリの[Wi-Fi ON](https://github.com/ksuzukigh/rokid-wifi-on)もRokidへ入れておきます。Wi-Fi ONは、再起動によってオフになったRokidのWi-Fiをオンへ戻すアプリです。

## Macにインストールする

### 1. DMGをダウンロードする

[Rokid Controlをダウンロード](https://github.com/ksuzukigh/rokid-mac-control/releases/latest/download/Rokid-Control.dmg)

ダウンロードした`Rokid-Control.dmg`をダブルクリックして開きます。

### 2. アプリケーションフォルダへコピーする

開いた画面で、`Rokid Control`のアイコンを`Applications`フォルダのアイコンへドラッグします。

コピーが終わったら、Finderの「アプリケーション」フォルダに`Rokid Control`があることを確認します。

### 3. 初めて起動する

初回だけ、Finderの「アプリケーション」フォルダにある`Rokid Control`を右クリックして「開く」を選びます。確認画面が表示されたら、もう一度「開く」を押します。

アプリの安全性を確認できないという警告が表示されて開けない場合は、警告画面を閉じます。続いてMacの「システム設定」→「プライバシーとセキュリティ」を開き、`Rokid Control`の「このまま開く」を押します。

### 4. キーボード操作を許可する

初回起動時に「キーボード操作の許可が必要です」と表示された場合は、Macの「システム設定」→「プライバシーとセキュリティ」→「アクセシビリティ」で`Rokid Control`をオンにします。

設定画面を閉じてから、`Rokid Control`をもう一度開きます。この許可は初回だけ必要です。

## Rokidと初めて接続する

最初の接続では、Rokid専用の開発用USBケーブル（5ピン）を使います。この接続によって、次回からWi-Fiで使うための準備も行われます。

1. スマートフォンでRokidのアプリを開き、開発者モード（ADB）を有効にします。
2. Rokidの電源を入れ、Rokid専用の開発用USBケーブル（5ピン）でMacとつなぎます。
3. RokidにUSB接続の確認が表示された場合は許可します。
4. Macで`Rokid Control`を開きます。
5. MacにRokidの画面が表示されるまで待ちます。接続には最大1分ほどかかることがあります。
6. 画面が表示されたら初回設定は完了です。USBケーブルを外して使えます。

## 普段の使い方

1. MacとRokidを同じWi-Fiへ接続します。
2. Macで`Rokid Control`を開きます。
3. Rokidの画面が表示されたら、画面を1回クリックして操作を始めます。

初回設定が済んでいれば、普段は開発用USBケーブルをつなぐ必要はありません。Rokid Controlの使用中にWi-Fiが一時的に切れた場合は、自動的に再接続します。

よく使う場合は、Rokid Controlの起動中にDockのアイコンを右クリックし、「オプション」→「Dockに追加」を選ぶと、次回からDockで起動できます。

## Rokidを再起動した後

Rokidを再起動すると、Wi-Fiがオフになることがあります。Wi-Fi ONを入れてある場合は、次の順番で接続します。

1. Rokidのアプリ一覧から「Wi-Fi ON」を開きます。
2. 「Wi-Fiはオンです」と表示されるまで待ちます。
3. Macで`Rokid Control`を開きます。

Wi-Fi ONをまだ入れていない場合や、この手順で接続できない場合は、Rokid専用の開発用USBケーブル（5ピン）でMacとRokidをつないでから`Rokid Control`を開きます。

## キーボード操作

Rokidの画面を1回クリックし、一番手前にしてから操作します。ほかのアプリを使っている間、キーはMacの通常操作になります。

| キー | 動作 |
| --- | --- |
| `←` / `→` | 上段のアプリアイコンを移動 |
| `Enter` | 決定・起動 |
| `Esc` | 一つ前へ戻る |
| `H` | 中央のHomeへ戻る |
| `Shift` + `←` | 下段左のメモを開く |
| `Shift` + `→` | 下段右のアプリ一覧を開く |
| `Space` | 画面中央をタップ |
| 素早く`Space` 2回 | 画面中央をダブルタップ |

## うまく接続できないとき

次の順番で確認します。

1. MacとRokidが同じWi-Fiへ接続されているか確認します。
2. Rokidで「Wi-Fi ON」を開き、「Wi-Fiはオンです」と表示されるまで待ってから、`Rokid Control`を開き直します。
3. それでも接続できない場合は、Rokid専用の開発用USBケーブル（5ピン）でMacとRokidをつなぎ、`Rokid Control`を開き直します。
4. RokidにUSB接続の確認が表示された場合は許可します。

## キーが動かないとき

1. Macに表示されているRokidの画面を1回クリックします。
2. 改善しない場合は、Macの「システム設定」→「プライバシーとセキュリティ」→「アクセシビリティ」を開き、`Rokid Control`がオンになっているか確認します。

## 終了する

Macに表示されているRokidの画面の左上にある赤いボタンを押します。画面表示、キーボード操作、Wi-Fiの自動再接続がまとめて終了します。

## 削除する

Rokid Controlを終了してから、Macの「アプリケーション」フォルダにある`Rokid Control`をゴミ箱へ入れます。

## プライバシー

- 画面と操作データは、同じWi-Fi内のMacとRokidの間で直接送受信します。
- クラウドサービスへ画面や操作データを送りません。
- 前回接続したRokidの接続先はMac内だけに保存します。

## 関連アプリ

- [Wi-Fi ON](https://github.com/ksuzukigh/rokid-wifi-on)：RokidのWi-Fiをオンへ戻します。
- [Photo to Mac](https://github.com/ksuzukigh/rokid-photo-to-mac)：Rokidで撮影した写真をMacへ送ります。

## 参考と謝辞

本アプリは、bcefghjさんが公開している[rokid-glasses-control](https://github.com/bcefghj/rokid-collection/tree/main/rokid-glasses-control)を参考に開発しました。

本アプリには、[scrcpy](https://github.com/Genymobile/scrcpy)とAndroid Platform ToolsのADBを同梱しています。ライセンスと著作権表示はアプリ内の`Licenses`フォルダに収録しています。

<details>
<summary>開発者向け情報</summary>

### ビルド

Xcode Command Line Toolsが入ったMacで、次を実行します。

```sh
./build_dmg.sh
```

初回は公式scrcpy 4.1のmacOS版をダウンロードし、SHA-256を照合します。完成したアプリとDMGは`build`フォルダへ作成されます。

アプリ本体とキーボード制御はSwiftで実装しています。ADB、scrcpy、scrcpy-serverはアプリ内のファイルだけを使用します。

</details>
