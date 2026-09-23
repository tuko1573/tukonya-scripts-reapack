# TUKONYA JP LangPack Updater

REAPERの日本語パッチ（ReaperLangPack）を、配布元から自動で最新に保つスクリプト。
REAPER起動時に1日1回だけ確認し、新しい版が出ていれば差し替えます（反映は次回起動から）。
別の日本語パッチを使っている場合は、この配布元の版に切り替えます。

配布元: https://stash.reaper.fm/50552/Japanese_add_SWS_kb_edit.zip

---

## 必要なもの

・REAPER バージョン7以降
・ReaPack https://reapack.com/

---

## 導入

①
[拡張→ReaPack→Import Repositories...]をクリックし、出た画面でこのアドレスを入力し[OK]
https://raw.githubusercontent.com/tuko1573/tukonya-scripts-reapack/main/index.xml

②
[拡張→ReaPack→Browse packages...]からFilter:に「tukonya」と検索。
「TUKONYA JP LangPack Updater」を[右クリック→Install]、[Apply]をクリック。

③
将来の更新は[拡張→ReaPack→Synchronize packages]で行えます。

---

## 使い方

・最初に1回だけ、アクションリストから「TUKONYA_JP LangPack Updater (Install Startup).lua」を実行してください。
  次回のREAPER起動から、1日1回の自動確認が始まります。
  もう一度実行すると、登録を外すかどうかを聞かれます。

・今すぐ確認したいときは「TUKONYA_JP LangPack Updater.lua」を実行してください。
  1日1回の制限を無視して確認し、結果を必ず知らせます。

---

## 注意

・今まで使っていた言語ファイルは消しません。切り替えたときも元のファイルは LangPack フォルダに残ります。
  差し替え前の版は LangPack/.update に3つまで残します。
・英語のまま使っている人（言語パッチを選んでいない人）には何もしません。
・自動確認の登録は Scripts/__startup.lua に印つきの数行を書くだけです。他のスクリプトの記述には触りません。

---

## ログ

- 名前: `JPLangPackUpdater.log`（最後の200行だけ残します）
- 置き場: REAPERのリソースフォルダ
  - macOS: `~/Library/Application Support/REAPER/`
  - Windows: `%APPDATA%\REAPER\`
