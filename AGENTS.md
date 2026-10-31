# AGENTS.md

This file provides guidance to AI coding agents (Codex, Claude Code, etc.) when
working with code in this repository. It is the canonical source — other
agent-specific files (e.g. `CLAUDE.md`) point back here rather than
duplicating content.

## Project Overview

Bubilator88 is a **behavioral emulator** for the NEC PC-8801-FA computer, built
as a macOS-native SwiftUI application. It reproduces externally observable
hardware behavior for commercial software compatibility — it does NOT simulate
at the transistor, gate, or LSI level.

Platform: macOS only. Deployment targets are **not** uniform: the app target is
26.0, the project and test targets are 26.2, and the core's `Package.swift`
declares `.macOS(.v15)`.

## Build, Test & Lint

```bash
# Build
xcodebuild -scheme Bubilator88 -configuration Debug build

# Run Bubilator88Core unit tests (primary test suite; runs in the core clone)
cd ../Bubilator88Core && swift test

# Run app-level tests (UI tests, template test)
xcodebuild test -scheme Bubilator88 -configuration Debug

# Run UI tests only
xcodebuild test -scheme Bubilator88 -only-testing:Bubilator88UITests -configuration Debug

# Regression suite (15 scenarios, pixel comparison; also available as /regression).
# Rebuild BootTester first: the script runs the existing binary without rebuilding.
swift build --package-path ../Bubilator88Core
python3 scripts/regression_compare.py

# Format (2-space indent) and lint — both cover the app and the core clone
scripts/format_all.sh          # or --check to verify without writing
scripts/lint.sh
```

Lint is not wired into the build; see Code Style for why.

### Checking What a First-Time User Gets

Verify changes to signing, entitlements, the `Info.plist` type and document
declarations, the Quick Look extensions or `release.yml` on a fresh macOS VM,
not on the development Mac. LaunchServices there keeps every build Xcode ever
registered (DerivedData, `build/`) and past "Open With" choices, so it shows
which copy wins rather than what an installed DMG does — v1.5.0 shipped Quick
Look extensions that macOS refused to register, and nothing on the
development Mac showed it.

```bash
# Needs Tart: brew install openai/tools/tart (the old cirruslabs/cli tap is stale).
# Takes a DMG or a release tag; --bios lets .d88 thumbnails boot.
scripts/vm_release_check.sh --bios ~/Library/Application\ Support/Bubilator88 \
  path/to.dmg some.b88s some.d88
```

To test unreleased code, run `release.yml` by hand (workflow_dispatch builds
the DMG as an artifact without attaching it to a release) and pass that DMG.
To ask Quick Look for a thumbnail, use `scripts/ql_thumbnail_check.swift`:
`qlmanage -t` hangs on app thumbnail extensions on macOS 27.

## The Core Is a Separate Repository

The emulation core is the public Swift package
[bubio/Bubilator88Core](https://github.com/bubio/Bubilator88Core). The Xcode
project depends on it remotely, pinned in
`Bubilator88.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
(requirement: up to next major from the version in `project.pbxproj`). The core
repository deliberately carries no agent instructions or tooling: this file,
the scripts, the regression suite and `docs/develop` all stay here and apply to
core work too.

- **Clone it next to this repository**: `../Bubilator88Core`. Everything here
  looks there by default (`BUBILATOR88_CORE_DIR` overrides it). The folder name
  must stay `Bubilator88Core`: Xcode matches a local override to the remote
  package by the folder name.
- **Develop in `Bubilator88Dev.xcworkspace`**, not the bare project. It lists
  the project and `../Bubilator88Core`, so the local core overrides the remote
  one and core edits build straight into the app. Never drag the core into the
  project itself — that rewrites `project.pbxproj`.
- **Opening the bare project builds the pinned core**, which is fine for
  app-only work. A Debug build of a tagged core is about ten times slower (tags
  drop the core's Debug `-O`; see the core's README), so use the workspace for
  anything that runs the machine.
- **Changing both sides**: merge the core change, tag a release with the core's
  Release Tag workflow (patch for fixes, minor for new API), then update the
  pin here in the same PR as the app change that needs it — raise
  `minimumVersion` in `project.pbxproj` when the app needs the new version, and
  run `xcodebuild -resolvePackageDependencies` so `Package.resolved` follows.
  The Windows workflows build whatever `Package.resolved` pins.
- **Core commits are made in the core clone** (`git -C ../Bubilator88Core …`)
  and its pull requests go to bubio/Bubilator88Core. Refer to this repository's
  pull requests there as `bubio/Bubilator88#N`.
- **Release tags on the core come only from its Release Tag workflow**
  (`scripts/tag-release.sh` in the core repository), never a hand-made
  `git tag`.

## Architecture

- **Layer structure:** Bubilator88Core (pure Swift, no platform APIs) ← App
  (SwiftUI/AppKit). Lower layers must never depend on upper layers.
- **Timing:** T-state based, not frame-based. Machine orchestrates all
  progression. GVRAM access adds 1T WAIT during active display.
- **Memory map (default):** 0x0000–0x7FFF ROM (N88-BASIC), 0x8000–0x83FF text
  window, 0x8400–0xBFFF Main RAM, 0xC000–0xFFFF GVRAM (banked) or Main RAM.
  Unimplemented I/O ports return 0xFF.

### Design Documents

`docs/develop` is a private git submodule (`bubio/dev-docs`, `Bubilator88/`
subfolder) holding internal design notes, investigation logs, and hardware
spec references (`docs/develop/SPECS/`) that are kept out of this public repo.
It requires access to the private repo and `git submodule update --init` to
populate; if it is empty, treat those docs as unavailable rather than assuming
the content does not exist.

Updating these docs:

- **Commit straight to the `bubilator88` branch of `bubio/dev-docs`** — no
  topic branch or pull request. A fresh checkout leaves the submodule on a
  detached HEAD, so first run
  `git -C docs/develop checkout -B bubilator88 origin/bubilator88` (after a
  `fetch`), then commit there.
- **Push the dev-docs commit before pushing this repository**, so the pointer
  never names a commit the remote does not have.
- **Bump the `docs/develop` pointer in the same commit or PR as the change it
  documents** (`git add docs/develop`), as `c24c408` did.

| Document | Contents |
| --- | --- |
| `ARCHITECTURE.md` | Full design document |
| `KNOWN_PITFALLS.md` | Regression lessons |
| `BOOTTESTER.md` | CLI test harness |
| `PERSISTENCE.md` | Inventory of persisted data |
| `URL_SCHEME.md` | `bubilator88://` URL scheme and CLI launch arguments (QUASI88-compatible syntax, FlipDisk integration) |
| `AI_MODEL_DOWNLOAD.md` | On-demand download of Quality AI models: `models-v*` release tags, manifest, UX, Windows plan |
| `FMGEN_FORK_COMPARISON.md` | Fixes in fmgen forks and whether Bubilator88 has them |
| `MEMORY_WAIT_STATES.md` | Memory wait specification and status. All four classes (M1 / main RAM / TVRAM / GVRAM) are implemented; waits during HALT are the remaining gap |
| `RELEASE_1_5_0_PLAN.md` | 1.5.0 plan: dependency order and verification for the two-thread split, SwiftUI modernization, monitor types, GVRAM waits and M1 waits |
| `RELEASE_EXCLUSIVITY.md` | Why distribution builds use `unchecked` exclusivity, the CI gates that verify it, and how to re-verify locally |
| `AI_WORKFLOW.md` | Guide to AI-assisted development, written for humans |
| `AUTOMATION.md` | AI agent control over MCP: the tools in the core's `Bubilator88Automation`, the app's Streamable HTTP server, the headless `bubilator88-mcp`, and the Windows entry point |
| `PAR_CHEAT_CODES.md` | 88PAR (`.pat`) cheat code format, pat.dll behaviour from disassembly, and how it maps onto Bubilator88. The primary sources (PATCH.DOC, pat.dll, QUASI88 glue, the code lists) are preserved in `PAR/` |

## Development Rules

- **Strict incremental TDD** — each phase must compile and pass tests before
  proceeding.
- **No speculative behavior** — if uncertain, document with TODO, do not guess.
- **Public APIs must not be modified once stabilized.**
- **Run the regression suite before committing any change to the core's
  `Sources/`** (`/regression`, i.e. `scripts/regression_compare.py`). Do not
  ship if it reports a true regression.
- **Persist reusable scripts** — save reusable Python/shell scripts for
  analysis, conversion, or debugging to `scripts/` rather than regenerating
  them each time.
- Unit tests use the Swift Testing framework (`@Test`); UI tests use XCTest.
- BIOS files are never bundled — they are loaded from
  `~/Library/Application Support/Bubilator88/`. The one exception is the
  substitute kanji ROMs in `Shared/SubstituteKanji/`, generated from the
  public-domain Shinonome fonts and the core's built-in 8×8 font by
  `scripts/make_substitute_kanji_rom.py` and
  used only when the user has no `KANJI1.ROM` / `KANJI2.ROM`.
- No additional LSI-level classes unless explicitly justified.

## Windows Native Port

`windows/` holds a C# + WinUI 3 shell that drives the same Bubilator88Core
through a C ABI DLL (`Sources/CApi/` in the core, built as the `Bubilator88C`
product). The shell's own rules, CI triggers and parity gaps live in
`windows/CLAUDE.md`, which loads when working under `windows/`. Two rules
belong here because they apply to the core, which is a separate clone:

- **The C ABI is additive-only.** Do not change the signature or semantics of
  an existing `b88_*` function; add a new one instead. Shipped Windows binaries
  and the source tree drift apart between releases.
- **Every `@_cdecl` function in the core's `Sources/CApi/` must be `public`.**
  On Windows, Swift exports only a DLL's public symbols; a non-public one still
  builds while the DLL silently loses it. The core's CI compares the DLL's
  export table with the `@_cdecl` names.

## Code Style

- **2-space indentation.** Enforced by SwiftFormat via `scripts/format_all.sh`;
  the `.swiftformat` config enables only `indent` and `trailingSpace`, so the
  formatter can never rewrite code — a run must leave
  `git diff --ignore-all-space` empty.
- **Comments are English DocC.** Use `///` for API documentation and `//` for
  implementation notes. Japanese stays only where it is the subject rather than
  the prose: game titles, PC-8801 keytop legends (画面消去, 説明, 半角), kana that
  is itself the data, and direct quotations from QUASI88.
- **Hardware findings are documentation.** Comments recording real-hardware
  behaviour pair with `docs/develop/KNOWN_PITFALLS.md` — translate or edit them
  faithfully rather than compressing them.
- **SwiftLint is lenient and warning-only** (`.swiftlint.yml`). Rules that fight
  the deliberate column alignment used in bit-manipulation and lookup-table code
  (`comma`, `colon`, `switch_case_alignment`) are disabled on purpose. Do not
  re-enable them to "fix" alignment.
- **Lint runs from `scripts/lint.sh`, never from the build.** A SwiftLint build
  tool plugin was tried and reverted: plugin approval is per-user state (Xcode's
  defaults for the GUI, `~/Library/org.swift.swiftpm/security/plugins.json` for
  the CLI) and cannot be committed, so every `xcodebuild` invocation on every
  machine would have needed `-skipPackagePluginValidation` forever. Adding it to
  the core's `Package.swift` was never viable either: that manifest is also
  built on Windows (`.github/workflows/release-windows.yml`) and
  SwiftLintPlugins ships macOS-only binary artifacts. The core has no lint or
  format configuration of its own; `scripts/lint.sh` and
  `scripts/format_all.sh` apply this repository's to it.
- **`git blame`**: run `git config blame.ignoreRevsFile .git-blame-ignore-revs`
  once so the whole-tree reindent does not mask real authorship.

## Localization

UI strings live in String Catalogs and English is the source language, so **the
key is the English string**. The details — call-site forms, the catalog-filling
trap, and how the core reports localizable errors — are in the `localization`
skill (`.claude/skills/localization/SKILL.md`).

## Logging

Both layers log through **swift-log**. `Bubilator88/Utilities/OSLogHandler.swift`
bridges it to `os_log` under the subsystem `com.bubio.Bubilator88`, with the
swift-log label's last component as the category
(`Bubilator88Core.UPD765A` → `UPD765A`). `bootstrapLogging()` is called from
`AppDelegate.init()` — the earliest hook available, and it must stay ahead of the
first `Logger` construction anywhere, because a `Logger` captures its handler for
good at construction time.

```bash
log stream --level debug --predicate 'subsystem == "com.bubio.Bubilator88"'
```

Name loggers `App.<Component>` in the app layer and `Bubilator88Core.<Component>`
in the core. DEBUG builds admit `.debug`; release starts at `.info`. `print()` is
reserved for BootTester, which is a CLI writing to stdout on purpose.
