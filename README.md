# Tukonya Scripts

JSFX effects and ReaScripts for [REAPER](https://www.reaper.fm/), by tuko.
Free for personal use. No warranty.

## Install (ReaPack)

1. Install [ReaPack](https://reapack.com/) if you have not already.
2. In REAPER: **Extensions > ReaPack > Import repositories...** and paste

   ```
   https://raw.githubusercontent.com/tuko1573/tukonya-scripts-reapack/main/index.xml
   ```

3. **Extensions > ReaPack > Browse packages...**, search for the package, right-click > Install > Apply.

## Packages

| Package | Type | What it is |
|---|---|---|
| TUKONYA RENDER | ReaScript (Rendering) | One ReaImGui window for five render workflows: 2mix Render, 2mix Preview (watermarked), Para + 2mix (stems, project folder structure kept), Hardware Print and Mastering (WAV/AAC/DDP with CD-TEXT). Verified on macOS; Windows and 96 kHz interfaces not yet tested. Needs SWS and ReaImGui 0.10+. Installs with a project template; read the README.md next to the script. |
| TUKONYA Team Plugin Checker | ReaScript (Utility) | A REAPER window that searches which plugins each team member owns, from a shared folder, and inserts them directly. Needs SWS and ReaImGui 0.10+. Read the README.md next to the script. |
| TUKONYA VST3 Only Master | ReaScript (Utility) | Watches the track named "MASTER" and, when a non-VST3 plugin is inserted, offers to replace it with the VST3 version on the spot (ReaInsert is ignored). Companion to TUKONYA RENDER's Para + 2mix, which exports .vstpreset from VST3 only. Run the (Install Startup) action once. |
| TUKONYA Auto Link | ReaScript + JSFX (Utility) | Keeps automation envelopes (mute, volume, pan, width, trim and pre-FX variants; 8 types, chosen by checkbox) in sync between tracks that share the same Link Ch. Insert the marker JSFX on each track, run the watcher script; the (Install Startup) action starts it with REAPER. Synced while stopped. Verified on macOS; Windows not yet tested. |
| TUKONYA Folder Link | ReaScript (Utility) | Keeps folder open/closed state in sync between the arrange view (TCP) and the mixer, both ways. Includes Folder Toggle (open/close the selected track's folder in both views, for a shortcut). The (Install Startup) action starts the watcher with REAPER. Verified on macOS; Windows not yet tested. |
| TUKONYA Container Link | ReaScript + JSFX (Utility) | A KSHMR Chain-style link for REAPER containers: containers that share a Link Ch keep the same FX order, parameters, bypass, GUI-only settings, automation and name, whichever track you edit. One Undo/Redo moves them all. Insert the marker JSFX inside each container, run the watcher script; the (Install Startup) action starts it with REAPER. Needs REAPER 7.79+ and js_ReaScriptAPI. Verified on macOS; Windows not yet tested. |
| TUKONYA JP LangPack Updater | ReaScript (Language) | Keeps the Japanese REAPER language pack up to date, checking once a day at startup. Does nothing if REAPER runs in English. |

More to come.

## 日本語

REAPER用のJSFXエフェクトとReaScriptの配布元です。個人利用は自由、無保証です。
入れ方: ReaPackを入れたあと、REAPERの **拡張 > ReaPack > Import repositories...** に上のURLを貼り、
**Browse packages...** で名前を検索して右クリック > Install > Apply。

## Notes

- No third-party source code is included in any package.
- TUKONYA JP LangPack Updater installs to `Scripts/Tukonya Scripts/Language/`.
- TUKONYA RENDER installs to `Scripts/Tukonya Scripts/Rendering/`. Open `template/TUKONYA_RENDER_template.RPP` in that folder as the base project.
- TUKONYA Team Plugin Checker installs to `Scripts/Tukonya Scripts/Utility/`.
- TUKONYA Auto Link installs to `Scripts/Tukonya Scripts/Utility/`, and its marker JSFX to `Effects/Tukonya Scripts/Utility/`.
- TUKONYA Folder Link installs to `Scripts/Tukonya Scripts/Utility/` (its README is `README_FolderLink.md`).
- TUKONYA Container Link installs to `Scripts/Tukonya Scripts/Utility/` (its README is `README_ContainerLink.md`), and its marker JSFX to `Effects/Tukonya Scripts/Utility/`.
- TUKONYA VST3 Only Master installs to `Scripts/Tukonya Scripts/Utility/` too (its README is `README_VST3OnlyMaster.md`).
