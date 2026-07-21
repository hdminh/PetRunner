# PetRunner

Standalone macOS menu-bar and Windows tray renderer for Codex-compatible custom
pets. It reads `${CODEX_HOME:-~/.codex}/pets` without starting or connecting to
Codex.

## Start

PetRunner is independent from pet installers. Install pets with Petdex (or copy
any compatible pet into the directory above), then run:

```bash
npx pet-runner start
```

On first use, the CLI checks the platform toolchain and builds PetRunner locally.
Later runs open the installed build immediately. No repository clone or shell
script is required.

Requirements:

- macOS 14 or later with Xcode Command Line Tools
- Windows 10/11 x64

For a downloaded Windows installer rather than the npm/source workflow, run
`PetRunner-<version>-windows-x64-setup.exe`. It installs a Start-menu entry
and uninstaller and does not require .NET or the Visual C++ runtime.

The Windows npm workflow is for developers: it builds the native app locally
and requires Visual Studio C++ Build Tools, CMake, Ninja, and vcpkg.

Windows releases also include an x64 Microsoft Store `.msix` package. It is a
full-trust desktop package, and the Store signs it during submission.

Other commands:

```bash
npx pet-runner install
npx pet-runner update
npx pet-runner uninstall
```

## Publishing packages

GitHub Releases run `.github/workflows/publish-packages.yml`, which publishes
to npm and GitHub Packages. Before the first automated npm release, configure
`@hdminh/pet-runner` on npmjs.com with trusted publisher `hdminh/PetRunner` and
workflow filename `publish-packages.yml`. To backfill GitHub Packages without
republishing npm, manually run the workflow with only **Publish to GitHub
Packages** enabled.

## Optional agent monitor (macOS)

Choose **Agent Monitor → Enable Agent Monitor** in the menu bar to explicitly select any
detected Claude Code, Codex, or Cursor providers. It starts off by default and
shows the provider, a two-line current activity, and a small fixed state:
`Working…`, `Reviewing…`, `Needs approval`, `Finished`, or `Failed`. Activity is
derived locally and deterministically from lifecycle hooks, such as `Reading
server.ts`, `Ran swift`, or `Fetching docs.example.com`; PetRunner never sends
it to an LLM.

The attached rail shows up to five active sessions in stable order. Use the
large up/down buttons to browse and the highlighted color cell as an overview;
the compact rail has a `+` button to reopen the card. For the contextual view,
PetRunner may show a file basename, search pattern, URL hostname, subagent
description, or the first token of a command. It never retains or displays a
prompt, tool output, full command, raw tool payload, session ID, or transcript.

To restore active work after PetRunner relaunches, the helper keeps at most five
derived snapshots in a user-only runtime journal for up to 15 minutes. Terminal
events and disabling monitoring remove those snapshots. This adds only local
hook, file, and IPC overhead—no model-token usage.

Disable monitoring before deleting a manually installed app in Finder. The npm
uninstall command runs monitor-hook cleanup automatically.

To override the pet library:

```bash
npx pet-runner start --pets-dir /absolute/path/to/pets
```

See [the complete setup guide](docs/RUN_LOCAL.md) for prerequisites, the manual
source-build fallback, and troubleshooting.

Use the menu-bar or tray paw icon to choose or reload pets, change size, or quit.
Drag the pet to move it,
throw it toward a screen edge, hover or click it to jump, or drag its
lower-right handle to resize. Idle uses the six standard frames at a calm,
three-times-slower cadence, pausing for one second between each pass. Hover runs the three Codex
jump cycles before returning to idle. V2 look-direction cells are reserved for
a Computer Use cursor; this runner also uses recent physical pointer movement
as a fallback, then resumes idle after the pointer settles.

## Tests

macOS:

```bash
swift test
PETRUNNER_RUN_INSTALLED_PET_TESTS=1 swift test --filter InstalledPetsIntegrationTests
```

Windows native:

```powershell
cmake -S windows\native -B .build\windows-native -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=%VCPKG_ROOT%\scripts\buildsystems\vcpkg.cmake -DVCPKG_TARGET_TRIPLET=x64-windows-static
ctest --test-dir .build\windows-native --output-on-failure
```

## License

PetRunner is available under the [MIT License](LICENSE).
