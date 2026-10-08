# TUKONYA Container Link

同じ「Link Ch」を選んだコンテナ同士で、中のプラグインの並び・つまみ・バイパス・オートメーション・コンテナの名前をリンクすることができます。
Leaderトラックを決める必要がなく、どのトラックで触っても全員に反映されるのが特徴です。
Reaperネイティブ動作のため、wavesのようなプラグインでも相性問題が出ません。
(VST3/JSFXは問題ないと思われますが、AUについては不具合が出る可能性があります)

---

> 必要なもの

・REAPER バージョン7.79以降
・ReaPack https://reapack.com/
・js_ReaScriptAPI
　[拡張→ReaPack→Browse packages...]からFilter:に「js_ReaScriptAPI」と検索。
　「js_ReaScriptAPI: API functions for ReaScripts」を[右クリック→Install]、[Apply]をクリックし、REAPERを再起動。

---

> 導入

①(他のツールで設定済の場合②へ)
[拡張→ReaPack→Import Repositories...]をクリックし、出た画面でこのアドレスを入力し[OK]
https://raw.githubusercontent.com/tuko1573/tukonya-scripts-reapack/main/index.xml

②
[拡張→ReaPack→Browse packages...]からFilter:に「tukonya」と検索。
「TUKONYA Container Link」を[右クリック→Install]、[Apply]をクリック。

③
将来の更新は[拡張→ReaPack→Synchronize packages]で行えます。

---

> 自動起動の設定

①
[アクション→アクションリストを開く...]の検索欄に「tukonya」と入力し、
「TUKONYA_Container Link (Install Startup)」を選んで[実行]。

②
自動起動をやめたいときは、「TUKONYA_Container Link (Uninstall Startup)」を実行してください。

---

> 使い方

①
リンクしたいトラックにコンテナを作り、コンテナの中に「TUKONYA Container Link」を挿して、同じ Link Ch を選ぶ。
「Link Ch」をクリックすると現在のリンク一覧が開きます。名前の変更は右クリックでも可能です。

②
空のコンテナでも、同じ Link Ch を選べば同じプラグインと設定が入ります。

③
目印の画面の[LINK]ボタン、またはアクション「TUKONYA_Container Link - LINK (selected track)」で、そのトラックのコンテナを正として、同じ Link Ch のコンテナを強制的に同期できます。
