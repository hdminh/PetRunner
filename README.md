# PetRunner

Standalone macOS menu-bar renderer for Codex-compatible custom pets. It reads
`${CODEX_HOME:-~/.codex}/pets` without starting or connecting to Codex.

## Build and run

```bash
./script/build_and_run.sh
```

The unsigned local app is staged at `dist/PetRunner.app`. Use the menu-bar paw
icon to choose or reload pets, change size, or quit. Drag the pet to move it,
throw it toward a screen edge, hover or click it to jump, or drag its
lower-right handle to resize. Idle uses the six standard frames at a calm,
three-times-slower cadence, pausing for one second between each pass. Hover runs the three Codex
jump cycles before returning to idle. V2 look-direction cells are reserved for
a Computer Use cursor; this runner also uses recent physical pointer movement
as a fallback, then resumes idle after the pointer settles.

To load another directory during development:

```bash
dist/PetRunner.app/Contents/MacOS/PetRunner --pets-dir /path/to/pets
```

## Tests

```bash
swift test
PETRUNNER_RUN_INSTALLED_PET_TESTS=1 swift test --filter InstalledPetsIntegrationTests
```
