# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Platform scope

### Parity core
Cross-platform capabilities that must stay aligned on macOS and Windows: pet package load/atlas/animation/physics, pets-dir defaults, user-initiated import/replace/delete, local loopback dashboard, Claude/Codex spend usage, and budget-based quota bars.

### macOS-advanced
Capabilities that ship on macOS first and are not required for Windows parity in 0.3.x: Agent Monitor (hooks, IPC, session history), Cursor usage/analytics, and remote plan-quota windows.

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
