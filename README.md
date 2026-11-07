# Bubilator88

日本語 | [English](README.en.md)

<p align="center">
  <img src="docs/AppIcon.png" alt="Bubilator88" width="128" height="128">
</p>


NEC PC-8801 エミュレーター for macOS</br>

https://bubio.github.io/Bubilator88/

[![Latest Release](https://img.shields.io/github/v/release/bubio/Bubilator88)](https://github.com/bubio/Bubilator88/releases/latest)
[![License](https://img.shields.io/github/license/bubio/Bubilator88)](https://github.com/bubio/Bubilator88/blob/main/LICENSE)
[![Downloads](https://img.shields.io/github/downloads/bubio/Bubilator88/total.svg)](https://github.com/bubio/Bubilator88/releases/latest)
[![CodeQL](https://github.com/bubio/Bubilator88/actions/workflows/codeql.yml/badge.svg)](https://github.com/bubio/Bubilator88/actions/workflows/codeql.yml)

## About

Bubilator88 は、NEC パーソナルコンピュータ PC-8801 の macOS ネイティブエミュレーターです。

**このプロジェクトのコードは、ほぼすべて AI（Claude, Codex）によって書かれています。**

<p align="center">
  <img src="docs/Screenshot.png" alt="Bubilator88 Screenhot">
</p>


レトロ PC エミュレーターは、未文書化されたハードウェアの挙動再現、T ステート精度のタイミング制御、複数 LSI の協調動作など、深い専門知識と緻密な実装を要求される特殊なソフトウェアです。「AI はこの種のソフトウェアをゼロから構築できるのか？」— の興味から開発しました。

macOSらしいUIと機能を追求しています。

一応、Windows版もあります。

https://github.com/bubio/Bubilator88/releases/tag/win-v1.2.0

## Features

- Z80 CPU エミュレーション（T ステート精度）
- YM2608 (OPNA) サウンド — FM 6ch、SSG 3ch、リズム、ADPCM
- uPD765A FDC
- uPD3301 CRTC + DMA テキスト表示
- Metal による高速な画面描画
- AVAudioEngine による低遅延サウンド出力
- ゲームコントローラー対応（ハプティックフィードバック）
- Apple Silicon ネイティブ

### 画面フィルター

Metal シェーダーによる複数の画面フィルターを搭載しています。

- **Linear / Bicubic** — バイリニア・バイキュービック補間によるスムージング
- **CRT** — CRT モニターのスキャンライン・蛍光体残光を再現
- **xBRZ** — ピクセルアートに特化したエッジ検出スケーラ
- **Enhanced** — xBRZ + 独自フィルタの組み合わせ

### AI Upscale

CoreML 上で超解像モデルを実行し、PC-8801 の画面をリアルタイムに高解像度化します。M4 Pro 以上の性能がないと実用は難しいと思います。

### イマーシブオーディオ

AirPodsなどのヘッドトラッキングと連動した空間オーディオを実現します。FM、SSG、リズム、ADPCM の各チャンネルを 3D 空間上に自由に配置でき、頭の動きに追従してサウンドが変化します。

### 疑似ステレオ

モノラル出力のサウンドに左右の微小なディレイ差を加え、擬似的なステレオ広がりを生成します。

### リアルタイム翻訳オーバーレイ

Apple Vision OCR + Translation フレームワークを使い、画面上の日本語テキストをリアルタイムで認識・翻訳してオーバーレイ表示します。

### ハプティックフィードバック

ゲームコントローラーの振動機能に対応。SSGによる効果音に連動した触覚フィードバックを提供します。

### 操作領域

画面上の領域をクリックすると、登録したキーを入力します。キーボードでしか操作できないゲームを、マウスやゲームコントローラーで遊べます。

### チート

88PAR 形式のチートコード（.pat）に対応しています。69 本分のコード集を同梱しています。

### テキストのコピー＆ペースト

エミュレータの画面テキストを macOS のクリップボードへコピー、またはクリップボードのテキストを擬似キー入力として流し込むことができます。半角カナを含む BASIC プログラムのリスト転記や、サンプルコードの貼り付けが手打ちなしで行えます。

### AI ツールからの操作 (MCP)

[Model Context Protocol](https://modelcontextprotocol.io) に対応した AI ツールから、起動中のエミュレーターを操作・確認できます。キー入力、画面の取得、ディスクやステートの操作、メモリの参照、ブレークポイント、書き込み元の追跡、サイクル計測などを AI に任せられます。

設定の「一般」で「AI ツールからの操作を許可」をオンにし、URL とトークン、または設定 JSON をコピーしてクライアントに登録します。接続は `http://127.0.0.1:<ポート>/mcp` への Streamable HTTP で、要求には `Authorization: Bearer <トークン>` が要ります。

| クライアント | 登録のしかた |
| --- | --- |
| Claude Code | `claude mcp add --transport http bubilator88 <URL> --header "Authorization: Bearer <トークン>"` |
| Cursor | `~/.cursor/mcp.json` に設定 JSON をそのまま書く |
| VS Code | `.vscode/mcp.json` に設定 JSON を書き、最上位のキー `mcpServers` を `servers` にする |
| Gemini CLI | `~/.gemini/settings.json` に設定 JSON を書き、`url` を `httpUrl` にして `type` を消す |
| Codex | `~/.codex/config.toml` に `[mcp_servers.bubilator88]` を作り、`url = "<URL>"` と `bearer_token_env_var = "<トークンを入れた環境変数名>"` を書く |

## System Requirements

- macOS 26.0 (Tahoe) 以降
- Apple Silicon Mac

## Install

### Homebrew

```bash
brew install --cask bubio/bubilator88/bubilator88
```

### 手動ダウンロード

[Releases](https://github.com/bubio/Bubilator88/releases)ページから最新版をダウンロードしてください。

> **注意**: このアプリは Apple によるノータリゼーション（公証）を受けていないため、初回起動時に Gatekeeper によってブロックされる場合があります。以下のいずれかの方法で回避できます：
>
> **方法1: ターミナルで隔離フラグを削除**
> ```bash
> xattr -cr /Applications/Bubilator88.app
> ```
>
> **方法2: システム設定から許可**
> 1. アプリを開こうとしてブロックされた後
> 2. 「システム設定」→「プライバシーとセキュリティ」を開く
> 3. 「"Bubilator88"は開発元を確認できないため、使用がブロックされました」の横にある「このまま開く」をクリック

## ROM Files

PC-8801 の起動には実機の ROM ファイルが必要です（本プロジェクトには含まれていません）。リズム音源用 WAV は無くても代替音で鳴り、漢字 ROM は無くても同梱の代替（[東雲フォント](http://openlab.ring.gr.jp/efont/shinonome/)から作成）で漢字が表示されます。

*~/Library/Application Support/Bubilator88/* に配置してください。

```
~/Library/Application Support/Bubilator88/
├── N88.ROM          N88-BASIC ROM（必須）
├── N80.ROM          N-BASIC ROM
├── FONT.ROM         フォント ROM ※任意。無ければ内蔵フォント
├── KANJI1.ROM       漢字 ROM（第1水準）※任意。無ければ同梱の代替
├── KANJI2.ROM       漢字 ROM（第2水準）
├── JISYO.ROM        辞書 ROM（かな漢字変換）
├── DISK.ROM         サブ CPU ファームウェア（8KB）
├── N88_0.ROM        N88 拡張 ROM バンク 0
├── N88_1.ROM        N88 拡張 ROM バンク 1
├── N88_2.ROM        N88 拡張 ROM バンク 2
├── N88_3.ROM        N88 拡張 ROM バンク 3
├── 2608_BD.WAV      YM2608 リズム音源（バスドラム）※任意。無ければ同梱の代替音
├── 2608_SD.WAV      YM2608 リズム音源（スネア）
├── 2608_TOP.WAV     YM2608 リズム音源（シンバル）
├── 2608_HH.WAV      YM2608 リズム音源（ハイハット）
├── 2608_TOM.WAV     YM2608 リズム音源（タム）
└── 2608_RIM.WAV     YM2608 リズム音源（リムショット）
```

### 実機の ROM が無い場合: pbios（代替 BIOS）

cisc 氏が公開している起動専用の代替 BIOS
[pbios](http://retropc.net/cisc/m88/download.html) の `n88.rom` と `disk.rom` を
`N88.ROM` と `DISK.ROM` として置くと、BASIC を使わないソフトの一部が起動します。

## Development

エミュレーションコアは別リポジトリの Swift パッケージ
[Bubilator88Core](https://github.com/bubio/Bubilator88Core) です。
`Bubilator88.xcodeproj` を開けば、固定されたバージョンのコアを取得してビルドできます。

コアも一緒に編集するときは、このリポジトリと同じ階層にコアを clone し、
`Bubilator88Dev.xcworkspace` を開きます。手元のコアがリモートより優先されます。

```bash
git clone https://github.com/bubio/Bubilator88.git
git clone https://github.com/bubio/Bubilator88Core.git
open Bubilator88/Bubilator88Dev.xcworkspace
```

コマンドラインからはCMakeでもビルドできます（CMake 3.21以降）。
リポジトリ直下で実行すると、手元のコアを使うDebug・排他チェック有効のビルドになります。

```sh
cmake --preset dev
cmake --build --preset dev
```

Releaseのchecked／unchecked切替や、CMake不要のシェルスクリプトは
[ローカルビルド手順](docs/LOCAL_BUILD.md)を参照してください。

内部設計資料は private submodule (`docs/develop`) にあります。ビルドや実行には不要で、
アクセス権があるコントリビューター向けです。

```bash
git submodule update --init docs/develop
```

## Credits

- **FM 合成エンジン**: [fmgen](http://retropc.net/cisc/sound/) by cisc — Swift への移植
  (利用条件は [Bubilator88Core](https://github.com/bubio/Bubilator88Core) の
  `Sources/FMSynthesis/fmgen-readme.txt`、改変内容は同ディレクトリの `fmgen-changes.md` を参照)
- **参考エミュレーター**: [QUASI88](https://www.eonet.ne.jp/~showtime/quasi88/) by S.Fukunaga — ビヘイビアリファレンスとして参照
- **参考エミュレーター**: [common source code project](https://takeda-toshiya.my.coocan.jp/common/index.html) by Takeda Toshiya — BubiC-8801MA として参照
- **参考エミュレーター**: [X88000](https://quagma.sakura.ne.jp/manuke/x88000.html) by Manuke — Z80 未文書化命令や細部の実装リファレンスとして参照
- **技術資料**: [PC-8801についてのページ](http://www.maroon.dti.ne.jp/youkan/pc88/) by youkan — ハードウェア仕様リファレンス
- **技術資料**: [PC-8801 VRAM情報](http://mydocuments.g2.xrea.com/html/p8/vraminfo.html) — VRAM アクセス仕様リファレンス
- **スケーリングアルゴリズム**: [xBRZ](https://sourceforge.net/projects/xbrz/) by Zenju — Enhanced フィルターのベース
- **AI モデル**: [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) — 超解像アップスケーリング用 CoreML モデル
- **AI コーディング**: [Claude Code](https://claude.ai/code) (Anthropic) — コードのほぼ全体を生成

## License

[GNU General Public License v2.0](LICENSE)
