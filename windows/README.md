# Bubilator88 — Windows ネイティブ版

macOS 版と**同一の Swift エミュレーションコア**を Windows ネイティブ DLL 化し、
C# + WinUI 3 のシェルから P/Invoke で駆動する移植版。描画は D3D11、音声は XAudio2、
AI アップスケールは ONNX Runtime + DirectML。

> 全体方針・移植性監査・実装進捗は `docs/develop/WINDOWS_PORT.md` を参照。
> このファイルは**ビルドと実行の手順書**。

## 構成

```
windows/Bubilator88.Windows/
├── NativeApi.cs              P/Invoke (Bubilator88C.dll の @_cdecl と 1:1)
├── EmulatorHost.cs           native ハンドル管理 + 再利用バッファ (毎フレーム alloc ゼロ)。全呼び出しを SyncRoot で排他
├── EmulationLoop.cs          エミュレーション専用スレッド + 高分解能タイマのペーサ (macOS の EmulationLoop 相当)
├── FramePublisher.cs         完成フレームをエミュスレッド → UI スレッドへ渡す 3 スロット (macOS と同じ)
├── KeyMapping.cs             VirtualKey → PC-8801 15行マトリクス (US/JIS + テンキー擬似)
├── D3DScreen.cs              D3D11 + SwapChainPanel。フィルタ + スキャンライン + レターボックス
├── AiUpscaler.cs             ONNX Runtime + DirectML で AI x2 (3モデル切替、非同期ダブルバッファ)
├── AIModelStore.cs           Quality モデルの任意ダウンロード・検証・保存
├── PixelMath.cs              無依存の画素演算ヘルパ (単体テスト対象)
├── XAudioSink.cs             XAudio2 で 44.1kHz ステレオ float をストリーム (適応レート制御)
├── ImageCodec.cs             スクリーンショット PNG/JPEG/HEIC エンコード
├── WinSaveState.cs           セーブステート/メタ/サムネイルのファイル入出力
├── MainWindow.xaml(.cs)      UI + フレームループ (エミュ側 tick と UI 側の表示) + 入力/ディスク/メニュー
├── MainWindow.SettingsDialog.cs  設定ダイアログ (General/Display/Audio/Keyboard)
├── App.xaml(.cs)
├── Assets/
│   └── AppIcon.ico            ← exe リソース (ApplicationIcon) + タイトルバー/タスクバー用
└── native/
    └── Bubilator88C.dll      ← swift build 成果物を手動配置 (git 管理外)

windows/Bubilator88.Windows.Tests/   シェルの純ロジック xUnit テスト (KeyMapping / PixelMath / FramePublisher など)

Fast / Balanced の 2 モデルは `../../models/onnx/` から出力直下へコピーする。
Quality (`RealESRGAN_x2.onnx`) は初回選択時に確認してからダウンロードし、
`%LOCALAPPDATA%\Bubilator88\DownloadedModels\` に保存する。
source-of-truth と再生成は `../../models/PROVENANCE.md`。
```

コアは別リポジトリ [bubio/Bubilator88Core](https://github.com/bubio/Bubilator88Core)。
このリポジトリと同じ階層に clone しておく (後述)。C ABI シムはその
`Sources/CApi/` 以下のファイル。複数ファイルに分かれており、`b88_*` 関数を
探すときは全体を grep する。

| ファイル | 内容 |
|---|---|
| `CApi.swift` | ハンドル管理、リセット・実行、描画、音声、基本設定、ステートの入出力 |
| `CApiMachine.swift` | 設定の読み戻し (`b88_get_*`)、音声ステム、入力、画面テキスト |
| `CApiMedia.swift` | テープ、ディスクの書き戻し、メモリイメージ、ステートファイル、チートファイル |
| `CApiTyping.swift` | テキスト貼り付け、テープ自動起動、`.n80` ロード |
| `CApiCDROM.swift` | PC-8801MC の CD-ROM ドライブ |

どれも `@_cdecl` 関数は `public` にし、新しい関数は既存の関数に近いファイルへ足す
(下記の ABI ルール)。

## 前提ツール

1. **Swift toolchain for Windows**(swift.org の Windows 版 + Visual Studio Build Tools の
   C++ ワークロード)。`swift --version` が通ること。
2. **Visual Studio 2022** + **Windows App SDK / .NET デスクトップ** ワークロード、**.NET 10 SDK**。
3. **Git LFS**(`git lfs version` が通ること)。AI モデルが LFS 管理のため。
4. ROM 一式を `%LOCALAPPDATA%\Bubilator88\` に配置(`N88.ROM` 必須、`DISK.ROM` 等は任意)。
   macOS の `~/Library/Application Support/Bubilator88/` と同じ顔ぶれ(`../docs/PERSISTENCE.md`)。

## チェックアウト

```powershell
git lfs install            # マシンごとに一度 (LFS フックを有効化)
git clone git@github.com:bubio/Bubilator88.git
git clone git@github.com:bubio/Bubilator88Core.git   # コア。Bubilator88 と同じ階層に置く
cd Bubilator88
git lfs pull               # 同梱する Fast / Balanced モデルの実体を取得
```

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
# 成果物 (例): .build\release\Bubilator88C.dll を shell の native\ にコピー
Copy-Item .build\release\Bubilator88C.dll ..\Bubilator88\windows\Bubilator88.Windows\native\
```

まずコア健全性を確認(macOS と同じ結果になるはず):

```powershell
swift test -Xswiftc -enforce-exclusivity=unchecked  # 760+ ユニットテスト
swift run BootTester "C:\path\game.d88"     # テキストVRAMダンプ等
```

> **エクスポートに関する注意**: Swift は DLL の `public` な記号を自分で書き出す。
> `Sources/CApi/` の `@_cdecl` 関数は必ず `public` にすること
> (付け忘れてもビルドは通り、P/Invoke が実行時に失敗する)。コアの CI が DLL の
> 書き出し表と `@_cdecl` の一覧を突き合わせている。

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
  再生成手順は `..\..\models\PROVENANCE.md`(Balanced はコンパイル済 `.mlmodelc` から復元)。
- csproj は Fast / Balanced の 2 モデルだけを出力直下へコピーする。Quality は
  `models-v1` の ONNX asset から任意ダウンロードする。いずれも未準備なら Bicubic フォールバック。

### 3. シェルをビルド & 実行

```powershell
cd windows\Bubilator88.Windows
dotnet run -c Release -r win-x64
```

> **ランタイム依存**: `Bubilator88C.dll` は Swift ランタイム DLL(`swiftCore.dll` 等)に依存する。
> 開発機では `...\Swift\Runtimes\6.3.2\usr\bin` が PATH 上なので `dotnet run` で解決するが、
> 単体配布する場合は同 bin の DLL 群を exe の隣に同梱する必要がある(手動 `dotnet run` では
> 未同梱のまま。配布パッケージは §5 の `build-windows-package.ps1` が自動でバンドルする)。
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
> (`KeyMapping.cs` / `PixelMath.cs`)を**ソースリンク**してヘッドレスに検証する。
> 対象を増やすときは `.csproj` の `<Compile Include=…>` に純ロジックファイルを足す。

### 5. 配布パッケージ (zip) をビルド

```powershell
pwsh scripts\build-windows-package.ps1 -Version 1.2.3
```

コア DLL をビルドし、Fast / Balanced モデル (Git LFS) を確認してから、次の2つを
同じ Windows App SDK **2.5.1** で発行する。単一 EXE 版は .NET 10 を含み、
共有ランタイム版は PC に導入された .NET 10 を使う。必要な Swift DLL は両方に
同梱し、ROM と任意ダウンロードの Quality モデルは含まない。

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
`%LOCALAPPDATA%\Bubilator88\` に配置する。配布物に ROM は含まない。
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

2026-09-24 のローカル検証では、単一 EXE ZIP が **138.8 MiB**、共有ランタイム ZIP が
**53.9 MiB**。後者は前者より **84.9 MiB** 小さい (.NET 10 を同梱していた旧共有版は
87.9 MiB)。共有版の `Bubilator88.runtimeconfig.json` は `Microsoft.NETCore.App` 10
だけを要求するので、通常の .NET Runtime 10 (x64) で足りる。
単一 EXE は Swift を PATH から外して
起動し、展開先のコア DLL・Swift DLL・Fast モデル・アイコンの存在を確認した。
共有ランタイム版も公式ランタイム導入後に Swift を PATH から外して起動し、
`Microsoft.UI.Xaml.dll` を共有の `WindowsApps` ディレクトリから、コアと Swift DLL を
配布フォルダからロードすることを確認した。AI 推論・ディスク操作等の操作回帰は
この発行テストには含まない。

#### 配布物のスリム化 (§6 / §6b)

共有ランタイム版のファイル数とサイズを抑えるため、スクリプトは 2 段階で削る。
単一 EXE 版では Swift DLL の依存クロージャだけを発行前に取り込み、展開が必要な
Windows App SDK のファイルは EXE に内包する:

1. **Swift ランタイムは依存クロージャのみ** — `Runtimes\...\usr\bin\*.dll` を全部
   コピーせず、`Bubilator88C.dll` の PE インポートテーブルを `llvm-objdump -p`
   (Swift toolchain 同梱) で再帰的に辿り、実際に静的依存する DLL だけを入れる
   (32 個 → 17 個)。`FoundationNetworking` / `FoundationXML` / `swiftDistributed`
   などは Bubilator88Core が import していないので落ちる。
2. **未使用ファイルの prune** — デバッグシンボル (`*.pdb`、`DirectML.pdb` だけで
   8.6MB)、未使用の WindowsAppSDK 機能 (WebView2 / Widgets / 通知 / MSIX 配置)、
   英語以外の `*.mui` ロケールフォルダ (84 個) を削除する。self-contained な
   WindowsAppSDK には機能単位の on/off スイッチが無いため、発行後に削るしかない。
   削除リストは `build-windows-package.ps1` の `$pruneFiles` に理由付きで並べて
   あるので、WindowsAppSDK / .NET を上げたときはここを再監査すること。

   WinRT のクラスは**実際に使う瞬間**に初めて DLL がロードされる (遅延活性化)
   ため、消しすぎても起動スモークテストでは捕まらない — 例えば WebView2 で
   ヘルプ画面を出す機能を後から足すと、ビルドも起動も通るのに「その画面を
   開いた瞬間だけ落ちる」。そこで WindowsAppSDK 機能の削除には**使用箇所ガード**
   (`$guardedPruneGroups`) を付けてある。シェルの `*.cs` / `*.xaml` を grep し、
   その機能のキーワード (`WebView2` / `AppNotification` / `Microsoft.Windows.Widgets`
   など) が 1 つでも見つかれば prune を取りやめ、警告を出す:

   ```
   WARNING: WebView2 を使い始めた形跡があるため prune しません
            (.\windows\Bubilator88.Windows\HelpWindow.xaml.cs:42)。
   ```

   安全側 (= 同梱する) に倒れるので、機能追加時に気づかず壊れることはない。

削りすぎていないかは §7 のスモークテスト(実際に exe を起動してメインウィンドウが
出るまで確認する)が検出する。旧 1.6 系フォルダ版の測定では
**414 エントリ / 353MB → 287 エントリ / 324MB** (zip は 181MB → 165MB)。
現行の共有版は Windows App SDK 自体を同梱しない。

> **旧フォルダ版では `WinUIEdit.dll` (3.4MB) をあえて残していた**。`TextBox` / `RichEditBox` を使った
> 瞬間に遅延ロードされる DLL で、現状 XAML・コードとも `TextBox` 系は未使用だが、
> UI を足した途端に落ちる類の削除なのでサイズ以上にリスクが大きい。

#### 単一 EXE 配布の検証 (Windows App SDK 1.6 → 2.5.1)

現在のリリーススクリプトは **Windows App SDK 2.5.1** で単一 EXE 版と共有ランタイム版を作る。
以下の 1.6 系の失敗は当時の検証結果であり、SDK 全般の制約ではない。

##### 1.6 系での失敗

`PublishSingleFile=true` でのビルド自体は通り、160MB 程度の単一 exe が生成される
(WindowsAppSDK も `Microsoft.WindowsAppSDK.SingleFile.targets` で明示的にサポート
している)。**しかし、1.6 系では unpackaged + self-contained の構成で起動しなかった**:

```
System.Runtime.InteropServices.COMException (0x80040111): ClassFactory は要求されたクラスを提供できません
   at WinRT.ActivationFactory.Get(String typeName, Guid iid)
   at Microsoft.UI.Xaml.Application.Start(...)
```

当時の調査では WinUI3 の**登録不要 (reg-free) WinRT 活性化**が原因と推定した。`obj\...\Manifests\app.manifest`
に 1808 個の `<winrtv1:activatableClass>` が生成され、それぞれ
`<asmv3:file name="Microsoft.ui.xaml.dll">` のような**ファイル名だけ**の参照になっている。
SxS のアクティベーションコンテキストはこれを **exe があるディレクトリ**基準で解決する
仕様で、single-file では実体が `%TEMP%\.net\<app>\<hash>\` に展開されるため見つからない。
`MICROSOFT_WINDOWSAPPRUNTIME_BASE_DIRECTORY` (SDK の自動初期化子が
`AppContext.BaseDirectory` を入れる) を展開先に向け直しても SxS 側の解決には効かない。
逆に、展開先ディレクトリへ exe をコピーして起動すると正常に動作する
(= DLL の中身ではなく exe の置き場所だけが問題であることの裏付け)。

前提条件 (`EnableMsixTooling` / `WindowsPackageType=None` /
`IncludeAllContentForSelfExtract` / `WindowsAppSdkUndockedRegFreeWinRTInitialize`) は
すべて満たした上での結果だった。

##### 2.5.1 での再検証 (2026-09-24、Windows 11 / win-x64)

ソースを独立した検証用ディレクトリへコピーし、Windows App SDK を `2.5.1` に固定。
`PublishSingleFile=true`、`IncludeAllContentForSelfExtract=true`、`SelfContained=true` を
追加して `dotnet publish -c Release -r win-x64` を実行した。既存の
`WindowsPackageType=None`、`WindowsAppSDKSelfContained=true`、`EnableMsixTooling=true`
は維持。**単一 EXE の発行と起動は成功した**。Swift toolchain のランタイムを PATH から
外した状態で `Bubilator88` のメインウィンドウが開き、Swift コア DLL・`swiftCore.dll`・
D3D11 のロードと、コアの実行ログを確認した。1.6 系の `0x80040111` は再現しなかった。

ただし、最初の発行ではウィンドウだけが開き、Swift コアはロードされなかった。
現行スクリプトは `dotnet publish` **後**に Swift ランタイム DLL をコピーするため、
単一 EXE には入らない。検証では、現行フォルダ配布物に含まれる Swift 依存 DLL 17 個を
発行 **前**に `Content` として出力直下へ組み込んで解消した。モデル 3 個も EXE に含まれ、
起動時の展開先に存在することを確認した。

当時、単一ファイル版をリリースするには、次の対応と検証が必要だった:

- `AiUpscaler.cs` のモデル探索と `MainWindow.xaml.cs` のタイトルバーアイコン探索は
  `AppContext.BaseDirectory` (EXE の場所) を見るが、モデルと `Assets/AppIcon.ico` は
  `%TEMP%\.net\Bubilator88.Windows\<hash>\` に展開される。展開先を参照できるようにし、
  AI フィルタ 3 種とアイコン表示を実操作で確認する。
- EXE を別名へ変更すると起動直後に `0xC000027B` で終了した。配布時の名前変更を避ける
  だけでなく、ダウンロード時の自動改名も想定して対処または配布方法を決める。
  同様の報告: <https://github.com/microsoft/WindowsAppSDK/issues/6248>。
- ディスク操作、音声、設定、セーブ状態、AI 推論は未検証。単一ファイル起動時の展開と
  遅延ロードを含めて回帰確認する。

検証用 EXE は **416.7 MiB**、それだけを ZIP 圧縮すると **198.1 MiB**。現行の
prune 済みフォルダ版 ZIP (**165 MB**) とは SDK バージョンと削減処理が異なるため、
単純なサイズ比較はできないが、単一ファイル化は容量削減策ではない。公式手順も
依存ファイルを初回起動時に一時ディレクトリへ展開する方式としている:
<https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/unpackage-winui-app#single-file-exe>。
この検証用のソースと発行物は削除済み。現行の 2.5.1 対応については上の §5 を参照。

## 実装済み機能

- **コア**: Swift→DLL を P/Invoke。`runFrame`/`render_rgba`/キー入力/ディスクマウント。挙動精度は macOS と同一。
- **映像**: D3D11。None/Linear/Bicubic/CRT/xBRZ/Enhanced/**AI (Fast/Balanced/Quality)** の
  フィルタ + スキャンライン。ウィンドウ ×1/×2/×4(固定・永続)、フルスクリーン(整数スケーリング切替)、レターボックス。
- **AI アップスケール**: ONNX Runtime + DirectML で 3 モデル(Fast=SRVGGNet_x2_lite /
  Balanced=SRVGGNet_x2 / Quality=RealESRGAN_x2)を切替(640×400→1280×800)。Fast / Balanced は同梱。
  Quality は初回選択時に確認、ダウンロード進捗、再試行・キャンセルを表示。サイズと SHA-256 を
  検証してから保存し、設定画面で削除できる。保存済みフィルターのモデルが起動時に欠けていれば
  None に戻す。未準備時は Bicubic フォールバック。

Quality のダウンロード先は `models-v1/RealESRGAN_x2.onnx`。2026-09-24 に公開し、
公開 URL から取得したファイルのサイズと SHA-256 がマニフェストと一致することを確認した。
ファイルは 67,072,862 bytes、SHA-256
`74786f9a2680d8c887f51c74131b2233d0f8910c5e5307e1beee71f69a88a4f0`。
- **音声**: XAudio2 リングバッファ + 適応レート制御。**音声サブフレーム化**(Emulation Speed
  x1 時、1フレームを `b88_run_frame_slice` で4スライスに分割し、スライス毎に音声を drain。
  1バーストが ~16.7ms → ~4.5ms に縮み、短めのバッファ設定でのアンダーラン耐性が向上。
  macOS の音声サブフレーム化 (`bubio/Bubilator88#193`) に対応。x2〜x16 の早送りは従来通り
  フレーム一括実行)。フレームループはコアの `b88_frame_rate`(CRTC とモニタ種別から決まる
  実機のフレームレート。24kHz・25行で 55.42Hz)で毎フレームペースを取り直す — 60Hz 固定で
  回すと CPU も YM2608 タイマーも約 8% 速くなる。**2 スレッド構成**(macOS と同じ): エミュレーションは
  専用スレッド (EmulationLoop) が自前のペーサで回し、UI スレッドの CompositionTarget.Rendering は
  完成フレーム (FramePublisher) を表示するだけ。メニューやダイアログで UI が詰まっても音と進行が止まらない。
  最小化中は停止する。早送りの音は x2/x4 は N 倍速(音程も上がる)で
  鳴らし、x8 以上はミュート(macOS 版は全段 N 倍速のまま)。YM2608 リズム音源サンプル読込。音量・バッファ長設定。
  擬似ステレオと **CD Mix**(出力段のローパス + ステレオリバーブ、既定 OFF。`b88_set_cd_mix`)。
  **FDD アクセス音**(シーク/リード音を合成、ドライブ別ステレオ定位、ステータスバーの赤アクセスランプ)は
  メイン音声とは別の専用 XAudio2 エンジンで再生し、出力デバイスを個別に選択可能
  (`NAudio.CoreAudioApi.MMDeviceEnumerator` でデバイス列挙、macOS の `fddSoundDeviceUID` と同じ設計)。
- **ディスク**: マルチイメージ D88、Drive 1/2/1&2、ライトプロテクト、Recent Files、イメージ選択ダイアログ。
- **入力**: VirtualKey→マトリクス(US/JIS 記号、矢印/数字行/WASD のテンキー擬似)、
  メニューのキーボードショートカット(Ctrl+R/P/S/L、Ctrl+Shift+C、Ctrl+1/2/3、F11)。
  **ゲームコントローラ**(`Windows.Gaming.Input.Gamepad` ポーリング、Dpad/ABXY/ショルダー/
  トリガー/スティックをPC-88キーまたはホストコマンドにマッピング、設定ダイアログの
  Controller タブで「キーを押してバインド」/デフォルト復帰が可能)。
- **状態保存**: セーブステート(スロット/クイック、メタ・サムネイル)、スクリーンショット(PNG/JPEG/HEIC)、Emulation Speed(×1〜×16)。
- **設定**: General/Display/Audio/Keyboard/Controller タブ(`settings.json` に即時永続化)。
  General タブの Hardware Configuration でモニタ種別 (24kHz/15kHz)・メモリウェイト DIP・
  拡張 RAM を選択(いずれも次回リセットで反映)。モニタ種別は macOS と同様にセーブステートの
  メタに記録し、ロード時に復元する(記録の無い古いステートは 24kHz 扱い)。
- **テスト基盤**: シェル純ロジックの xUnit プロジェクト。

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

## 未実装(後続 / 別実装枠)

- **CPU オーバークロックの設定 UI**。C ABI (`b88_set_cpu_overclock`) と P/Invoke 宣言は
  あるが、設定画面から選べない。常に ×1 で動く。
- 触覚フィードバック(SSGノイズ検出→振動。Bubilator88Core の CApi 拡張が必要なため別PRで対応予定)
- コントローラーのモデル別マッピング / ブランド別アイコン表示(`Windows.Gaming.Input.Gamepad` は
  製品識別情報を提供しないため、v1 は単一のグローバルマッピング)
- マウスロック(`ClipCursor` + RAWINPUT 相対デルタ)
- **OCR 翻訳オーバーレイ**(`windows/Bubilator88.Windows/Ocr/`)。`Windows.Media.Ocr` で
  実装・実機検証したが、**PC-8801 の小さいフォント(640×400 中 8px 相当)に対する認識率が
  実用に耐えないほど低く**(4倍アップスケール+反転+アンシャープマスクのチューニングを行っても
  ほとんど文字を検出できない)、UI から意図的に隠蔽(マスク)している——View メニュー項目・
  Ctrl+T ショートカットともに存在しない。パイプライン自体(`OcrManager`/`ImagePreprocessor`/
  `OcrTypes`)と `MainWindow` 側の配線(`_ocr` フィールド、フレームループでの `Tick`/
  `TryTakeResult` 呼び出し、`OcrOverlayCanvas`)はコードとして残しているため、認識精度の
  問題(モデル/前処理/`Windows.Media.Ocr` 自体の限界)を解決できる見込みが立った場合は、
  メニュー項目とショートカットキーを再度追加するだけで再有効化できる。翻訳バックエンドは
  そもそも未着手(検出精度がこの状態のため着手を見送り)。
- スキャンラインのテキスト除外(macOS は `renderTextOverlay(markTextPixels:)` が
  テキスト画素を alpha 0xFE でタグ付けし、ディスプレイシェーダがそこだけスキャンライン
  の減光を免除する。D3D11 シェーダ側が未対応のため `CApi` からは `false` を渡している)
- 空間オーディオ / ヘッドトラッキング、操作スクリプト記録
- PC-8001 メモリイメージ(`.n80`)の読み込み(C ABI は公開済み、C# 側は未実装)
- PC-8801MC の CD-ROM ドライブと CD イメージ(`.cue` / `.ccd`)(C ABI は公開済み、C# 側は未実装)
