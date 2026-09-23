# TUKONYA VST3 Only Master

「TUKONYA RENDER」のPara + 2mix書き出しモードでマスターチェーンを書き出す際、VST3以外のプラグインは.vstpresetを書き出せません。
このツールは「MASTER」トラックを常に監視し、VST3以外のプラグインがインサートされた時に警告を出し、同名のVST3プラグインが存在する場合はその場で置き換えることができます。

---

> 必要なもの

・REAPER バージョン7以降
・ReaPack https://reapack.com/

---

> 導入

①(他のツールで設定済の場合②へ)
[拡張→ReaPack→Import Repositories...]をクリックし、出た画面でこのアドレスを入力し[OK]
https://raw.githubusercontent.com/tuko1573/tukonya-scripts-reapack/main/index.xml

②
[拡張→ReaPack→Browse packages...]からFilter:に「tukonya」と検索。
「TUKONYA_VST3 Only Master」を[右クリック→Install]、[Apply]をクリック。

③
将来の更新は[拡張→ReaPack→Synchronize packages]で行えます。

---

> 自動起動の設定

①
[アクション→アクションリストを開く...]の検索欄に「tukonya」と入力し、
「TUKONYA_VST3 Only Master (Install Startup).lua」を選んで[実行]。

②
「REAPER起動時に見張りが自動で始まるように登録しました」と出れば完了です。

③
自動起動をやめたいときは、「TUKONYA_VST3 Only Master (Uninstall Startup).lua」を実行してください。


---

> 備考

プロジェクトを開いた時点ですでにインサートされているプラグイン、ReaInsertは監視の対象外になります。
