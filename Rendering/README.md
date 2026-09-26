# TUKONYA RENDER

つこが使うレンダー方式をひとつにまとめたスクリプト。
Macで動作確認済み。Windows と 96kHz のオーディオインターフェースでは未確認です。

**[2mix Render]**
2mixをwavとaac(mp3)で書き出し、圧縮音源にはディザーを使わない。
MASTERトラックにReaInsertが含まれる場合はハードウェア書き出しモードに移行し、最小限の負荷でオンラインバウンスを行うことで音途切れリスクを極限まで減らせます。

**[2mix Preview]**
2mix Renderに加え、透かし音声を入れてデータが完成品でないことを示すモード。

**[Para + 2mix]**
2mix Renderに加え、選択トラックのパラ出しを同時に行う。
REAPERのフォルダ構造のままに書き出されるため、データのフォルダ分けやリネームの手間を減らせます。
選択トラックの親トラックを遡り、サイドチェーン処理を全て有効化する機能を搭載(実験中)。
トラックを個別にソロして書き出すため、「ミュートされたトラックを処理しない」設定を使用している場合に時間を短縮可能。
「MASTER」トラックに入っているvst3プラグインの設定を.vstpresetとして書き出せます。

**[Hardware Print]**
REAPERの「選択メディア、マスター経由」で、rawトラックより上の全てのエフェクトをバイパスして書き出し、そのままプロジェクトに追加するモード。
rawトラック内に作ったフォルダ構造はcompressedトラック内に再現されます。
ボーカル等の下処理にハードウェアを通すことを想定しています。

**[Mastering]**
DDP、複数フォーマットのwav、AAC(mp3)の同時書き出しに対応。
同一フォルダ内に完成2mixの他instやminus1等別バージョンを配置すると同じ処理を通して自動で書き出せます。
CD-TEXT情報はスクリプトから記入が可能なほか、スプレッドシートの情報を直接コピーすることも可能。
https://docs.google.com/spreadsheets/d/1iKCHgF9pYBhRW_wEfzl_ZUpOZuDgvZpk-Vg-GIZw2Yo/copy
このタブだけ、最上位に「24bit Dither」「16bit Dither」という名前のトラック（フォルダにしない・ミュートしない・FXボタンは切っておく）を作り、それぞれにディザープラグインを載せておく必要があります。足りないときは窓が何を直すか教えてくれます。

各タブの設定は曲（プロジェクト）ごとに記憶されます。「既定として保存」を押すと、新しい曲でもその値から始まります。
実行するたびに実行記録（TUKONYA_Render_日付_時刻.log）がREAPERのリソースフォルダに残ります。止まったときは完了画面に出る文と、この記録を添えてください。

MASTERトラックにVST3以外のプラグインが入った瞬間に警告する「TUKONYA VST3 Only Master」も同じ目録から入れられます。併用をお勧めします。

---

> 必要なもの

・REAPER バージョン7以降
・SWS/S&M https://www.sws-extension.org/
・ReaPack https://reapack.com/
・ReaImGui 0.10以降(ReaPack経由で導入可能)
[拡張→ReaPack→Browse packages...]からFilter:に「ReaImGui」と検索。
[ReaImGui: Reascript binding for Dear ImGui]、TypeがExtensionのものを[右クリック→Install]、[Apply]をクリック。

---

> 使い方

①
[拡張→ReaPack→Import Repositories...]をクリックし、出た画面でこのアドレスを入力し[OK]
https://raw.githubusercontent.com/tuko1573/tukonya-scripts-reapack/main/index.xml

②
[拡張→ReaPack→Browse packages...]からFilter:に「tukonya」と検索。
「TUKONYA RENDER」を[右クリック→Install]、[Apply]をクリック。

③
[アクション→アクションリストを開く...→メニュー編集]をクリック、「Main File(ファイル)」タブで「追加→アクションを挿入...」を選択。TUKONYA_Render.luaを選択し、「レンダリング」の下あたりに順番を入れ替える

④
将来の更新は[拡張→ReaPack→Synchronize packages]で行えます。

---

> 動作の前提トラック

複雑な操作をスクリプトから行うため、フォルダ構造やトラックネームに前提があります。
[オプション→REAPER のリソースフォルダを開く...」で出たFinder(エクスプローラ)から、
Scripts/Tukonya Scripts/Rendering/template/
内に入っている「TUKONYA_RENDER_template.RPP」を使用してください。

普段の制作トラックは「2MIXBUS」の下層に展開してください。

この.RPPは今後の更新の際に上書きされるため、自身のプロジェクトで上書きしないでください。
スクリプトを動作させるため、普段のテンプレートに構造を組み込んでおくことをお勧めします。
