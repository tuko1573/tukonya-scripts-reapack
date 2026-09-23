# TUKONYA Team Plugin Checker

チームや仲間うちで、各自が持っているプラグインを共有フォルダに集め、
REAPERの中の小窓で「誰が何を持っているか」を検索・そのままトラックへ挿入できるツールです。

---

## 必要なもの

・REAPER バージョン7以降
・SWS/S&M https://www.sws-extension.org/
・ReaPack https://reapack.com/
・ReaImGui 0.10以降(ReaPack経由で導入可能)
[拡張→ReaPack→Browse packages...]からFilter:に「ReaImGui」と検索。
[ReaImGui: Reascript binding for Dear ImGui]、TypeがExtensionのものを[右クリック→Install]、[Apply]をクリック。

---

## 導入

①
[拡張→ReaPack→Import Repositories...]をクリックし、出た画面でこのアドレスを入力し[OK]
https://raw.githubusercontent.com/tuko1573/tukonya-scripts-reapack/main/index.xml

②
[拡張→ReaPack→Browse packages...]からFilter:に「tukonya」と検索。
「TUKONYA Team Plugin Checker」を[右クリック→Install]、[Apply]をクリック。

③
将来の更新は[拡張→ReaPack→Synchronize packages]で行えます。

---

## 共有フォルダの用意

チームで1つ、みんなが同期するフォルダを決めてください。中身は空で構いません。
Dropbox・Google Drive・OneDriveなど、メンバー全員が同じ場所を同期できればどれでも使えます。

---

## 初回設定

アクションリストから `Script: TUKONYA_Team Plugin Checker.lua` を実行します
（[アクション→アクションリストを開く...]で「TUKONYA_Team Plugin Checker」と検索すると出ます。
よく使うならショートカットキーを割り当てておくと便利です）。

初回だけ、ダイアログで次の3項目を聞かれます。

- **共有フォルダのパス**: 上で用意した共有フォルダを指定します。
- **メンバーID**: 半角の小文字英数字とアンダースコアのみ、1〜16文字（例: `taro`）。あとから変えられません
  （共有フォルダの中のファイル名になるため）。
- **表示名**: 画面に表示される名前です。日本語でもOKで、あとから設定タブで変更できます。

入れ終わると小窓が開きます。

---

## 使い方

### 検索タブ
プラグイン名で検索します。○＝持っている、△＝持っているが使用不可、×＝持っていない。
行をダブルクリックすると、REAPERで選択中のトラックに挿入されます。

### 整備タブ
自分だけ古い形式を使っているもの、使用不可として登録したもの、他のメンバーが持っている
無料プラグインなどを確認できます。

### 設定タブ
プロファイルの切り替え・追加・削除、共有フォルダの変更、表示名の変更、
「今すぐ更新」（自分の一覧を集め直して共有フォルダへ書く）、
「REAPER起動時の自動送信」の登録・解除をここで行います。

自分の一覧を最新に保つには、「REAPER起動時の自動送信」の**登録**を押しておくと、
以後はREAPER起動のたびに自動で共有フォルダへ書かれます
（設定タブから登録する代わりに、アクション `Script: TUKONYA_Team Plugin Checker (Install Startup).lua`
を実行しても同じことができます）。

---

## プロファイル（複数チームに入っている場合）

設定タブの「プロファイルを追加…」で、共有フォルダ・メンバーID・表示名の組をもう1つ作れます。
チームごとにプロファイルを切り替えて使ってください。

---

## 更新

[拡張→ReaPack→Synchronize packages]で最新版に入れ替わります。

---

## ログ

問題が起きたときにAIへ見せるためのログです。

- 名前: `TeamPluginChecker.log`
- 置き場: REAPERのリソースフォルダ（[オプション→REAPERのリソースフォルダを開く...]）
  - macOS: `~/Library/Application Support/REAPER/`
  - Windows: `%APPDATA%\REAPER\`
- 末尾200行だけ残ります。

---

## 旧「Shippo Blend Plugins」から移る人へ

1. ReaPackの[Browse packages...]で旧版（Shippo Blend Plugins）を右クリック→**Uninstall**。
2. 続けて本ツール（TUKONYA Team Plugin Checker）を**Install**→[Apply]。
3. 初回設定のダイアログが出ますが、旧版の設定（共有フォルダ・メンバーID・表示名）は
   自動で引き継がれます。共有フォルダはDropboxの「Shippo Blend」フォルダがそのまま使われます。
4. 設定タブで「REAPER起動時の自動送信」の**登録**を押し直してください。
   登録し直すと、旧版の仕込み（起動時ファイルの古い一塊）は自動で消えます。
