# TUKONYA JP LangPack Updater

REAPERの日本語パッチを、配布元( https://stash.reaper.fm/v/50552/Japanese_add_SWS_kb_edit.zip )から自動で最新に保つスクリプト。
REAPER起動時に1日1回だけ確認し、新しい版が出ていれば差し替えます。
別の日本語パッチを使っている場合は、この配布元の版に切り替えます。
英語のまま使用している場合には何も行いません。

---

## 必要なもの

・REAPER バージョン7以降
・ReaPack https://reapack.com/

---

## 導入
①(他のツールで設定済の場合②へ)
[拡張→ReaPack→Import Repositories...]をクリックし、出た画面でこのアドレスを入力し[OK]
https://raw.githubusercontent.com/tuko1573/tukonya-scripts-reapack/main/index.xml

②
[拡張→ReaPack→Browse packages...]からFilter:に「tukonya」と検索。
「TUKONYA JP LangPack Updater」を[右クリック→Install]、[Apply]をクリック。

③
将来の更新は[拡張→ReaPack→Synchronize packages]で行えます。

---

## 使い方
[アクション→アクションリストを開く...]から「TUKONYA_JP LangPack Updater (Install Startup).lua」を実行してください。
その後はREAPER起動時に自動でスクリプトが働きます。

---

## ログ

問題が起きたときにAIへ見せるためのログです。

* 名前: JPLangPackUpdater.log
* 置き場: REAPERのリソースフォルダ（[オプション→REAPERのリソースフォルダを開く...]）
   * macOS: `~/Library/Application Support/REAPER/`
   * Windows: `%APPDATA%\REAPER\`
