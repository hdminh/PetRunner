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
# macOS app and tests (builds the Rust bridge first)
./script/test_macos.sh
PETRUNNER_RUN_INSTALLED_PET_TESTS=1 ./script/test_macos.sh --filter InstalledPetsIntegrationTests
./script/build_and_run.sh

# npm CLI
npm test
npm pack --dry-run

# Windows (run on Windows with the .NET 10 SDK)
dotnet run --project windows/PetRunner.Tests/PetRunner.Tests.csproj
.\script\build_and_run.ps1
.\script\package_windows.ps1
```

`script/build_and_run.sh` stages a debug app at `dist/PetRunner.app` and opens
it. `script/package_macos_release.sh` makes a universal, ad-hoc-signed DMG.
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
