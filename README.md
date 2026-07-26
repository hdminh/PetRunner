# PetRunner

Local desktop pet runner and usage dashboard for Codex-compatible custom pets.
Use the same pets while you work with Claude, Cursor, or Codex—PetRunner never
starts, embeds, or connects to Codex. On **macOS** it also tracks local usage
and spend, shows under-pet Quota Bar meters, and an optional Agent Monitor
bubble. On **Windows** the Store/host cut focuses on the desktop pet and Pets
library window (WebView2); usage and quota UI stay unwired there for now.
Default library: `${CODEX_HOME:-~/.codex}/pets`.

<p align="center">
  <img src="https://raw.githubusercontent.com/hdminh/PetRunner/main/docs/images/hero.png" alt="PetRunner desktop pet with Agent Monitor bubble and Quota Bars" height="420" />
    &nbsp;&nbsp;
  <img src="https://raw.githubusercontent.com/hdminh/PetRunner/main/docs/images/hero-collapsed.png" alt="PetRunner with collapsed heart Quota Bar meter" height="420" />
</p>

Source: [github.com/hdminh/PetRunner](https://github.com/hdminh/PetRunner)

## Install and start

```bash
npx @hdminh/pet-runner start
```

On a TTY, the CLI asks for pets directory, which pet to show, Agent Monitor
(macOS), which providers feed Usage/Analytics, autonomous motion, and menu
bar / tray visibility (menu bar icon on macOS) before building. Claude- or
Cursor-only setups: pick or create a pets directory (or keep the default),
enable the providers you actually use, then open the Dashboard—usage stays
empty until local sessions (or Cursor login on macOS) exist. Use `--yes`
to skip the wizard, `--setup` to run it again, or
`npx @hdminh/pet-runner setup` on its own.

On first use, the CLI checks the platform toolchain and builds PetRunner locally.
Later runs open the installed build immediately—no repository clone required.

```bash
npx @hdminh/pet-runner install
npx @hdminh/pet-runner update
npx @hdminh/pet-runner uninstall
```

Requirements:

- Node.js 20.19+
- macOS 14+ with Xcode Command Line Tools
- Windows 10/11 (x64 or arm64) with the .NET 10 SDK

Override the pet library:

```bash
npx @hdminh/pet-runner start --pets-dir /absolute/path/to/pets
```

See [docs/RUN_LOCAL.md](docs/RUN_LOCAL.md) for prerequisites, the manual
source-build fallback, Agent Monitor details, and troubleshooting.

## Pets

Codex-format pet packages render locally whether you use Claude, Cursor, or
Codex—you do not need Codex installed. Default library:
`${CODEX_HOME:-~/.codex}/pets` (override with `--pets-dir` or the setup wizard).

On first launch PetRunner seeds every missing package under the bundled
`DefaultPets/` library (today that is **maomao**) and prefers that default when
nothing else is selected.

- Download more pets from [pet-runner.com](https://pet-runner.com) (any provider)
- Import a ZIP (or folder) from the **Pets** tab / Windows **Open Pets…** window
- Or, if you already use Codex pets: Petdex / `npx codex-pets add <id>`

Drag the pet to move it, throw it toward a screen edge, hover or click to jump,
or drag the lower-right handle to resize.

**macOS** menu bar: open the Dashboard, enable Agent Monitor, show/hide or set
Quota Bar mode, reload pets, change size, toggle autonomous motion, or quit.

**Windows** tray: Pets / Appearance / Behavior / Library — switch pets, size,
hide/show, autonomy, **Open Pets…** (WebView2 library), reload, or download more
pets from pet-runner.com. Quota Bar and usage dashboard chrome are not part of
the Windows Store cut.

The under-pet **Quota Bar** (macOS) shows remaining daily / monthly / plan usage
(Show / Auto / Daily / Monthly / Plan from the paw menu or the Dashboard
Monitor tab). Plan meters are macOS-only today. Collapse the bars to a heart
meter on macOS.

## Dashboard

On **macOS**, open the Dashboard from the menu bar icon, Applications, or the
pet’s context menu. Claude and Codex usage come from local session files on this
device. Cursor spend and analytics (when enabled) come from Cursor’s usage API
using the local Cursor.app login—Cursor Usage/Analytics is macOS-only today.

On **Windows**, **Open Pets…** opens a WebView2 window on the Pets library
(preview, import, autonomy, folder). Full Usage / Analytics / Monitor dashboard
chrome is not enabled in the Windows Store cut; Core usage parsers remain for a
later embed.

When Agent Monitor is enabled (macOS), the top bar shows today’s spend for the
active Monitor provider.

### Overview

KPIs for today’s tokens and cost, month-to-date spend, provider cards, daily
volume, and an activity heatmap of when you usually work.

![Overview tab](https://raw.githubusercontent.com/hdminh/PetRunner/main/docs/images/overview.png)

### Providers

Per-provider **Usage** and **Pricing** panels, spend charts, model breakdowns,
daily / monthly budgets, and (macOS) plan quota meters.

![Providers usage](https://raw.githubusercontent.com/hdminh/PetRunner/main/docs/images/providers.png)

![Providers plan quota](https://raw.githubusercontent.com/hdminh/PetRunner/main/docs/images/providers-plan.png)

![Providers recent activity](https://raw.githubusercontent.com/hdminh/PetRunner/main/docs/images/providers-records.png)

### Analytics

**Sessions**, **Projects**, and **Models**—filter by Claude, Codex, or Cursor
(Cursor filter is macOS-only).

![Analytics sessions](https://raw.githubusercontent.com/hdminh/PetRunner/main/docs/images/analytics-sessions.png)

![Analytics models](https://raw.githubusercontent.com/hdminh/PetRunner/main/docs/images/analytics-models.png)

### Pets

Installed library, ZIP/folder import, animation preview, size / menu-bar /
folder settings, and optional autonomous motion.

![Pets tab](https://raw.githubusercontent.com/hdminh/PetRunner/main/docs/images/pets.png)

### Monitor

On macOS, enable Agent Monitor for Claude Code, Codex, or Cursor; preview the
desktop bubble; reset live session state. Activity labels are derived locally
from lifecycle hooks—PetRunner never sends them to an LLM. Deeper hook and
bubble behavior is in [docs/RUN_LOCAL.md](docs/RUN_LOCAL.md).

Configure the under-pet Quota Bar here (show/hide and Auto / Daily / Monthly /
Plan)—also available from the menu-bar **Quota Bar** menu on macOS.

![Monitor tab](https://raw.githubusercontent.com/hdminh/PetRunner/main/docs/images/monitor.png)

## Privacy

Claude and Codex spend are calculated from local session files on this device.
Cursor spend is imported from Cursor’s usage API using the local Cursor.app
login cookie when Cursor reports it. Optional plan-quota meters (macOS) make
authenticated requests to Anthropic / ChatGPT / Cursor using credentials already
on the machine: Claude from `~/.claude` (and, only on explicit Refresh Usage,
Claude Code Keychain on macOS—then PetRunner may cache the OAuth blob under
Application Support for silent reuse); Codex/ChatGPT from `~/.codex/auth.json`;
Cursor from the local Cursor.app login token. PetRunner does not send those
credentials to PetRunner servers.

Usage/Analytics extract local spend/token rows and limited session metadata
(truncated title, project path/name, model, timestamps) into on-device
ledgers and indexes. They do not retain full prompts, transcripts, tool
output, or raw session payloads. Computed ledgers and indexes stay local.

Agent Monitor never retains or displays prompts, tool output, full commands,
raw payloads, or transcripts. Derived activity labels (file basename, search
pattern, hostname, first command token, and similar) can appear in the bubble
and are stored only locally in live state, a short recovery journal, and
optional dashboard session history.

## Local development

From a clone of this repository:

```bash
# macOS
./script/build_and_run.sh
swift test

# Windows
.\script\build_and_run.ps1
dotnet run --project windows\PetRunner.Tests\PetRunner.Tests.csproj
```

`./script/build_and_run.sh` stages `dist/PetRunner.app` and opens it.
`.\script\build_and_run.ps1` runs `npm run dashboard:build`, then the WPF host
(WebView2 Runtime required). Full platform notes (including MSIX packaging) are
in [docs/RUN_LOCAL.md](docs/RUN_LOCAL.md). Contributor contracts and the
macOS/Windows capability matrix live in [AGENTS.md](AGENTS.md). Windows Store
host architecture:
[docs/solutions/architecture-patterns/windows-store-pet-only-host.md](docs/solutions/architecture-patterns/windows-store-pet-only-host.md).

## Publishing packages

Use **Actions → Release → Run workflow** to cut a new version:

1. Choose `patch` / `minor` / `major`, `current` (release what’s already in
   `package.json`), or `custom` + exact version
2. Leave `dry_run` off to commit the bump to `main` and create tag `vX.Y.Z`
3. `publish-packages.yml` is intended to run on that GitHub Release and publish
   npm + GitHub Packages (re-dispatch manually if the publish jobs do not start)
4. Keep `attach_macos` / `attach_windows` on (defaults) to attach universal
   `.dmg` and Windows `.exe` assets to the same release

Package versions are immutable after npm publish; always bump before a follow-up
release. Do not publish unless explicitly intended.

## License

PetRunner is available under the [MIT License](LICENSE).
