# TUKONYA Folder Link / Folder Toggle

REAPER のフォルダの開閉を、編集画面（TCP）とミキサーの両方でリンクするスクリプト。

> TUKONYA_Folder Toggle
選択トラックのフォルダを、編集画面とミキサーの両方で閉じる／開くスクリプト。ショートカットで叩く時向け。
> TUKONYA_Folder Link
編集画面とミキサー双方を監視し、フォルダ開閉状況を自動でリンクする常駐スクリプト。

---

> 必要なもの

・REAPER バージョン7.79以降
・ReaPack https://reapack.com/

---

> 導入

①(他のツールで設定済の場合②へ)
[拡張→ReaPack→Import Repositories...]をクリックし、出た画面でこのアドレスを入力し[OK]
https://raw.githubusercontent.com/tuko1573/tukonya-scripts-reapack/main/index.xml

②
[拡張→ReaPack→Browse packages...]からFilter:に「tukonya」と検索。
「TUKONYA Folder Link」を[右クリック→Install]、[Apply]をクリック。

③
将来の更新は[拡張→ReaPack→Synchronize packages]で行えます。

---

> 自動起動の設定

①
[アクション→アクションリストを開く...]の検索欄に「tukonya」と入力し、
「TUKONYA_Folder Link (Install Startup)」を選んで[実行]。

②
自動起動をやめたいときは、「TUKONYA_Folder Link (Uninstall Startup)」を実行してください。
