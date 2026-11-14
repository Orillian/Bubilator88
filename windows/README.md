# Bubilator88 — Windows ネイティブ版

macOS 版と同じ Swift パッケージ **Bubilator88Core** を DLL 化し、C# + WinUI 3 から
駆動する Windows 版です。描画は D3D11、音声は XAudio2、AI アップスケールは
ONNX Runtime + DirectML を使用します。**コアを共有していても、アプリの機能は同一ではありません。**

## macOS 版との機能比較

以下は **2026-11-14 時点のソースツリー**を比較したものです。公開済み ZIP の機能とは
一致しない場合があります。「対応」は Windows の通常 UI から利用可能、「一部対応」は
制限または操作方法の違いあり、「未対応」は通常 UI から利用できないことを示します。
C ABI の公開や試作コードの存在だけでは対応済みとしていません。

### 対応済み・一部対応

| 機能 | Windows | 対応内容・macOS 版との差 |
| --- | --- | --- |
| エミュレーションコア | 対応 | CPU・映像・音源・FDC 等は共通コア。CI・配布は macOS と同じ `Package.resolved` の revision を使用 |
| 起動モード・CPU クロック | 対応 | N88-BASIC V2 / V1H / V1S / N-BASIC、4 / 8 MHz、リセット、一時停止・再開 |
| ハードウェア設定 | 対応 | 24 / 15 kHz モニタ、メモリウェイト DIP、拡張 RAM。次回リセットで反映 |
| 代替 ROM・リズム音 | 対応 | 代替漢字 ROM・リズム音を共用。実機由来の ROM・WAV を優先。辞書 ROM も読込可能 |
| D88 / D77 ディスク | 一部対応 | Drive 1 / 2 / 1&2、複数イメージの選択・切替、ライトプロテクト、最近使ったファイル。ファイルへの書き戻し・エクスポート等は下表参照 |
| 画面フィルター | 対応 | None / Linear / Bicubic / CRT / xBRZ / Enhanced、スキャンライン。Metal の代わりに D3D11 を使用 |
| AI アップスケール | 対応 | Fast / Balanced / Quality の 3 モデル。Fast・Balanced 同梱、Quality は確認後に任意ダウンロード。進捗・再試行・キャンセル・検証・削除に対応 |
| 表示サイズ | 対応 | ×1 / ×2 / ×4、フルスクリーン、Fit / 整数 / 4:3 補正、ウィンドウ位置・倍率の保存 |
| 通常音声・音量・バッファ調整 | 対応 | XAudio2、適応レート制御、等速時の音声サブフレーム化。エミュレーションと表示は別スレッド |
| 疑似ステレオ・CD Mix | 対応 | CD Mix は出力音のローパス＋リバーブ。CD-ROM 対応とは別の機能 |
| FDD アクセス音 | 対応 | シーク・リード音、ドライブ別定位、音量・専用出力デバイス選択、アクセスランプ |
| 早送り | 一部対応 | ×1 / ×2 / ×4 / ×8 / ×16。Windows は ×8 以上でミュート、macOS は全段で倍速音声 |
| キーボード入力 | 一部対応 | US / JIS・自動判定、矢印 / 数字列 / WASD のテンキー代用。特殊キー再割当等は下表参照 |
| ゲームコントローラー | 一部対応 | ボタン・トリガー・スティック、PC-88 キーへの割当変更と初期化。ホストコマンドは既定割当で利用。機種別設定・振動は未対応 |
| チート | 対応 | 88PAR `.pat` の取込、macOS と共通のプリセット、グループ別 ON / OFF、ディスク別の設定保存 |
| セーブステート | 対応 | クイック＋10 スロット、サムネイル・メタ情報。macOS と同じ単一 `.b88s`（AMTA / THMB 内蔵）。旧 Windows サイドカーも読込可能 |
| スクリーンショット | 対応 | PNG / JPEG / HEIC、自動保存・保存先選択、画面画像のクリップボードコピー（Ctrl+Shift+C） |
| AI ツールからの操作（MCP） | 対応 | ローカル HTTP・トークン認証・設定・8 種類のクライアント登録形式。プロトコルとツール実行は共通コア。下記参照 |
| 更新確認 | 対応 | 起動時・手動の確認、後で通知・バージョンのスキップ。Windows 用 `win-v*` リリースを案内し、導入は手動 |
| 起動引数 | 一部対応 | 既存の `.d88` / `.d77` パスを 1 件受け取り起動時にマウント。macOS の URL スキーム・QUASI88 互換オプションには未対応 |

### macOS 版にあり、Windows の通常 UI では未対応の機能

| 機能 | macOS 版 | Windows の現状 |
| --- | --- | --- |
| ディスクの永続化・管理 | ディスクキャッシュ、書き戻し、空ディスク作成、キャッシュのエクスポート | 元の D88 / D77 への書き戻しや管理 UI なし。ディスクの変更内容を残すにはセーブステートを保存する |
| ZIP 内のディスク読込 | ZIP 内のディスクを選択・マウント | ファイル選択は D88 / D77 のみ。事前に展開が必要 |
| テープ | ファイルを開く、自動起動、巻戻し、取出し、履歴 | Tape メニューなし。共通コア・C ABI の対応と Windows UI の対応は別 |
| PC-8001 メモリイメージ | `.n80` 読込 | 読込 UI なし（C ABI は公開済み） |
| PC-8801MC CD-ROM | `.cue` / `.ccd` の読込・取出し・履歴 | CD メニューなし（C ABI は公開済み） |
| CPU オーバークロック | Develop メニューで ×1 / ×2 / ×4 を設定 | 設定 UI なし。`b88_set_cpu_overclock` の宣言はあるが通常実行は ×1。Emulation Speed の早送りとは別 |
| 巻戻し（Rewind） | 過去のスナップショットへ戻る | スナップショットの自動蓄積・巻戻し操作なし |
| 終了時の状態から再開 | Resume where you left off | 自動保存・次回起動時の自動復元なし。手動のクイック保存・読込を使用 |
| バックグラウンド動作設定 | 実行継続・音声の可否を個別設定 | 設定なし。最小化中は停止 |
| 録音・録画 | 音声録音、音声付き動画記録 | 保存 UI・記録処理なし。スクリーンショットは対応 |
| 空間オーディオ | チャンネルの 3D 配置、ヘッドトラッキング | 通常音声・疑似ステレオ・CD Mix のみ |
| マウス入力 | PC-8872 バスマウス、マウスによるジョイスティック代用、感度・捕捉解除 | ホストマウスの相対移動・ボタンをエミュレーターへ送る配線なし |
| 操作領域 | 画面上の領域にキー操作を割当 | 領域の編集・クリック・コントローラーでの操作なし |
| ソフトウェアキーボード | PC-88 キー配列の別ウィンドウ | 表示 UI なし |
| 特殊キー再割当・ローマ字かな入力 | 特殊キーのカスタマイズ、ローマ字からかな入力 | 固定のキーマッピング・テンキー代用のみ |
| テキストのコピー＆ペースト | 画面文字をコピー、文字列を擬似キー入力 | 通常 UI に文字列のコピー・貼付操作なし。Ctrl+Shift+C は画像コピー |
| コントローラーの機種別設定・振動 | モデル別マッピング、ブランド別アイコン、SSG 効果音連動の触覚フィードバック | 全機種共通のマッピング。振動出力なし |
| OCR・翻訳オーバーレイ | Apple Vision OCR＋Translation | OCR は試作コードのみで UI から無効化。翻訳バックエンドは未実装 |
| テキストを除外したスキャンライン | テキスト画素の減光を除外 | D3D11 シェーダー未対応。スキャンライン自体は使用可能 |
| 操作スクリプトの実行・記録 UI | スクリプト実行・記録 | アプリの操作 UI なし。共通コアの MCP ツールとは区別する |
| 開発・デバッグ用ウィンドウ | Develop メニューの各種検査 UI | 対応するウィンドウなし。MCP のデバッグツールは利用可能 |
| OS との統合 | Finder の Quick Look・サムネイル、ファイルを開く操作、`bubilator88://` | Explorer 用プレビュー・サムネイル拡張、ファイル関連付け・URL 登録の配布処理なし |
| リセット時の演出 | ディゾルブアニメーションの ON / OFF | 設定・描画処理なし |
| UI のローカライズ | String Catalog による多言語 UI | Windows UI は英語文字列で実装 |

OCR の試作は `Ocr/` とフレームループに残っていますが、PC-8801 の小さい文字に対する
認識精度が不十分なため、View メニュー・Ctrl+T の入口を設けていません。
コードの存在を理由に翻訳機能が利用できるとは扱わないでください。

比較元は macOS の `Bubilator88/App/Commands/`・`Bubilator88/Views/Settings/` と、
Windows の `MainWindow.xaml`・`MainWindow.*.cs`・`EmulatorHost*.cs`・`App.xaml.cs` です。
内部の移植方針・調査記録は `docs/develop/WINDOWS_PORT.md`（非公開サブモジュール）にあります。
この README だけで対応状況とビルド・配布手順を確認できます。

## 構成

| 場所 | 役割 |
| --- | --- |
| `Bubilator88.Windows/NativeApi*.cs` | 共通コアの C ABI に対応する P/Invoke 宣言 |
| `EmulatorHost*.cs` / `EmulationLoop.cs` / `FramePublisher.cs` | コアの排他・メディア操作、専用実行スレッド、3 スロットのフレーム受渡し |
| `MainWindow.xaml` / `MainWindow.*.cs` | メニュー、設定、入力、メディア、保存、MCP、更新確認 |
| `D3DScreen.cs` / `AiUpscaler.cs` / `AIModelStore.cs` | D3D11 描画、AI 推論、モデルのダウンロード・検証・保存 |
| `XAudioSink.cs` / `FddSound.cs` | 通常音声・FDD 音の再生 |
| `KeyMapping.cs` / `GameController/` | キーボード・ゲームコントローラー入力 |
| `WinSaveState.cs` / `StateSections.cs` / `AtomicStateFile.cs` | ステートの保存・メタ情報・サムネイル・原子的置換 |
| `Automation*.cs` / `AppAutomationHost.cs` | MCP の通信・セッション・アプリ操作の橋渡し（[詳細](MCP.md)） |
| `Bubilator88.Windows/native/` | ビルドした `Bubilator88C.dll` の配置先（git 管理外） |
| `Bubilator88.Windows.Tests/` | UI 非依存のロジック・HTTP・ネイティブ連携の xUnit テスト |
| `Bubilator88.Launcher/` | 共有ランタイム配布版の起動用ランチャー |

上表でディレクトリを省略した `.cs` は `Bubilator88.Windows/` 内です。
コアは別リポジトリ [bubio/Bubilator88Core](https://github.com/bubio/Bubilator88Core) の
`Sources/CApi/` にあり、`b88_*` 関数は複数の Swift ファイルに分かれています。
開発規約は [AGENTS.md](AGENTS.md) と[ルートの AGENTS.md](../AGENTS.md) を参照。

## 前提ツール

1. **Swift toolchain for Windows**(swift.org の Windows 版 + Visual Studio Build Tools の
   C++ ワークロード)。`swift --version` が通ること。
2. **Visual Studio 2022** + **Windows App SDK / .NET デスクトップ** ワークロード、**.NET 10 SDK**。
3. **Git LFS**(`git lfs version` が通ること)。AI モデルが LFS 管理のため。
4. ROM 一式を `%LOCALAPPDATA%\Bubilator88\` に配置(`N88.ROM` 必須、`DISK.ROM` 等は任意)。

   `JISYO.ROM`（辞書ROM、512KB）も同じフォルダから読み込み、かな漢字変換に使用する。
   `KANJI1.ROM` / `KANJI2.ROM` がない場合は、macOS版と同じ東雲フォント由来の
   代替ROMを使用する。YM2608のリズム音もmacOS版と同じ6音を同梱し、
   `2608_BD.WAV` / `2608_SD.WAV` / `2608_TOP.WAV` / `2608_HH.WAV` /
   `2608_TOM.WAV` / `2608_RIM.WAV` を配置した音だけユーザーのサンプルを優先する。
   WAVの解析と音源への投入は既存のコアC ABIが担当する。
   macOS の `~/Library/Application Support/Bubilator88/` と同じ顔ぶれ（内部資料: `docs/develop/PERSISTENCE.md`）。

## チェックアウト

```powershell
git lfs install            # マシンごとに一度 (LFS フックを有効化)
git clone git@github.com:bubio/Bubilator88.git
git clone git@github.com:bubio/Bubilator88Core.git   # コア。Bubilator88 と同じ階層に置く
cd Bubilator88
git lfs pull               # 同梱する Fast / Balanced モデルの実体を取得
```

以降、コア DLL の手動ビルド以外のコマンドはリポジトリ直下から実行する。

コアの置き場所を変えたときは `BUBILATOR88_CORE_DIR` に設定する
(`scripts/build-windows-package.ps1` が見る)。
リリースと CI は、macOS アプリの `Package.resolved` が固定している revision のコアを使う。

> **LFS 注意**: 同梱する Fast / Balanced モデルは Git LFS 管理。`git lfs pull` 前は
> ~133 バイトの**ポインタ**なので、そのままビルドするとモデルが壊れたまま同梱される。
> `git lfs pull` で実体に展開すること。特に **Fast/Balanced(SRVGGNet)は自前学習で
> 公開重みが無い**ため、pull しないと再生成もできない(Quality は公開重みから再生成可)。
> モデルが無くても(または AI を使わなくても)ビルド・起動は可能で、その AI フィルタは
> Bicubic にフォールバックする(`AiUpscaler` の state=unavailable)。

## ビルド & 実行

### 1. コア DLL をビルド

```powershell
cd ..\Bubilator88Core     # このリポジトリの隣に clone したコア
swift build -c release --product Bubilator88C -Xswiftc -enforce-exclusivity=unchecked
# 配置先を作成し、成果物をコピー
New-Item -ItemType Directory -Force ..\Bubilator88\windows\Bubilator88.Windows\native | Out-Null
Copy-Item .build\release\Bubilator88C.dll ..\Bubilator88\windows\Bubilator88.Windows\native\
```

まずコア健全性を確認(macOS と同じ結果になるはず):

```powershell
swift test -Xswiftc -enforce-exclusivity=unchecked  # コアのユニットテスト
swift run BootTester "C:\path\game.d88"     # テキストVRAMダンプ等
```

> **エクスポートに関する注意**: Swift は DLL の `public` な記号を自分で書き出す。
> `Sources/CApi/` の `@_cdecl` 関数は必ず `public` にすること
> (付け忘れてもビルドは通り、P/Invoke が実行時に失敗する)。コアの CI が DLL の
> 書き出し表と `@_cdecl` の一覧を突き合わせている。

コアの確認後は `cd ..\Bubilator88` でリポジトリ直下に戻る。

### 2. AI モデル (ONNX) を用意 — 任意

`git lfs pull` で `models/onnx/*.onnx` を取得済みならスキップ可。自分で生成する場合:

```powershell
pip install torch onnx onnxruntime
python scripts\convert_srvggnet_onnx.py       # models\*.pth → SRVGGNet_x2*.onnx (Fast/Balanced)
python scripts\convert_realesrgan_onnx.py     # RealESRGAN_x2plus.pth を自動DL → RealESRGAN_x2.onnx (Quality)
```

- 出力はすべて `models\onnx\` 直下。3 モデルとも macOS の CoreML 版と**同一重み**で、
  ONNX↔CoreML の出力一致は `scripts\verify_onnx_coreml.py` で検証済(fp16 精度、
  max|diff| < 0.003)。入出力は float[0,1] RGB CHW、正規化(/255)と RGBA8 化はホスト
  (`AiUpscaler.cs`)が行う。
- Fast/Balanced(SRVGGNet)は公開重みが無いため `.pth`・`.onnx` とも LFS 必須。詳細と
  再生成手順は [models/PROVENANCE.md](../models/PROVENANCE.md) を参照（Balanced はコンパイル済 `.mlmodelc` から復元）。
- csproj は Fast / Balanced の 2 モデルだけを出力直下へコピーする。Quality は
  `models-v1` の ONNX asset から任意ダウンロードする。いずれも未準備なら Bicubic フォールバック。

### 3. シェルをビルド & 実行

```powershell
# リポジトリ直下で実行
dotnet run --project windows\Bubilator88.Windows -c Release -r win-x64
```

> **ランタイム依存**: `Bubilator88C.dll` は Swift ランタイム DLL(`swiftCore.dll` 等)に依存する。
> 開発機では `...\Swift\Runtimes\6.3.2\usr\bin` が PATH 上なので `dotnet run` で解決するが、
> 単体配布する場合は同 bin の DLL 群を exe の隣に同梱する必要がある(手動 `dotnet run` では
> 未同梱のまま。配布パッケージは後述の `build-windows-package.ps1` が自動でバンドルする)。
>
> **DLL 配置**: `None Include="native\..."` を `<Link>Bubilator88C.dll</Link>` で**出力直下**に
> 置かないと P/Invoke が `ERROR_MOD_NOT_FOUND (0x8007007E)` で落ちる(native\ サブフォルダは
> 探索対象外)。Fast / Balanced の ONNX モデルも出力直下へ Link コピーされる。

> **アプリアイコン**: `Assets\AppIcon.ico` は `..\..\docs\AppIcon.png` から生成したマルチ
> 解像度 ico (16〜256px)。`<ApplicationIcon>` で exe の Win32 リソースに焼き込まれる
> (エクスプローラ/タスクバー/ショートカットの表示に使われる)が、unpackaged WinUI3 では
> それだけではタイトルバーアイコンにならないため、`MainWindow` コンストラクタで
> `AppWindow.SetIcon(...)` を明示的に呼んで同じ ico を渡している。元画像を差し替えたら
> 再生成すること:
> ```powershell
> pwsh scripts\convert-png-to-ico.ps1 -SourcePng docs\AppIcon.png -OutputIco windows\Bubilator88.Windows\Assets\AppIcon.ico
> ```

### 4. シェルの単体テスト

```powershell
dotnet test windows\Bubilator88.Windows.Tests\Bubilator88.Windows.Tests.csproj
```

> self-contained な WinUI exe を ProjectReference するとテストホストに WinUI ランタイムが
> 載って失敗するため、テストプロジェクトは UI 非依存の純ロジックファイル
> （`KeyMapping.cs` / `PixelMath.cs` / `AutomationHTTPServer.cs` 等）を**ソースリンク**してヘッドレスに検証する。
> 対象を増やすときは `.csproj` の `<Compile Include=…>` に純ロジックファイルを足す。

## 配布パッケージ

```powershell
pwsh scripts\build-windows-package.ps1 -Version 1.2.3
```

コア DLL をビルドし、Fast / Balanced モデル (Git LFS) を確認してから、次の2つを
同じ Windows App SDK **2.5.1** で発行する。単一 EXE 版は .NET 10 を含み、
共有ランタイム版は PC に導入された .NET 10 を使う。必要な Swift DLL は両方に
同梱し、実機由来のROMと任意ダウンロードの Quality モデルは含まない。
代替漢字ROM（ライセンス文書を含む）と代替リズム音は両方の配布物に同梱する。

| ZIP | 内容 | 利用者側の前提 |
| --- | --- | --- |
| `Bubilator88-Windows-x64-<Version>-SingleFile.zip` | 単一の `Bubilator88.exe`。初回起動時に依存ファイルを `%TEMP%\.net\` に展開する | Windows App SDK の別途インストールは不要 |
| `Bubilator88-Windows-x64-<Version>-SharedRuntime.zip` | 表に起動用ランチャー `Bubilator88.exe`、`app\` に EXE と依存ファイルを収めたフォルダ配布。WinUI 3 と .NET のランタイムは含めない | [Windows App SDK 2.5.1 ランタイム (x64)](https://aka.ms/windowsappsdk/2.5/2.5.1/windowsappruntimeinstall-x64.exe) と [.NET Runtime 10 (Windows x64)](https://dotnet.microsoft.com/download/dotnet/10.0) を導入。互換ランタイムが既にあれば再導入不要 |

どちらの版も [Visual C++ 再頒布可能パッケージ (x64)](https://aka.ms/vc14/vc_redist.x64.exe)
が必要。通常すでに入っているPCでは追加作業は不要。
単一 EXE のファイル名は `Bubilator88.exe` のまま使う。2.5.1 の検証時に
EXE 自体を別名へ変えると起動に失敗しており、ZIP の名前変更とは区別する。

#### 共有ランタイム版を試す

まず上記の Windows App SDK ランタイムと .NET Runtime 10、必要なら Visual C++ 再頒布可能パッケージを
導入する。すでに導入済みならこの手順は不要。次に
`dist\Bubilator88-Windows-x64-<Version>-SharedRuntime.zip` を任意のフォルダへ
展開し、表にある `Bubilator88.exe` (`app\Bubilator88.exe` を起動するだけの小さな
ランチャー) を実行する。`app\Bubilator88.exe` から直接起動してもよい。
ランチャーと `app\` フォルダは一緒に移動できる。`Bubilator88C.dll` や
`swiftCore.dll` は `app\` 内で EXE と同じフォルダに置いたままにする。
ROM (`N88.ROM` 等) は従来どおり
`%LOCALAPPDATA%\Bubilator88\` に配置する。配布物に実機由来のROMは含まない。
ランタイムが未導入の PC では起動できないのが共有版の仕様。

開発用に共有版だけを作り直す場合:

```powershell
pwsh scripts\build-windows-package.ps1 -Version 0.0.0-local -Variant SharedRuntime -SkipCoreBuild
```

`-SkipCoreBuild` は `windows\Bubilator88.Windows\native\Bubilator88C.dll` が
既にある場合に使う。コアもビルドし直す場合は外す。

軽量版は展開したフォルダの `INSTALL-RUNTIME.txt` に導入先を記載する。WinUI 3 の
ランタイムはアプリごとではなく Windows App SDK の共有パッケージとして導入される。
同一の 2.5 系内では更新されたランタイムをブートストラッパーが選択するが、別の
メジャー/マイナー系列だけを導入済みでも、このアプリの 2.5 系依存を満たさない。
ランタイムは各アプリの ZIP に含めないので、複数アプリ・更新間で共有できる。

スクリプトは依存 Swift DLL の選別、未使用ファイルの削除、起動スモークテスト、ZIP と
SHA-256 の算出も行う。`-Variant SingleFile` または `-Variant SharedRuntime` で片方だけ
作成できる。主なオプション: `-SkipCoreBuild` (既存 DLL を使い回す)、`-RunCoreTests`、
`-SwiftRuntimeBin`、`-SkipSmokeTest` (GUI を起動できない環境向け)。CI と Windows
リリースワークフローも両方を作り、リリースには2つの ZIP を添付する。共有版の
起動スモークテスト前には CI が Windows App SDK 2.5.1 ランタイムと .NET 10 SDK
（.NET 10 ランタイムを含む）を導入する。

## AIツールからの操作（MCP）

Settings → General → **AI Control (MCP)** の **Allow control from AI tools** を有効にする。
既定の接続先は `http://127.0.0.1:18801/mcp`。ポートは変更可能。
クライアントを選び、表示された登録コマンドまたは設定をコピーする。
macOS版と同じ8種類の登録形式を用意し、コマンドはPowerShell用に1行で表示する。
トークンは初回に生成し、ほかの設定と同じ `%LOCALAPPDATA%\Bubilator88\settings.json`
に保存する。登録内容にはトークンが含まれる。

MCPプロトコルとツールはCoreの共通実装を使う。Windows側はHTTP通信とアプリ操作を担当し、
`b88_mcp_app_session_create` の型付きアプリ用ホストからCコールバックで呼ばれる。
要求・応答のJSON-RPCをC#で解析・補正することはない。責務分担、スレッド境界、検証方法は
[MCP.md](MCP.md) を参照。

保存・復元・マウントは通常UIとMCPで同じアプリ操作を使う。セーブ状態はmacOS版と同じ
`AMTA`／`THMB` 内蔵の単一 `.b88s` に統一し、原子的に置換する。旧Windows版の
サイドカーファイルは読み込み互換を残す。

**依存関係:** 型付きMCPセッションAPIを含むCore 1.11.0以降が必要。
WindowsのCIと配布ビルドは、macOS版と同じ `Package.resolved` のCoreリビジョンを使用する。
既存の `b88_mcp_handle` / `b88_mcp_reply`
のシグネチャとヘッドレス動作は維持する。

MCP では共通コアが提供する画面・テキスト・メモリの確認、入力、デバッグ、記録等の
ツールも使えるため、通常メニューの未対応一覧と MCP のツール一覧は一致しません。
MCP が使えることは、Windows に対応する設定画面や録画・スクリプト UI があることを意味しません。

## 保存先と注意点

| 保存するもの | 場所 |
| --- | --- |
| 実機 ROM・任意のリズム WAV | `%LOCALAPPDATA%\Bubilator88\` |
| 設定・MCP トークン | `%LOCALAPPDATA%\Bubilator88\settings.json` |
| セーブステート | `%LOCALAPPDATA%\Bubilator88\SaveStates\` |
| ダウンロードした Quality モデル | `%LOCALAPPDATA%\Bubilator88\DownloadedModels\` |
| スクリーンショット | 既定は Windows の「ピクチャ」。Settings → General で変更可能 |

ディスク内で行った保存を元のイメージファイルへ書き戻す機能はありません。
終了前にクイック保存またはスロット保存を行ってください。
配布サイズの測定や旧 SDK の起動問題の調査記録は [PACKAGING_NOTES.md](PACKAGING_NOTES.md) にまとめています。
