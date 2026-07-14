# PetRunner

PetRunner is a lightweight desktop companion that renders [Codex-compatible custom pets](https://github.com/openai/codex) above your windows. It is a menu-bar app on macOS and a system-tray app on Windows; it reads local pet packages and never starts or connects to Codex.

## Highlights

- Runs as a transparent, always-on-top desktop pet across Spaces/desktops.
- Loads multiple pet packages, with previews and validation errors in the app menu.
- Supports sprite-sheet formats V1 and V2; V2 pets follow the pointer while idle.
- Lets you click to jump, drag to reposition or throw, and resize from the lower-right corner.
- Remembers the chosen pet, size, and on-screen position.

## Requirements

| Platform | Requirement |
| --- | --- |
| macOS | macOS 14+ and a Swift 6 toolchain (Xcode is the simplest way to install it). |
| Windows | Windows x64 and the .NET 10 SDK for local development. Published builds are self-contained. |

## Run locally

### macOS

Run directly from the Swift package while editing source:

```bash
swift run PetRunner
```

Or build the local `.app` bundle and launch it:

```bash
./script/build_and_run.sh
```

This builds the Swift package and stages an unsigned local app at `dist/PetRunner.app`. The menu-bar paw icon opens controls for choosing a pet, changing its size, reloading packages, and quitting.

Useful development modes:

```bash
./script/build_and_run.sh --debug
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --verify
```

### Windows

Run directly from source in PowerShell:

```powershell
dotnet run --project windows/PetRunner.Windows/PetRunner.Windows.csproj
```

The tray icon provides the same pet, size, reload, and quit controls.

## Using PetRunner

| Action | Result |
| --- | --- |
| Click the pet | Makes it jump. |
| Drag the pet | Moves it. Release quickly to throw it; it bounces within the visible screen. |
| Drag the lower-right corner | Resizes it continuously (80–224 px wide). |
| Open the menu-bar/tray icon | Change pet, select a preset size, reload packages, or inspect unavailable pets. |

Preset sizes are Small (80 px), Medium (112 px), Large (160 px), and XL (224 px).

## Pet library

By default, PetRunner scans `${CODEX_HOME:-~/.codex}/pets`. To use a different library while developing, pass `--pets-dir`:

```bash
# macOS
dist/PetRunner.app/Contents/MacOS/PetRunner --pets-dir /path/to/pets

# Windows
dotnet run --project windows/PetRunner.Windows/PetRunner.Windows.csproj -- --pets-dir C:\path\to\pets
```

Each immediate subdirectory is treated as one pet package:

```text
pets/
└── my-pet/
    ├── pet.json
    └── spritesheet.webp
```

### `pet.json`

```json
{
  "id": "my-pet",
  "displayName": "My Pet",
  "description": "A friendly desktop companion.",
  "spriteVersionNumber": 2,
  "spritesheetPath": "spritesheet.webp"
}
```

All fields are optional: `id` defaults to the directory name, `displayName` defaults to `id`, `spriteVersionNumber` defaults to `1`, and `spritesheetPath` defaults to `spritesheet.webp`.

The sheet must be a PNG or WebP file within its package directory. Every frame is 192 × 208 px, arranged in eight columns:

| Version | Sheet dimensions | Behavior |
| --- | --- | --- |
| V1 | 1536 × 1872 px (9 rows) | Standard animations. |
| V2 | 1536 × 2288 px (11 rows) | Standard animations plus idle pointer tracking. |

PetRunner rejects malformed manifests, duplicate IDs, unsupported versions and file types, paths outside the package, missing sheets, and sheets with incorrect dimensions. Reload after adding or changing a package.

### Install Codex pets

These sources can supply or create packages that PetRunner can use:

- [Petdex gallery](https://petdex.crafter.run/) — browse community pets, then install one with `npx petdex install <slug>`. The [Petdex CLI docs](https://petdex.dev/docs) describe the available commands.
- [Codex Pets](https://codex-pets.net/) — another community gallery. Its displayed install snippets target macOS/Linux (`mkdir`, `curl`, and `unzip`), so on Windows download the ZIP and use the manual PowerShell steps below instead.
- [OpenAI's Hatch Pet skill](https://github.com/openai/skills/blob/main/skills/.curated/hatch-pet/SKILL.md) — create and validate a custom Codex-compatible pet from a prompt or reference art.
- [Hatch Pet guide](https://www.hatch-pet.com/) — a visual guide to enabling Codex pets and creating a custom package.

Most installers place a package in the default directory automatically. To install a downloaded package manually, copy its directory—not just its two files—into the library, then reload PetRunner:

```bash
mkdir -p "${CODEX_HOME:-$HOME/.codex}/pets"
cp -R /path/to/downloaded-pet "${CODEX_HOME:-$HOME/.codex}/pets/"
```

On Windows, the equivalent destination is `%USERPROFILE%\.codex\pets\` unless `CODEX_HOME` is set. Treat community packages as untrusted downloads: inspect `pet.json` and the image file before installing, and keep only the manifest and PNG/WebP sprite sheet in each pet directory.

To unpack a downloaded ZIP in PowerShell, replace the placeholders with the downloaded file and a unique pet folder name:

```powershell
$pets = if ($env:CODEX_HOME) { Join-Path $env:CODEX_HOME 'pets' } else { Join-Path $HOME '.codex\pets' }
$destination = Join-Path $pets 'my-pet'
New-Item -ItemType Directory -Force -Path $destination | Out-Null
Expand-Archive -LiteralPath 'C:\path\to\downloaded-pet.zip' -DestinationPath $destination -Force
```

If the ZIP contains an extra top-level directory, move `pet.json` and the sprite sheet up so they sit directly under `$destination`, then select **Reload Pets** in PetRunner.

## Test and package

Run the macOS Swift tests:

```bash
swift test
PETRUNNER_RUN_INSTALLED_PET_TESTS=1 swift test --filter InstalledPetsIntegrationTests
```

Run the Windows tests:

```powershell
dotnet run --configuration Release --project windows/PetRunner.Tests/PetRunner.Tests.csproj
```

Create distributable artifacts:

```bash
# Universal macOS DMG and SHA-256 file in dist/release/
./script/package_macos_release.sh
```

```powershell
# Self-contained Windows x64 executable and SHA-256 file in dist/windows-x64/
.\script\package_windows.ps1
```

The macOS release script creates an ad-hoc code signature; distribute a notarized build separately if Gatekeeper trust is required.
