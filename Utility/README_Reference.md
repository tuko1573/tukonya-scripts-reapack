# TUKONYA Reference Track

マスターアウト1/2の出力を別のチャンネルで鳴っている音に置き換えます。リファレンストラックをシームレスにチェックすることを想定しています。
ソロやミュートを使わないため、Solo Safeの邪魔をせず、動作も極めて低負荷でスムーズです。
画面に「REFERENCE」とウィンドウを表示するため、ごくわずかな差を追い込む際にも作業中とリファレンスどちらを聴いているか迷いません。

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
「TUKONYA Reference Track」を[右クリック→Install]、[Apply]をクリック。

③
将来の更新は[拡張→ReaPack→Synchronize packages]で行えます。

---

> 自動起動の設定

①
[アクション→アクションリストを開く...]の検索欄に「tukonya」と入力し、
「TUKONYA_Reference Display (Install Startup)」を選んで[実行]。
REAPER起動時から「REFERENCE」ウィンドウの表示が有効になります。

②
自動起動をやめたいときは、「TUKONYA_Reference Display (Uninstall Startup)」を実行してください。

---

> 使い方

①
リファレンスとして使うトラックを選択した後、アクションリストから「TUKONYA_Reference Setup」を実行。
「モニタリングFX」に切り替え用のルーターが入ります
※マスターフェーダーのメーターが鬱陶しい場合にはメーターを右クリックして「マルチチャンネルピークメーター」をオフにすると2chのみの監視に戻せます

②
「TUKONYA_Reference Toggle」にショートカットを割り当てて使用してください。
押すたびに 作業中 ⇄ リファレンス が切り替わります。
Stream Deck の場合は「ホットキー」で同じショートカットを送ってください。ボタンを点灯させたい場合はReaLearnの連携が必要です(ネイティブアプリが使用できなくなります)

