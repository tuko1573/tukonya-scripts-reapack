# TUKONYA RENDER

つこが使うレンダー方式をひとつにまとめたスクリプト。

[2mix Render]
2mixをwavとaac(mp3)で書き出し、圧縮音源にはディザーを使わない。
MASTERトラックにReaInsertが含まれる場合はハードウェア書き出しモードに移行し、最小限の負荷でオンラインバウンスを行うことで音途切れリスクを極限まで減らせます。

[2mix Preview]
2mix Renderに加え、透かし音声を入れてデータが完成品でないことを示すモード。

[Para + 2mix]
2mix Renderに加え、選択トラックのパラ出しを同時に行う。
REAPERのフォルダ構造のままに書き出されるため、出したパラデータのフォルダ分けやリネームの手間を減らせます。
REAPER標準の「マスター経由」バウンスで反映されない、選択トラックの親トラックのサイドチェーン入力を有効化する機能を搭載(実験中)。
トラックを個別にソロして書き出すため、「ミュートされたトラックを処理しない」設定を使用している場合書き出し時間を大幅に短縮可能。
「MASTER」トラックに入っているvst3プラグインの設定を.vstpresetとして書き出せます。

[Hardware Print]
REAPERの「選択メディア、マスター経由」を、rawトラックより上の階層の全てのエフェクトをバイパスして行い、書き出しトラックをプロジェクトに追加するモード。
rawトラック内に作ったフォルダ構造はそのまま「compressed」トラック内に再現されます。
ボーカル等の下処理にハードウェアを通すことを想定しています。

---

## 必要なもの

・REAPER バージョン7以降
・SWS/S&M https://www.sws-extension.org/
・ReaPack https://reapack.com/
・ReaImGui 0.10以降(ReaPack経由で導入可能)
[拡張→ReaPack→Browse packages...]からFilter:に「ReaImGui」と検索。
[ReaImGui: Reascript binding for Dear ImGui]、TypeがExtensionのものを[右クリック→Install]、[Apply]をクリック。

---

## 使い方

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

## 動作の前提トラック

複雑な操作をスクリプトから行うため、フォルダ構造やトラックネームに前提があります。
[オプション→REAPER のリソースフォルダを開く...」で出たFinder(エクスプローラ)から、
Scripts/Tukonya Scripts/Rendering/template/
内に入っている「TUKONYA_RENDER_template.RPP」を使用してください。

普段の制作トラックは「2MIXBUS」の下層に展開してください。

この.RPPは今後の更新の際に上書きされるため、自身のプロジェクトで上書きしないでください。
スクリプトを動作させるため、普段のテンプレートに構造を組み込んでおくことをお勧めします。

---

## ログ

実行するたびに生成されるログ。問題をAIに解決させる場合に。

- 名前: `TUKONYA_Render_<日付>_<時刻>.log`
- 置き場: REAPERのリソースフォルダ
  - macOS: `~/Library/Application Support/REAPER/`
  - Windows: `%APPDATA%\REAPER\`
