# PetRunner

Standalone macOS menu-bar renderer for Codex-compatible custom pets. It reads
`${CODEX_HOME:-~/.codex}/pets` without starting or connecting to Codex.

## Build and run

```bash
./script/build_and_run.sh
```

The unsigned local app is staged at `dist/PetRunner.app`. Use the menu-bar paw
icon to choose or reload pets, change size, or quit. Drag the pet to move it,
throw it toward a screen edge, click it to jump, or drag its lower-right handle
to resize. V2 pets look toward the pointer while idle.

To load another directory during development:

```bash
dist/PetRunner.app/Contents/MacOS/PetRunner --pets-dir /path/to/pets
```

## Tests

```bash
swift test
PETRUNNER_RUN_INSTALLED_PET_TESTS=1 swift test --filter InstalledPetsIntegrationTests
```
