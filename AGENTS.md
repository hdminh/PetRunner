# PetRunner contributor guide

PetRunner is a local desktop renderer for Codex-compatible custom pets. It does
not start, embed, or connect to Codex. By default it reads
`${CODEX_HOME:-~/.codex}/pets`; both apps also accept `--pets-dir <path>`.

## Repository layout

- `Sources/PetRunnerCore/`: shared macOS pet parsing, animation, atlas, and
  physics logic.
- `Sources/PetRunner/`: macOS 14+ AppKit menu-bar app and overlay window.
- `Tests/PetRunnerCoreTests/`: Swift Testing coverage for the macOS core.
- `windows/PetRunner.Core/`: Windows counterpart of the core behavior.
- `windows/PetRunner.Windows/`: Windows 10/11 WPF tray and overlay app.
- `windows/PetRunner.Tests/`: self-hosted .NET test executable.
- `bin/` and `lib/`: Node 18+ npm CLI that installs/builds PetRunner locally.
- `Support/Package.runtime.swift`: dependency-free SwiftPM manifest used only
  by the npm-installed runtime source. Keep it aligned with production targets
  in `Package.swift`, but do not add test-only dependencies to it.
- `Assets/`: committed application icons. Regenerate deliberately with
  `script/generate_app_icons.sh`; do not hand-edit generated icon formats.

## Development commands

Run commands from the repository root.

```bash
# macOS app and tests
swift test
PETRUNNER_RUN_INSTALLED_PET_TESTS=1 swift test --filter InstalledPetsIntegrationTests
./script/build_and_run.sh

# npm CLI
npm test
npm pack --dry-run

# Windows (run on Windows with the .NET 10 SDK)
dotnet run --project windows/PetRunner.Tests/PetRunner.Tests.csproj
.\script\build_and_run.ps1
.\script\package_windows.ps1
.\script\package_windows_msix.ps1
```

`script/build_and_run.sh` stages a debug app at `dist/PetRunner.app` and opens
it. `script/package_macos_release.sh` makes a universal, ad-hoc-signed DMG.
`script/package_windows.ps1` publishes self-contained `PetRunner.exe` builds.
`script/package_windows_msix.ps1` builds Partner Center–ready `.msix` packages
(Windows + Windows SDK `MakeAppx` required; Parallels VM is fine). Supply the
Partner Center identity, publisher, and publisher display name as arguments;
they are deliberately not stored in the repository.
`dist/`, `.build/`, and nested .NET `bin/`/`obj/` outputs are generated and
ignored. The top-level `bin/` directory is npm CLI source and is committed.

## Behavioral contracts

- Validate pet packages defensively. Never follow a spritesheet symlink outside
  its pet package.
- Keep macOS and Windows behavior aligned when changing parsing, sprite-atlas
  addressing, animation timing, physics, pointer tracking, or CLI arguments.
- V2 atlas dimensions and look-direction mapping are compatibility contracts;
  add/adjust tests in both platforms when changing them.
- Do not modify a user's pet library. The runner may scan and reload it only.
- Preserve the default pet location and `CODEX_HOME` override on both platforms.

## npm CLI and release rules

- The npm package bundles source and builds it in per-user application storage;
  it must not use `postinstall` or download unsigned executable releases.
- Maintain the `files` allow-list in `package.json` whenever a runtime source
  file is added. Verify it with `npm pack --dry-run`.
- The published package is `@hdminh/pet-runner`; users invoke it with
  `npx @hdminh/pet-runner start`. The executable bin remains `pet-runner`.
- Package versions are immutable after npm publish. Bump the version before any
  follow-up publish and verify the packed tarball before publishing.
- Do not publish, unpublish, modify npm access, or change dist-tags unless the
  user explicitly asks for that external action.

## Change hygiene

- Add focused tests for behavior changes. Run the relevant platform suite and
  `npm test` when touching the CLI.
- Keep changes scoped; this repository may contain a dirty working tree from
  ongoing work. Do not discard or overwrite unrelated modifications.
- Prefer `apply_patch` for edits. Do not commit generated build artifacts.

## Cursor Cloud specific instructions

The Cloud VM runs Linux, but the two native apps target macOS (Swift/AppKit)
and Windows (.NET 10/WPF). Neither `swift` nor `dotnet` is installed and neither
app can build or run on Linux. The Linux-developable/runnable surface is the
`DashboardWeb/` React+Vite frontend and the JavaScript test suites.

- Install deps with `npm install --force`. Plain `npm install` fails with
  `EBADPLATFORM` because `package.json` declares `"os": ["darwin","win32"]`;
  `--force` downgrades that check to a warning (dev-only, on Linux).
- Runnable on Linux (see `package.json` scripts): `npm test` (CLI unit tests),
  `npm run dashboard:typecheck`, `npm run dashboard:test` (Vitest),
  `npm run dashboard:build`, and `npm run dashboard:dev` (Vite dev server at
  `http://localhost:5173/`).
- The dashboard SPA expects the native app's embedded loopback API
  (`api/v2`, falling back to `api/v1`). On Linux that server does not exist, so
  the dev server shows an "Offline"/"Request failed (404)" banner and empty
  data. This is expected — the UI, routing, and client-side controls still
  work; it is not a bug to fix.
- The npm CLI (`pet-runner start/install/update`) errors on Linux because
  `resolveInstallPaths` only supports darwin/win32, so it cannot build or launch
  the native app here. Test the CLI via `npm test`, not by running it.
- Swift/.NET suites (`swift test`, the `dotnet` test project) and the
  `build_and_run`/packaging scripts require macOS or Windows; run them there.
