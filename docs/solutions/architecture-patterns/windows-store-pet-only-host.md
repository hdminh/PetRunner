---
title: Windows Store pet-only host with capability and WebView2 gates
date: 2026-07-26
category: architecture-patterns
module: windows-pet-host
problem_type: architecture_pattern
component: tooling
severity: high
applies_when:
  - "Shipping a Windows Store or MSIX build that must expose pets without usage, sessions, or Agent Monitor"
  - "Hosting DashboardWeb inside WebView2 for a pets-only surface while packaging Vite dist assets"
  - "Installing default pets whose package ids become filesystem destinations"
  - "The same DashboardWeb bundle must hide usage or monitor chrome until host capabilities are known"
tags:
  - windows-store
  - pet-only
  - webview2
  - capabilities
  - packaging
  - path-traversal
related_components:
  - documentation
---

# Windows Store pet-only host with capability and WebView2 gates

## Context

Windows Store PetRunner is a pets-only SKU: tray + overlay + a WebView2 window
for the shared Pets library UI. Usage KPIs, sessions analytics, token/cost
views, under-pet quota bars, and Agent Monitor stay out of that host cut (macOS
keeps the full dashboard). The same `DashboardWeb` bundle must honor host
`capabilities` so Overview / Providers / Analytics / Monitor do not flash on
Windows, while macOS can still resume overview after load. Packaging must ship
the Vite-built dashboard (`DashboardWeb/dist`), not raw sources, and default-pet
seeding must never treat `pet.json` ids as unsanitized path segments.

## Guidance

### Host composition
- Keep tray + overlay on pet runtime only. Do not construct usage indexes or
  wire quota-bar refresh on the Store path; clear leftover quota overlay
  segments from older settings if present.
- Serve pets management through WebView2 at the loopback dashboard URL with
  hash `#/pets`. External `http`/`https` links open in the system browser; do
  not navigate the WebView off loopback.
- Advertise `capabilities.usage`, `sessions`, and `agentMonitor` as false on
  this host; keep pet import / remove / preview / directory browsing enabled.
- Regroup the tray into Pets / Appearance / Behavior / Library (Open Pets…,
  Reload Pets, Download more pets… → pet-runner.com).
- Seed with `InstallAllMissing` over every valid package under `DefaultPets/`;
  ship only the bundled default pet today. Prefer that id when nothing else is
  selected.

### Packaging
- Windows run/publish scripts must run `npm run dashboard:build` and copy
  `DashboardWeb/dist` into the app output.
- Allow Vite hashed `assets/<file>` (single path segment) and pet spritesheet
  API routes on the Windows dashboard router.

### Hard gates (review fixes)
1. **Safe pet id** — Before joining an id into the pets directory, reject empty,
   `.`, `..`, `/`, `\`, and rooted/absolute values; resolve the destination and
   assert it stays under the pets root. Cover escape and rooted ids in tests on
   both platforms.
2. **`capabilitiesReady`** — Until overview/state succeeds, hide usage/monitor
   nav and render Pets content only. Do not rewrite the hash solely because
   capabilities are unknown, so macOS can still resume overview after load.
3. **WebView allow-list** — Allow only loopback `http`/`https` matching the
   dashboard origin, plus benign `about:blank`. Cancel `data:` / `blob:` and
   other schemes; do not open them externally either.
4. **Mutation origin** — Accept `Origin` matching the dashboard origin, or
   absent Origin with `Sec-Fetch-Site: same-origin`. Do not treat Referer alone
   as sufficient.

## Why This Matters

A Store listing that implies spend tracking or quota meters without shipping them
misleads users. Unvalidated package ids can escape the pets library during
default install. Flashing usage/monitor chrome before capabilities load confuses
pets-only users and can race-navigate macOS away from a restored overview hash.
A lax WebView or Referer-only CSRF check weakens the loopback pets surface.

## When to Apply

- Changing Windows Store product scope, tray IA, or dashboard capability flags
- Any path that joins a pet id into the pets directory (seed, import, remove)
- Shared DashboardWeb hosts that may advertise usage/monitor false (Windows) or
  true (macOS)
- WebView2 embedding of the loopback dashboard
- Windows package / MSIX / local-run scripts that must include the Vite dashboard

## Examples

### Safe pet id

**Before:** join `pet.Id` into the pets directory with no validation → ids like
`../escape` or a rooted path write outside the library.

**After:** validate the id, then resolve and contain the destination under the
pets root before copy. Tests must prove escape and rooted ids never create
outside folders; trimmed safe ids still install.

### Capability-ready chrome

**Before:** missing `capabilities.usage` is treated as enabled → Overview /
Providers / Analytics / Monitor flash on first paint (or the hash is forced to
`#/pets` too early and breaks macOS resume).

**After:** gate nav and content on a ready flag set only after a successful
state normalize. Until then show Pets-only chrome without rewriting the hash.
After ready, pets-only hosts stay on Pets; full hosts resume the stored view.

## Related

- [Quiet Claude credential reuse with provider quota HP bar](../design-patterns/quiet-provider-credentials-and-quota-hp-bar.md) — shared quota-bar resolver still lives in Core for a future Windows re-enable; Store host leaves it unwired
- [docs/RUN_LOCAL.md](../../RUN_LOCAL.md) — WebView2 Runtime, `dashboard:build`, MSIX packaging
- Store listing copy under `StoreAssets/`
