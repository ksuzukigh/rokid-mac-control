# Rokid Control

Rokid Glasses RV101の画面をMacに表示し、マウスとキーボードで操作するアプリです。

![MacからRokid Glassesを操作するイメージ](docs/images/mac-control-overview.png)

## できること

- Rokidの画面をMacへ表示
- MacのマウスとキーボードでRokidを操作
- Wi-Fi接続と開発用USB接続の両方に対応

Apple SiliconとIntelの両方のMacに対応しています。対応OSはmacOS 11以降です。

## ダウンロード

[Rokid Controlをダウンロード](https://github.com/ksuzukigh/rokid-mac-control/releases/latest/download/Rokid-Control.dmg)

## インストール

1. ダウンロードした`Rokid-Control.dmg`を開きます。
2. `Rokid Control`を`Applications`へドラッグします。
3. DMGを取り出します。
4. Macの「アプリケーション」から`Rokid Control`を開きます。

初回にMacがアプリを止めた場合は、`Rokid Control`を右クリックして「開く」を選び、確認画面でもう一度「開く」を押してください。

「キーボード操作の許可が必要です」と表示された場合は、開いた設定画面で`Rokid Control`をオンにしてから、アプリをもう一度開きます。

## 最初の接続

最初のインストール前に、Rokidのスマホアプリで開発者モードを有効にしておきます。

1. MacとRokidを開発用5ピンケーブルでつなぎます。
2. `Rokid Control`を開きます。
3. RokidにUSB接続の確認が表示された場合は許可します。
4. MacにRokidの画面が表示されたら、ケーブルを外して使えます。

## 普段の使い方

1. MacとRokidを同じWi-Fiへつなぎます。
2. `Rokid Control`を開きます。
3. 表示されたRokidの画面を1回クリックして操作します。

普段は開発用5ピンケーブルをつなぐ必要はありません。

Rokidを再起動した後は、Rokidで「Wi-Fi ON」を一度開いてから`Rokid Control`を起動します。それでも接続できない場合だけ、開発用5ピンケーブルをつないで再実行してください。

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

## Wi-Fiの自動復旧

`Rokid Control`を開いている間は、RokidのWi-Fiが一時的に切れても接続と画面表示を自動で復旧します。

Rokidの画面を閉じると自動復旧も終了し、Rokid本来の省電力動作へ戻ります。

起動前からWi-Fiが完全にオフの場合は、別公開の[Wi-Fi ON](https://github.com/ksuzukigh/rokid-wifi-on)を利用できます。

## うまく動かないとき

- 画面が開かない：MacとRokidが同じWi-Fiにつながっているか確認します。Rokidで「Wi-Fi ON」を開いてから再実行します。
- それでも接続できない：開発用5ピンケーブルをつなぎ、Rokid側のUSB接続確認を許可して再実行します。
- キーが動かない：Rokidの画面をクリックして一番手前にします。改善しない場合は、Macの「システム設定」→「プライバシーとセキュリティ」→「アクセシビリティ」で`Rokid Control`がオンか確認します。
- 黒い`exec`がDockに出る：旧版の履歴です。最新版では画面表示部がDockへ別表示されません。

## 終了と削除

Rokidの画面を閉じると、画面表示、キーボード操作、Wi-Fi自動復旧がまとめて終了します。

削除する場合は、Rokidの画面を閉じてから「アプリケーション」フォルダの`Rokid Control`をゴミ箱へ入れます。

接続先の記録も消す場合は、`ホーム`→`ライブラリ`→`Application Support`→`Rokid Control`フォルダを削除します。

## プライバシー

- 画面と操作データは、同じWi-Fi内のMacとRokidの間で直接送受信します。
- クラウドサービスへ画面や操作データを送りません。
- 前回接続したRokidの接続先はMac内だけに保存します。

## 対応状況

Rokid Glasses RV101の実機で、次の項目を確認しています。

- DMGからのインストール
- HomebrewとPythonを使わない起動
- Wi-Fi接続と再接続
- Rokid再起動後の接続先変更への追従
- 画面表示、マウス、キーボード操作
- Dockへ不要な黒いアイコンを表示しないこと
- 終了後に接続処理を残さないこと

他のRokid製品での動作は未確認です。

写真をMacへ直接送りたい場合は、別公開の[Photo to Mac](https://github.com/ksuzukigh/rokid-photo-to-mac)を利用できます。

## 参考と謝辞

このツールは、bcefghjさんが公開している[rokid-glasses-control](https://github.com/bcefghj/rokid-collection/tree/main/rokid-glasses-control)を参考に開発しました。

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
