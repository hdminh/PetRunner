# PetRunner contributor guide

PetRunner is a local desktop pet runner and usage dashboard for
Codex-compatible custom pets. It does not start, embed, or connect to Codex as
a host. By default it reads `${CODEX_HOME:-~/.codex}/pets`; both apps also
accept `--pets-dir <path>`.

The product is local-first: the pet overlay, local loopback dashboard, and
(macOS) Agent Monitor talk to on-machine state. Opt-in outbound network is
limited to provider plan-quota and pricing-catalog refresh.

## Repository layout

- `Sources/PetRunnerCore/`: shared macOS domain logic — pet parsing, animation,
  atlas, physics, usage parsing, and (macOS-advanced) monitor contracts.
- `Sources/PetRunner/`: macOS 14+ AppKit menu-bar app, overlay window, local
  dashboard HTTP server, and provider credential/HTTP clients.
- `DashboardWeb/`: Vite/React UI served by the local loopback dashboard API.
- `Tests/PetRunnerCoreTests/`: Swift Testing coverage for the macOS core.
- `windows/PetRunner.Core/`: Windows counterpart of the pet/usage core.
- `windows/PetRunner.Windows/`: Windows 10/11 WPF tray, overlay, WebView2 Pets
  window, and loopback dashboard host (Store cut is pets-only).
- `windows/PetRunner.Tests/`: self-hosted .NET test executable.
- `bin/` and `lib/`: Node 18+ npm CLI that installs/builds PetRunner locally.
- `Support/Package.runtime.swift`: dependency-free SwiftPM manifest used only
  by the npm-installed runtime source. Keep it aligned with production targets
  in `Package.swift`, but do not add test-only dependencies to it.
- `Assets/`: committed application icons and `DefaultPets/` packages. Regenerate
  icons deliberately with `script/generate_app_icons.sh`; do not hand-edit
  generated icon formats.
- `docs/solutions/` — documented solutions to past problems (bugs, best
  practices, workflow patterns), organized by category with YAML frontmatter
  (`module`, `tags`, `problem_type`). Relevant when implementing or debugging
  in documented areas.
- `CONCEPTS.md` — shared domain vocabulary (entities, named processes, status
  concepts). Relevant when orienting to the codebase or discussing domain
  concepts.
- `STRATEGY.md` — product problem, approach, and tracks of work.

## Platform capability matrix

Keep macOS and Windows aligned for **parity core**. Treat everything else as
**macOS-advanced** until it is explicitly ported. The Windows Store / host cut
ships a **pets-only** surface (WebView2 Pets window); usage and quota UI stay
unwired there while Core parsers remain for a later embed.

| Capability | macOS | Windows | Contract |
|---|---|---|---|
| Pet package load, atlas, animation, physics | Yes | Yes | Parity core |
| `--pets-dir` / `CODEX_HOME` default library | Yes | Yes | Parity core |
| User-initiated pet import / replace / delete | Yes | Yes | Parity core |
| Local loopback Pets library UI (preview / settings) | Yes | Yes (WebView2) | Parity core |
| Usage / sessions / spend KPIs in dashboard | Yes | No (Store cut; Core retained) | macOS-first until re-enabled |
| Budget-based quota bar | Yes | No (Store cut; Core retained) | macOS-first until re-enabled |
| Agent Monitor (hooks, IPC, session history) | Yes | No | macOS-advanced (0.3.x) |
| Cursor usage / analytics | Yes | No | macOS-advanced (0.3.x) |
| Remote plan-quota windows | Yes | No | macOS-advanced (0.3.x) |
| Pricing-catalog refresh (`models.dev` / LiteLLM) | Yes | Partial / none | Prefer host-layer HTTP; do not silently expand Core networking |

**Windows pets-only host:** tray + overlay + WebView2 `#/pets`. Advertise
`capabilities.usage` / `sessions` / `agentMonitor` false. Seed `DefaultPets/*`
with path-safe package ids. Package `DashboardWeb/dist` after
`npm run dashboard:build`. See
`docs/solutions/architecture-patterns/windows-store-pet-only-host.md`.

**Monitor port strategy (0.3.x):** Agent Monitor stays macOS-only. Do not start a
partial Windows port. When porting later, share the normalized event protocol
and session-history schema first, then host IPC/hooks.

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
  its pet package. Never join a pet id into the pets directory without rejecting
  empty, `.`, `..`, separators, and rooted/absolute values, then containing the
  resolved destination under the pets root.
- Keep macOS and Windows behavior aligned for **parity core** (parsing,
  sprite-atlas addressing, animation timing, physics, pointer tracking, CLI
  pets-dir arguments, import/remove validation). Add/adjust tests on both
  platforms when changing those contracts.
- V2 atlas dimensions and look-direction mapping are compatibility contracts;
  add/adjust tests in both platforms when changing them.
- Do not silently mutate a user's pet library. User-confirmed import, replace,
  and delete through the dashboard or explicit app actions are allowed; scan
  and reload remain the default for background paths.
- Preserve the default pet location and `CODEX_HOME` override on both platforms.
- Outbound network is opt-in and scoped: plan-quota refresh and pricing-catalog
  updates only, behind explicit user intent or documented refresh paths. Prefer
  keeping live HTTP and OS credential access in the app/host layer; keep Core
  focused on parsers, resolvers, and contracts.
- Dashboard and Usage are split by resource: Core usage modules
  (`UsageModels`, `UsageAggregators`, `UsageBudgets`, `BundledPricing`,
  `UsageStore`, `LocalUsageSource`) and host handlers
  (`DashboardPetsHandler`, `DashboardUsageHandler`, `DashboardMonitorHandler`,
  `DashboardSettingsHandler`) behind `DashboardAPIDependencies`. Prefer
  extending those files over growing a single god object again.
- Windows Store packaging scripts must build and ship `DashboardWeb/dist` (not
  Vite sources). WebView2 Pets navigations stay on loopback http(s); mutation
  requests require Origin or `Sec-Fetch-Site: same-origin`, not Referer alone.

## npm CLI and release rules

- The npm package bundles source and builds it in per-user application storage;
  it must not use `postinstall` or download unsigned executable releases.
- Maintain the `files` allow-list in `package.json` whenever a runtime source
  file is added. Verify it with `npm pack --dry-run`.
- Vite/React remain install-time dependencies because the CLI runs
  `dashboard:build` during local app install. Do not move them to
  `devDependencies` unless `DashboardWeb/dist` is shipped in the package and
  the CLI can skip the build for end users.
- The published package is `@hdminh/pet-runner`; users invoke it with
  `npx @hdminh/pet-runner start`. The executable bin remains `pet-runner`.
- Package versions are immutable after npm publish. Bump the version before any
  follow-up publish and verify the packed tarball before publishing.
- Do not publish, unpublish, modify npm access, or change dist-tags unless the
  user explicitly asks for that external action.
- Do not introduce a cloud backend (for example Supabase) into this repository
  without an explicit STRATEGY change. Ignore local Supabase CLI cache under
  `supabase/.temp/`.

## Change hygiene

- Add focused tests for behavior changes. Run the relevant platform suite and
  `npm test` when touching the CLI.
- Keep changes scoped; this repository may contain a dirty working tree from
  ongoing work. Do not discard or overwrite unrelated modifications.
- Prefer `apply_patch` for edits. Do not commit generated build artifacts.
