# Windows 配布パッケージの検証記録

現行の配布手順は [README.md](README.md#配布パッケージ) を参照。
以下は過去のサイズ測定・SDK 移行時の調査記録であり、現在の制約や未完了作業の一覧ではない。
記録中の「現行」「当時」は各検証時点を指す。

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

