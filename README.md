# Rokid Control

Rokid AI Glasses RV101の文字やアイコンをMacに表示し、Macのマウスとキーボードで操作するアプリです。Rokidのカメラが捉えた映像を背景にした表示も選べます。

![MacからRokid AI Glassesを操作するイメージ](docs/images/mac-control-overview.png)

初回はUSBケーブルで接続します。2回目以降はWi-Fiで接続できます。

現在の正式版は**1.1.0**です。更新内容は[変更履歴](CHANGELOG.md)で確認できます。

## できること

- Rokidの画面をMacに表示
- カメラのライブ映像に、Rokidの文字やアイコンを重ねて表示
- 「ライブ映像」と「背景なし（省電力）」を起動時に選択
- 文字やアイコンの見やすさをスライダーで調整
- MacのマウスとキーボードでRokidを操作
- Wi-Fi接続と開発用USB接続の両方に対応
- Photo to Macの撮影後にライブ映像を自動復帰

### ライブ映像

カメラの映像を背景にして、Rokidの文字やアイコンを重ねて表示します。

![ライブ映像を背景にしてRokidの文字やアイコンを表示した例](docs/images/rokid-control-live-view.png)

この画面は、Rokidをかけた人が実際に見ている視界そのものではありません。Rokidのカメラが捉えた範囲（視界の一部）に、文字やアイコンをMac上で重ねたものです。

### 背景なし（省電力）

ライブ映像を使わず、黒い背景にRokidの文字やアイコンを表示します。電池消費を抑えたいときに適しています。

![背景なし（省電力）でRokidの文字やアイコンを表示した例](docs/images/rokid-control-connected.png)

## あらかじめ用意するもの

- Rokid AI Glasses RV101
- macOS 12.3以降のMac（Apple Silicon、Intelの両方に対応）
- Rokid専用の開発用USBケーブル（5ピン、別売）
- MacとRokidを同じWi-Fiに接続できる環境
- Rokidのスマホアプリをインストール済みのスマートフォン

Rokid AI Glasses RV101に付属する3ピンのUSBケーブルは充電専用で、Macとの接続には使用できません。開発用USBケーブル（5ピン）は別売です。入手できない場合は、購入した販売店またはRokidの開発者向け窓口へ「RV101用の5ピン開発ケーブル」についてお問い合わせください。

Rokidを再起動した後もUSBケーブルを使わずに接続したい場合は、別アプリの[Wi-Fi ON](https://github.com/ksuzukigh/rokid-wifi-on)もRokidにインストールしておきます。Wi-Fi ONは、再起動後にRokidのWi-Fi接続をオンにするアプリです。

## Macにインストールする

### 1. DMGをダウンロードする

[Rokid Controlをダウンロード](https://github.com/ksuzukigh/rokid-mac-control/releases/latest/download/Rokid-Control.dmg)

ダウンロードした`Rokid-Control.dmg`をダブルクリックして開きます。

### 2. アプリケーションフォルダへコピーする

表示されたウインドウで、`Rokid Control`のアイコンを`Applications`フォルダにドラッグします。

コピーが終わったら、Finderの「アプリケーション」フォルダに`Rokid Control`があることを確認します。

## Rokidと初めて接続する

最初の接続では、Rokid専用の開発用USBケーブル（5ピン）を使います。このとき、次回からWi-Fiで接続するための設定も自動で行われます。

### 1. RokidをUSBでつなぐ

1. スマートフォンでRokidのアプリを開き、開発者モード（ADB）を有効にします。
2. Rokidの電源を入れ、Rokid専用の開発用USBケーブル（5ピン）でMacとつなぎます。

### 2. Rokid Controlを初めて起動する

1. Finderの「アプリケーション」フォルダにある`Rokid Control`を右クリックし、「開く」を選びます。
2. 「“Rokid Control.app” は開いていません」と表示されたら、「ゴミ箱に入れる」は押さず、「完了」を押します。
3. Macのメニューから「システム設定」を開きます。
4. 左側の「プライバシーとセキュリティ」を選び、一番下までスクロールします。
5. 「セキュリティ」に表示された`Rokid Control`の「開く」を押します。
6. 確認画面で「このまま開く」を押し、Macのログインパスワードを入力します。
7. Finderの「アプリケーション」フォルダに戻り、`Rokid Control`をもう一度開きます。

「開く」は、`Rokid Control`を開こうとしてから約1時間表示されます。詳しくは[Apple公式の説明](https://support.apple.com/ja-jp/guide/mac-help/mh40617/mac)を参照してください。

### 3. キーボード操作を許可する

「キーボード操作の許可が必要です」と表示された場合は、Macの「システム設定」→「プライバシーとセキュリティ」→「アクセシビリティ」で`Rokid Control`をオンにします。

設定画面を閉じてから、`Rokid Control`をもう一度開きます。この許可は初回だけ必要です。

### 4. ライブ映像を許可する

起動時に「ライブ映像」を選んだ場合、初回だけ画面収録の許可を求められます。

「画面収録の許可が必要です」と表示されたら、Macの「システム設定」→「プライバシーとセキュリティ」→「画面とシステムオーディオ録音」で`Rokid Control`をオンにします。

設定画面を閉じてから、`Rokid Control`をもう一度開きます。「背景なし（省電力）」だけを使う場合、この許可は不要です。

### 5. 接続を確認する

1. Rokid側にUSB接続の確認が表示された場合は許可します。
2. 「ライブ映像」または「背景なし（省電力）」を選びます。
3. 接続待ち画面に表示される進捗を確認します。接続には最大1分ほどかかることがあり、待つのをやめる場合は「キャンセル」を押せます。

Macに画面が表示されたら接続完了です。以降はUSBケーブルを外して、Wi-Fiで接続できます。

## 普段の使い方

1. MacとRokidを同じWi-Fiに接続します。
2. Macで`Rokid Control`を開きます。
3. 背景を選びます。
4. 画面が表示されたら、ウインドウ内を1回クリックして操作を始めます。

初回設定が済んでいれば、普段は開発用USBケーブルをつなぐ必要はありません。Rokid Controlの使用中にWi-Fiが一時的に切れた場合は、自動的に再接続します。

よく使う場合は、Rokid Controlの起動中にDockのアイコンを右クリックし、「オプション」→「Dockに追加」を選ぶと、以後はDockから起動できます。

## 背景を選ぶ

起動時に、次のいずれかを選びます。

- **ライブ映像**：カメラの映像を背景に表示します。文字やアイコンの見やすさは、画面上部のスライダーで調整できます。
- **背景なし（省電力）**：黒い背景で表示します。ライブ映像を使わないため、電池消費を抑えられます。

ライブ映像はカメラを継続して使用するため、背景なし（省電力）よりRokidの電池を多く消費します。必要なときだけ使用し、使い終わったらウインドウを閉じてください。

背景を変更する場合は、Rokid Controlを一度終了し、開き直して別の背景を選びます。

Photo to Macで撮影すると、撮影中だけライブ映像が一時停止します。撮影後は自動的にライブ映像へ戻ります。

## Rokidを再起動した後

Rokidを再起動すると、Wi-Fi接続がオフになることがあります。Wi-Fi ONをインストールしている場合は、次の順番で接続します。

1. Rokidのアプリ一覧から「Wi-Fi ON」を開きます。
2. 「Wi-Fiはオンです」と表示されるまで待ちます。
3. Macで`Rokid Control`を開きます。

Wi-Fi ONをインストールしていない場合や、この手順で接続できない場合は、Rokid専用の開発用USBケーブル（5ピン）でMacとRokidをつないでから`Rokid Control`を開きます。

## キーボード操作

Macに表示されたRokidのウインドウ内を1回クリックしてから操作します。ほかのアプリを選んでいる間は、キーがそのアプリに入力されます。

> **操作仕様を変更しました（2026年7月27日）**
>
> 従来の`Shift` + `←` / `→`で下段左右を直接開く操作は廃止しました。現在は`↓`で下段へ移動し、`←` / `→`でメモ・Home・アプリ一覧を順番に選べます。選択中の項目は、Mac上のRokid画面に表示される水色の枠で確認できます。

| キー | 動作 |
| --- | --- |
| `←` / `→` | 選択中の段でアイコンを移動 |
| `↓` | ホーム画面で下段へ移動 |
| `↑` | 下段から上段へ戻る |
| `Enter` | 決定・起動 |
| `Esc` | 一つ前に戻る |
| `H` | ホーム画面に戻り、中央のHomeを開く |
| `Space` | 画面中央をタップ |
| 素早く`Space` 2回 | 画面中央をダブルタップ |

ホーム画面で`↓`を押すと、Macに表示されたRokid画面上で下段中央のHomeに選択枠が付きます。`←` / `→`で「メモ」「Home」「アプリ一覧」を選び、`Enter`で開きます。`↑`または`Esc`で上段へ戻ります。ホーム以外の画面では、上下左右キーを通常の方向キーとして送ります。

## うまく接続できないとき

次の順番で確認します。

1. MacとRokidが同じWi-Fiに接続されているか確認します。
2. Rokidで「Wi-Fi ON」を開き、「Wi-Fiはオンです」と表示されるまで待ってから、`Rokid Control`を開き直します。
3. それでも接続できない場合は、Rokid専用の開発用USBケーブル（5ピン）でMacとRokidをつなぎ、`Rokid Control`を開き直します。
4. Rokid側にUSB接続の確認が表示された場合は許可します。

## キーが動かないとき

1. Macに表示されているRokidのウインドウ内を1回クリックします。
2. 改善しない場合は、Macの「システム設定」→「プライバシーとセキュリティ」→「アクセシビリティ」を開き、`Rokid Control`がオンになっているか確認します。

## ライブ映像が真っ黒のとき

1. Macの「システム設定」→「プライバシーとセキュリティ」→「画面とシステムオーディオ録音」で`Rokid Control`がオンになっているか確認します。
2. Rokidでカメラを使用している別のアプリを終了し、Rokid Controlを開き直します。
3. 改善しない場合は、背景なし（省電力）が表示できるか確認します。

## 電池が急に減る・カメラが使えないとき

Rokid Controlを開き直すと、前回の異常終了で残った同梱版scrcpyを自動的に終了します。それでも改善しない場合は、Macの「アクティビティモニタ」で`Rokid Control`内の`scrcpy`を終了するか、Macを再起動してください。

## ウインドウを閉じても終了できないとき

メニューバーの「Rokid Control」→「Rokid Controlを終了」を選ぶか、`⌘Q`を押します。Wi-Fi切断が繰り返される場合は、自動再接続を止める確認画面が表示されます。

## 不具合を報告するとき

ログは`~/Library/Logs/Rokid Control.log`に保存されます。不具合が起きた時刻と、可能であればこのログを添えてください。ログが2MBを超えると、直前のログは`Rokid Control.1.log`として1世代だけ残ります。

## 終了する

Rokidのウインドウ左上にある赤いボタンを押して閉じます。Rokid Controlも同時に終了します。メニューバーの「Rokid Controlを終了」または`⌘Q`でも終了できます。

## 削除する

Rokid Controlを終了してから、Macの「アプリケーション」フォルダにある`Rokid Control`をゴミ箱へ入れます。

接続履歴や設定、ログも消す場合は、Finderの「移動」→「フォルダへ移動」で次の場所を順に開き、該当するファイルまたはフォルダをゴミ箱へ入れます。

- `~/Library/Application Support/Rokid Control`
- `~/Library/Preferences/io.github.ksuzukigh.rokid-mac-control.plist`
- `~/Library/Logs/Rokid Control.log`
- `~/Library/Logs/Rokid Control.1.log`

## プライバシー

- 画面と操作データは、同じWi-Fiに接続しているMacとRokidの間で直接送受信します。
- ライブ映像もMacとRokidの間だけで送受信します。
- 画面や操作データをクラウドへ送信しません。
- 前回の接続情報はMacにのみ保存します。
- Rokid Controlは、キーボード操作をRokidへ送るためにアクセシビリティの許可を使用します。対象はRokidの画面を表示しているウインドウに向けられたキーだけです。ほかのアプリで入力した文字は素通しし、記録も送信もしません。
- ログには、押された操作キーの種類（矢印・決定など）が記録されます。文字入力の内容は含まれません。
- 初回のUSB接続時に、Rokid側でWi-Fi経由の開発者接続（ADB）を有効にします。この設定はRokidを再起動するまで有効です。公共のWi-Fiへ接続する場合は、Rokidを一度再起動してからつなぐことをおすすめします。

## ライセンス

本アプリのソースコードは[Apache License 2.0](LICENSE)で公開しています。同梱しているscrcpyとAndroid Platform Toolsのライセンスは、アプリ内の`Licenses`フォルダに収録しています。

## 関連アプリ

- [Wi-Fi ON](https://github.com/ksuzukigh/rokid-wifi-on)：RokidのWi-Fi接続をオンにします。
- [Photo to Mac](https://github.com/ksuzukigh/rokid-photo-to-mac)：Rokidで撮影した写真をMacに送ります。

## 参考と謝辞

本アプリ開発のきっかけは、bcefghjさんが公開している[rokid-glasses-control](https://github.com/bcefghj/rokid-collection/tree/main/rokid-glasses-control)でした。Rokid AI GlassesをMacから操作するという着想を得られたことに感謝します。

その後、Rokid AI Glasses RV101での実機検証を重ね、接続・操作・配布の仕組みを全面的に見直し、Swift製のMacアプリとして独自に再構築しました。

本アプリには、[scrcpy](https://github.com/Genymobile/scrcpy)とAndroid Platform ToolsのADBを同梱しています。ライセンスと著作権表示はアプリ内の`Licenses`フォルダに収録しています。

<details>
<summary>開発者向け情報</summary>

### ビルド

公開DMGはApple Developer ProgramによるDeveloper ID署名・公証を行っていないため、初回起動時に「プライバシーとセキュリティ」から開く手順が必要です。

Xcode Command Line Toolsが入ったMacで、次を実行します。

```sh
./build_dmg.sh
```

初回は公式scrcpy 4.1のmacOS版をダウンロードし、SHA-256を照合します。完成したアプリとDMGは`build`フォルダに作成されます。

アプリ本体とキーボード制御はSwiftで実装しています。ADB、scrcpy、scrcpy-serverはアプリ内のファイルだけを使用します。

ライブ映像の合成だけを確認する場合は、Rokidを接続せずに次を実行できます。

```sh
./run_self_test.sh
```

模擬カメラ画像と模擬文字・アイコンを合成した`build/vision-compositor-self-test.png`が作成され、画像サイズ、明るさ、緑色HUDの有無を自動判定します。ProcessRunnerの大量出力とタイムアウト処理も同時に確認します。

</details>
