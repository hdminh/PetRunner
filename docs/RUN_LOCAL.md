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

The hook sends an opaque session ID, provider name, fixed state, optional model,
and a short deterministic activity label to the local app. Labels may contain a
file basename, search pattern, URL hostname, subagent description, or first
command token; they never include a prompt, tool output, full command, raw tool
payload, or transcript. The feature makes no model request, so it uses no
additional model tokens. Each event launches a small local helper process and
makes a short loopback IPC attempt.

Codex may ask you to review and trust the installed hook command. Cursor does
not expose a passive approval event, so it will not display `Needs approval`.
PetRunner keeps a single current state and activity for each active session (up
to five, in stable order); it does not retain an event history. The expanded
bubble shows the provider, current activity, and fixed state text. A private
`0600` runtime journal preserves only those derived snapshots for up to 15
minutes so a relaunch can rediscover active work; terminal events and disabling
the monitor clear the corresponding records. Its attached pixel rail always
shows one colored cell for each current session; choose a cell to switch
sessions. Use the pixel `-` control to
collapse it into a tight vertical list of only those cells; choosing a compact
cell reopens that session. Yellow means working, cyan reviewing, violet needs
approval, green finished, and red failed. The activity is not a prompt or raw
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
- Visual Studio 2022 Build Tools with **Desktop development with C++**
- CMake 3.25+, Ninja, and [vcpkg](https://learn.microsoft.com/vcpkg/get_started/get-started-vs) with `VCPKG_ROOT` set
- PowerShell 5.1 or later

The released x64 installer is native and has no .NET or Visual C++ runtime
prerequisite.

To create the installer from a checkout, also install [Inno Setup 6](https://jrsoftware.org/isinfo.php), then run:

```powershell
.\script\package_windows.ps1
```

This writes per-architecture setup programs to `dist\installer`. They install
PetRunner for the current user, add a Start-menu shortcut and an uninstall entry,
and optionally add a desktop shortcut.

The same command also writes `dist\msix\PetRunner-<version>-windows-x64-store.msix`
for Microsoft Store submission. The MSIX manifest uses the reserved Partner
Center identity for PetRunner; submit that `.msix` on the **Packages** page.

Confirm the native toolchain is available:

```powershell
cmake --version
ninja --version
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
swift test
PETRUNNER_RUN_INSTALLED_PET_TESTS=1 swift test --filter InstalledPetsIntegrationTests
```

Windows:

```powershell
cmake -S windows\native -B .build\windows-native -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=$env:VCPKG_ROOT\scripts\buildsystems\vcpkg.cmake -DVCPKG_TARGET_TRIPLET=x64-windows-static
ctest --test-dir .build\windows-native --output-on-failure
```

## Common issues

- **No pet appears:** confirm the pet directory exists and contains one folder
  per pet with `pet.json` and its spritesheet, then select **Reload Pets**.
- **A v2 pet is rejected:** its manifest must contain `spriteVersionNumber: 2`
  and its atlas must be exactly 1536 × 2288 pixels.
- **macOS build tools are missing:** run `xcode-select --install`.
- **Windows source build cannot configure:** install the C++ Build Tools, CMake,
  Ninja, and set `VCPKG_ROOT` to your vcpkg checkout.
- **The app is already open:** rerun the platform script; it stops the previous
  PetRunner process before starting the new build.
- **Monitoring does not show a bubble:** make sure PetRunner is running; hooks
  intentionally fail silently when the app is closed. Check that the provider
  accepted its local hook configuration and, for Codex, that its hook is trusted.
- **Setup refuses a provider config:** repair the provider's JSON configuration
  (or restore its adjacent `.petrunner-backup`) and run setup again; PetRunner
  will not overwrite malformed config.
