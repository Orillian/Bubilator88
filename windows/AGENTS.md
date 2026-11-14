# Windows native port

Guidance for the C# + WinUI 3 shell under `windows/`. The repository-wide
instructions are in `AGENTS.md` at the repository root; this file adds what
only matters when working on the Windows side. The two C ABI rules that apply
to the core (additive-only signatures, `@_cdecl` must be `public`) stay in
`AGENTS.md`, because the core is a separate clone that this file does not
cover.

The shell drives the same Bubilator88Core through a C ABI DLL (`Sources/CApi/`
in the core, built as the `Bubilator88C` product). It lives in `main` alongside
the macOS app rather than in a fork: the emulation core is the product, so every
accuracy fix is a Windows fix too, and a fork would turn each one into a
permanent cherry-pick. Windows builds use the same core revision as the macOS
app (`.github/actions/checkout-core`).

The Windows-specific footprint inside the Swift package is deliberately tiny —
the `CApi` target (new files only), the `Bubilator88C` product in
`Package.swift`, and one `#if os(Windows)` in `Peripherals/UPD1990A.swift`.
No emulation logic is conditional on the platform, and it must stay that way.

Rules:

- **Bubilator88Core is macOS-first.** Accuracy decisions are judged by the macOS
  regression suite. Never bend the core's design for the Windows shell.
- **The Windows shell may lag.** Core features can land without a C# counterpart.
- **A red `ci-windows.yml` does not block macOS work.** It records that Windows
  broke and which commit did it; fixing it can wait for the next Windows release.

`ci-windows.yml` runs on `main` pushes and PRs that change the core pin
(`Package.resolved`), `windows/**`, `models/onnx/**`, the shared core checkout
action, the packaging script or the CI workflow itself. See the workflow for
the exact path filters. `release-windows.yml` builds the distributable on
`win-v*` tags, independent of the macOS release. Details and the current parity
gaps: `windows/README.md`, `docs/develop/WINDOWS_PORT.md`.
