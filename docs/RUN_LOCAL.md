# Install and run PetRunner

The npm CLI packages PetRunner's source and builds it on each person's computer.
This keeps distribution convenient without shipping an unsigned executable.

This avoids the usual Gatekeeper or SmartScreen warning attached to a
downloaded unsigned binary. The operating system or antivirus may still scan
the local build; do not disable those protections.

## Pet library

PetRunner reads the existing Codex pet directory by default:

- macOS: `~/.codex/pets`
- Windows: `%USERPROFILE%\.codex\pets`
- custom `CODEX_HOME`: `$CODEX_HOME/pets`

Install pets with Petdex before or after starting PetRunner. PetRunner does not
depend on Petdex or any other pet installer; it only reads compatible files from
the pet directory.

## Quick start

Install Node.js 18 or later, then run:

```bash
npx pet-runner start
```

The first run builds and installs the app locally. Subsequent runs open the
existing build. Use **Reload Pets** from the tray or menu after adding a pet.

To update or remove the local build:

```bash
npx pet-runner update
npx pet-runner uninstall
```

To use a different pet library:

```bash
npx pet-runner start --pets-dir /absolute/path/to/pets
```

## Optional agent monitor (macOS)

PetRunner is pet-only by default. To show broad agent progress beside the pet,
choose **Enable Agent Monitor** from the menu bar. The setup lists Claude Code,
Codex, and Cursor when their usual local configuration directories are found;
every option starts unchecked. Select only the providers you want to monitor.

The hook sends only an opaque session ID, provider name, and one fixed state to
the local app: `Working…`, `Reviewing…`, `Needs approval`, `Finished`, or
`Failed`. It never sends a prompt, command, filename, or transcript and makes
no model request, so it uses no additional model tokens. Each event launches a
small local helper process and makes a short loopback IPC attempt; if PetRunner
is not running, delivery silently does nothing.

Codex may ask you to review and trust the installed hook command. Cursor does
not expose a passive approval event, so it will not display `Needs approval`.
PetRunner keeps a single current state for each active session (up to five,
most-recent first); it does not retain an event history. The expanded bubble
shows the provider, a locally derived `SESSION` label, and fixed state text.
Its attached pixel rail always shows one colored cell for each current session
in MRU order; choose a cell to switch sessions. Use the pixel `-` control to
collapse it into a tight vertical list of only those cells; choosing a compact
cell reopens that session. Yellow means working, cyan reviewing, violet needs
approval, green finished, and red failed. The label is not a task title or raw
session ID, and color is backed by the expanded text plus VoiceOver descriptions.

Choose **Disable Agent Monitor** to remove only PetRunner-owned hook entries
and return to pet-only mode. Existing configuration is parsed before changes;
malformed or unsupported config is left untouched and the action fails rather
than replacing it. A `.petrunner-backup` copy is kept beside any changed
provider config. `npx pet-runner uninstall` runs the same cleanup before it
deletes the installed app. If you remove a manually installed app in Finder,
disable monitoring first so no provider hook points to a missing executable.

## Manual source-build fallback

The following workflow is only needed when developing PetRunner or when npm is
unavailable.

### Get the source

Install Git, then clone the repository:

```bash
git clone https://github.com/hdminh/PetRunner.git
cd PetRunner
```

To update later, run `git pull` and then rerun the platform script.

### macOS

Requirements:

- macOS 14 or later
- Xcode Command Line Tools

Install the Apple command-line tools once:

```bash
xcode-select --install
```

From the repository root, build and open PetRunner:

```bash
./script/build_and_run.sh
```

The script creates `dist/PetRunner.app` locally and opens it. Re-running the
script closes the previous PetRunner process, rebuilds changed files, and opens
the new local build.

To use a different pet directory:

```bash
dist/PetRunner.app/Contents/MacOS/PetRunner --pets-dir /absolute/path/to/pets
```

If `swift` or `xcrun` is missing after installing the tools, run
`xcode-select -p` to confirm that an active developer directory exists.

### Windows

Requirements:

- 64-bit Windows 10 or Windows 11
- [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)
- PowerShell 5.1 or later

Confirm the SDK is available:

```powershell
dotnet --info
```

From the repository root, build and run PetRunner:

```powershell
.\script\build_and_run.ps1
```

Keep the PowerShell window open while PetRunner is running. Quit PetRunner from
its tray menu or press `Ctrl+C` in the PowerShell window.

To use a different pet directory:

```powershell
.\script\build_and_run.ps1 -PetsDir "C:\path\to\pets"
```

If the current PowerShell execution policy blocks local scripts, run this
one-time command from the repository root. It bypasses the policy only for this
process and does not change the machine-wide setting:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\script\build_and_run.ps1
```

## Verify the checkout

macOS:

```bash
./script/test_macos.sh
PETRUNNER_RUN_INSTALLED_PET_TESTS=1 ./script/test_macos.sh --filter InstalledPetsIntegrationTests
```

Windows:

```powershell
dotnet run --project windows\PetRunner.Tests\PetRunner.Tests.csproj
```

## Common issues

- **No pet appears:** confirm the pet directory exists and contains one folder
  per pet with `pet.json` and its spritesheet, then select **Reload Pets**.
- **A v2 pet is rejected:** its manifest must contain `spriteVersionNumber: 2`
  and its atlas must be exactly 1536 × 2288 pixels.
- **macOS build tools are missing:** run `xcode-select --install`.
- **Windows reports an incompatible target framework:** install the .NET 10
  SDK, not only the .NET runtime.
- **The app is already open:** rerun the platform script; it stops the previous
  PetRunner process before starting the new build.
- **Monitoring does not show a bubble:** make sure PetRunner is running; hooks
  intentionally fail silently when the app is closed. Check that the provider
  accepted its local hook configuration and, for Codex, that its hook is trusted.
- **Setup refuses a provider config:** repair the provider's JSON configuration
  (or restore its adjacent `.petrunner-backup`) and run setup again; PetRunner
  will not overwrite malformed config.
