--[[
  ref_text.lua
  TUKONYA Reference — 画面に出る文字はすべてここ（1つの表、ID 付き。日本語のみ）。
  各項目: def(ID, いつ出るか, 文面)。
  %s / %d は後から値が入る場所（入れ替えたり消したりしないこと。順番は変えない）。
  画面に出る文.md は tests/gen_screens_doc.lua が、実際のコードを動かして作る。
--]]
local M = {}
local T = {}
M.T = T
M.order = {}
M.trace = nil       -- 試験・文書生成用: 表を引いた ID を順に記録する（通常は nil）

local function def(id, when, ja)
  T[id] = { when = when, ja = ja }
  M.order[#M.order + 1] = id
end

--- 文面。引数があれば %s / %d に入れる。
function M.ja(id, ...)
  local e = assert(T[id], "ref_text: unknown id " .. tostring(id))
  if M.trace then M.trace[#M.trace + 1] = id end
  if select("#", ...) > 0 then return e.ja:format(...) end
  return e.ja
end


-- ===== WINDOW =====
def("WINDOW_TITLE", "REFERENCE 窓のタイトル（窓の上の帯）。",
    "Reference")
def("WINDOW_TEXT", "リファレンスを聴いている間、窓いっぱいに大きく出る文字。",
    "REFERENCE")

-- ===== TITLE =====
def("TITLE_MAIN", "Toggle・Install/Uninstall Startup のダイアログの見出し。",
    "TUKONYA Reference")
def("TITLE_SETUP", "Setup のダイアログの見出し。",
    "TUKONYA Reference Setup")

-- ===== MSG =====
def("MSG_NO_ROUTER", "Toggle を押したが、マスターのモニターFXにリファレンス用ルーターが見つからないとき。",
    "リファレンス用のルーターが見つかりません。先に「TUKONYA_Reference Setup」を実行してください。")

-- ===== HINT =====
def("HINT", "Toggle でリファレンスに切り替えたとき、このプロジェクトがまだ鳴らせる状態でない場合に出る窓の文（理由の行は付けない）。",
    "このプロジェクトはリファレンス用の設定が行われていないようです。\nリファレンス用トラックを選んで「TUKONYA_Reference Setup」を実行してください。")

-- ===== MENU =====
def("MENU_USED", "メニューの各行の後ろ。そのチャンネルが今のプロジェクトで既に使われているとき。%s = 使っているトラック名など。",
    "使用中: %s")
def("MENU_MORE", "「使用中」の名前が3つ以上あるとき、2つ目のあとに付く。%d = 残りの数。",
    "他%d")
def("MENU_CURRENT", "メニューの行の後ろ。いま動いているルーターが使っているチャンネル。",
    "（今の設定）")
def("MENU_WHO_HWOUT", "「使用中」の中で、ハードウェア出力が使っているときの呼び名。",
    "ハードウェア出力")

-- ===== CONFIRM =====
def("CONFIRM_HEAD", "Setup の確認の窓の最初の行。",
    "次の内容を行っていいですか？")
def("CONFIRM_INSERT", "確認の窓。ルーターが無くて新しく追加するとき。",
    "・マスターのモニターFXの1番目に「JS: IX/PhaseAdjustingRouter」と、その直後に「TUKONYA Reference Track Eater」を追加")
def("CONFIRM_OTHER_ROUTER", "確認ダイアログ。設定の違う IX ルーターが既に有るとき（それは触らない）。",
    "  （設定の違う IX ルーターが既にありますが、そのまま残します。触りません）")
def("CONFIRM_REPOINT", "確認ダイアログ。既存のルーターが別のチャンネルを使っていて、選んだチャンネルへ付け替えるとき。%s = 古い組、%s = 新しい組。",
    "・今のルーターの入力を %s から %s に変更（直後の Eater も同じ組に合わせる）\n  ※ルーターは REAPER 全体で共通です。ほかのプロジェクトも新しい組で設定し直す必要があります。")
def("CONFIRM_ADD_EATER", "確認ダイアログ。付け替えのとき、ルーターの直後に Eater が無くて追加するとき。",
    "・ルーターの直後に「TUKONYA Reference Track Eater」を追加")
def("CONFIRM_RAISE", "確認ダイアログ。マスターのチャンネル数を増やすとき。%d = 今の数、%d = 増やした後の数。",
    "・マスターのチャンネル数を %d から %d に増やす")
def("CONFIRM_HWOUT", "確認ダイアログ。マスターにハードウェア出力を足すとき。%s = チャンネルの組（例: 3/4）。",
    "・マスターに、%s ch → 出力 %s のハードウェア出力を追加")
def("CONFIRM_TRACKS", "確認ダイアログ。選択中のトラックのマスターセンドを付け替えるとき。%s = トラック名、%s = チャンネルの組。",
    "・選択中のトラック %s のマスターセンドを %s ch にする")
def("CONFIRM_SKIPPED", "確認ダイアログ。フォルダの中のトラックを選んでいたとき（送り先が親になるので触らない）。%s = トラック名。",
    "・フォルダの中のトラック %s は送り先が親になるため変更しません")
def("CONFIRM_NOSEND", "確認ダイアログ。選んだトラックのマスターへの送りが切ってあるとき。%s = トラック名。",
    "・注意: %s はマスター/親への送りが切ってあります（そのままにします）")
def("CONFIRM_NOTRACK", "確認ダイアログ。トラックが1本も選ばれていないとき。",
    "・トラックが選ばれていないので、センドの設定は行いません（リファレンス用トラックを選んで再実行できます）")

-- ===== NOTHING =====
def("NOTHING_TO_DO", "Setup を実行したが、すべて設定済みで何もすることが無いとき。",
    "すでに設定済みです。リファレンス用トラックを選んで実行すると、そのセンドを選んだチャンネルにします。")

-- ===== DONE =====
def("DONE_HEAD", "結果の窓の最初の行（Setup を実行して変更したあと）。",
    "実行しました。")
def("DONE_OTHER_ROUTER", "完了のお知らせ。設定の違う IX ルーターが既にあって、それは触らず新しいものを追加したとき。",
    "設定の違う IX ルーターが既にあったため、そちらは触らず、新しいものを追加しました。")
def("DONE_ROUTER_FAIL", "完了のお知らせ。ルーターを追加できなかったとき（JSFX が無い、など）。",
    "ルーターを追加できませんでした。JSFX「IX/PhaseAdjustingRouter」(IXix) が入っているか確認してください。入っているのに追加できないときは、マスターのモニターFX（表示メニュー > モニタリングFX）に自分で追加し、入力 %s / 出力 1+2 / Replace にしてバイパスにしてください。")
def("DONE_EATER_FAIL", "完了のお知らせ。Eater を追加できなかったとき（JSFX が無い、など）。",
    "Eater を追加できませんでした。JSFX「TUKONYA Reference Track Eater」が入っているか確認してください。")
def("DONE_REPOINT", "完了のお知らせ。既存のルーター（と Eater）のチャンネルを付け替えたとき。%s = 古い組、%s = 新しい組。",
    "ルーターの入力を %s から %s に変更しました。")
def("DONE_RAISED", "結果の窓。マスターのチャンネル数を増やしたとき。%d = 増やした後の数。",
    "マスターが%dchになりました。")
def("DONE_HWOUT", "完了のお知らせ。ハードウェア出力を追加したとき。%s = チャンネルの組。",
    "マスターの %s ch → 出力 %s のハードウェア出力を追加しました。")
def("DONE_HWOUT_FAIL", "完了のお知らせ。ハードウェア出力を作れなかったとき。",
    "ハードウェア出力を作れませんでした。マスターのルーティングで、%s ch → 出力 %s を自分で追加してください。")
def("DONE_TRACKS", "完了のお知らせ。トラックのセンドを付け替えたとき。%d = 本数、%s = チャンネルの組。",
    "%d本のトラックのセンドを%s chにしました。")
def("DONE_OLD_HEAD", "完了のお知らせ。チャンネルを付け替えたあと、古い設定が残っているときの見出し。",
    "古い設定（手で外してください）:")
def("DONE_OLD_HWOUT", "古い設定の一覧の1行。古いチャンネルのハードウェア出力が残っているとき。%s = チャンネルの組。",
    "・マスターの %s ch → 出力 %s のハードウェア出力")
def("DONE_OLD_TRACK", "古い設定の一覧の1行。選んでいないトラックが古いチャンネルへ送っているとき。%s = トラック名、%s = チャンネルの組。",
    "・トラック %s のマスターセンド（%s ch）")
def("DONE_OUT_WARN", "完了のお知らせ。Eater が無い構成のとき。%s = チャンネルの組。",
    "%s の出力からはリファレンスが常に出ています。そのチャンネルの出力にスピーカーやヘッドホンをつながないでください。")
def("DONE_OUT_WARN_FAIL", "完了のお知らせ。Eater の追加に失敗したとき（その組の出力にリファレンスが出続ける）。%s = チャンネルの組。",
    "Eaterのインサートに失敗したため、%s の出力からはリファレンスが常に再生されます。")
def("DONE_FX_NOTE", "結果の窓の最後の注意。",
    "注意: 4ch以上を処理するFXがマスタートラックにインサートされている場合、リファレンストラックが動作に作用します。ルーティングマトリックスを確認するようにしてください。")

-- ===== STARTUP =====
def("STARTUP_INSTALL_OK", "「Display (Install Startup)」を実行して登録できたとき（見張りが動いていたかどうかに関わらず同じ文）。",
    "REAPER起動時に常駐するように登録しました。\n不要になったときは「TUKONYA_Reference Display (Uninstall Startup)」を実行してください。")
def("STARTUP_INSTALL_FAIL", "Install Startup で登録に失敗したとき。%s = 理由。",
    "登録できませんでした。\n\n%s")
def("STARTUP_UNINSTALL_OK", "「Display (Uninstall Startup)」を実行したとき。%s = 常駐を止めたかどうかの一文。",
    "起動時の自動開始をやめました。\n%s")
def("STARTUP_STOPPING", "Uninstall Startup の文中。動いていた常駐を止めるとき。",
    "動いていた REFERENCE 窓の常駐も止めます。")
def("STARTUP_NOT_RUNNING", "Uninstall Startup の文中。常駐が動いていなかったとき。",
    "（動いている常駐はありませんでした）")
def("STARTUP_UNINSTALL_FAIL", "Uninstall Startup で外せなかったとき。%s = 理由。",
    "外せませんでした。\n\n%s")
def("STARTUP_ERR_UNKNOWN_LOC", "Install Startup。スクリプトの置き場所が分からないとき。",
    "場所が分かりません")
def("STARTUP_ERR_OUTSIDE", "Install Startup。スクリプトが REAPER の Scripts フォルダの外にあるとき。%s = 場所。",
    "REAPERのScriptsフォルダの外にあります: %s")
def("STARTUP_ERR_WRITE", "Install/Uninstall Startup。__startup.lua に書き込めないとき。%s = 場所。",
    "書き込めませんでした: %s")

return M
