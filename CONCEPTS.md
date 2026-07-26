# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Platform scope

### Parity core
Cross-platform capabilities that must stay aligned on macOS and Windows: pet package load/atlas/animation/physics, pets-dir defaults, user-initiated import/replace/delete, and the local Pets library surface (preview, import, autonomy, folder).

### macOS-advanced
Capabilities that ship on macOS first and are not required for Windows parity in the Store cut: full Usage / Analytics dashboard, budget-based quota bars, Agent Monitor (hooks, IPC, session history), Cursor usage/analytics, and remote plan-quota windows.

### Pets-only Store cut
The Windows Store host composition that ships tray + overlay + WebView2 Pets library without enabling usage, sessions, quota-bar, or Agent Monitor chrome. Host capability flags advertise those surfaces as off while Core usage parsers may still exist for a later embed.

## Pets library

### Default pets seeding
Copying every missing valid package from the app’s bundled default-pets root into the user pets library on launch, never overwriting an existing package, and preferring the built-in default id when nothing else is selected.

### Path-safe pet id
The rule that a package id used as a library folder name must be a single non-empty path segment — not `.`, `..`, separators, or a rooted/absolute path — and the resolved destination must stay inside the pets library root.

### Capability-ready dashboard chrome
The rule that Overview / Providers / Analytics / Monitor navigation stays hidden until host capability flags are known from a successful dashboard state response, so pets-only hosts do not flash disabled surfaces and full hosts can still resume their prior view.

## Agent Monitor

### Agent monitor
The opt-in PetRunner capability that turns local coding-agent activity into a pet expression and companion bubble using a minimized status payload.

### Normalized monitor event
The provider-neutral, privacy-minimized description of coding-agent activity that feeds both the live monitor presentation and session history.

### Monitor session
The current in-memory view of one provider-identified coding-agent session, represented by its latest generic status rather than an event history.

### Monitor status
The fixed, screen-share-safe statement of a monitor session's broad state that determines both its visible bubble text and the pet expression.

### Session history
The local, user-reviewable record of normalized monitor sessions and their meaningful state changes, distinct from the live monitor-session presentation.

### Recovery journal
The short-lived private handoff of derived active monitor snapshots used to restore live presentation after a restart, distinct from session history.

### Quota bar
The under-pet pixel meter that shows remaining usage for the active monitor provider. It is resolved from local spend budgets and remote plan windows, not from raw provider payloads.

### Provider quota snapshot
A normalized, time-bounded view of a provider's plan usage windows used to choose quota-bar segments. Distinct from spend/cost tracking and from live monitor-session status.

### Intent-gated credential access
The rule that background monitor paths may only use already-available credential material, while an explicit user refresh may perform a one-shot interactive read and then cache the result for silent reuse.
