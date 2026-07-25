---
title: Quiet Claude credential reuse with provider quota HP bar
date: 2026-07-25
category: design-patterns
module: agent-monitor
problem_type: design_pattern
component: authentication
severity: high
applies_when:
  - "A macOS overlay polls provider plan quota on a timer or at launch"
  - "Claude Code OAuth lives in a foreign Keychain item and ad-hoc re-signing resets ACL trust"
  - "Under-pet HP bars must choose among plan quota windows and local spend budgets"
  - "Background paths must stay silent while explicit Refresh may prompt once and cache"
  - "Menu actions mirror overlay controls and must share the same handler"
tags:
  - claude-oauth
  - keychain
  - provider-quota
  - quota-hp-bar
  - agent-monitor
  - application-support-cache
related_components:
  - tooling
---

# Quiet Claude credential reuse with provider quota HP bar

## Context

PetRunner's Monitor overlay shows live provider plan quota as pixel HP bars under
the pet (and in the dashboard). Claude OAuth for those meters lives in Claude
Code's Keychain item (`Claude Code-credentials`). Ad-hoc launches via
`build_and_run.sh` re-sign the binary; touching that foreign ACL item — even with
"no UI" Keychain flags — still surfaced Allow/Deny sheets on every launch and
timer refresh. (session history)

The durable pattern is not "better Keychain silence" alone. It layers
call-intent gating for secrets, identity-churn–safe file reuse, pure shared
quota resolution in core, and one real handler for every UI surface that claims
to do the same thing.

## Guidance

### 1. Separate silent paths from user-initiated auth

Background work (launch, ~60s timer, dashboard presence polls) must never query
Claude's Keychain. Only explicit Refresh Usage may prompt once, then cache.

```swift
// Launch / timer: silent
refreshUsage(allowClaudeKeychainPrompt: false)

// Quick actions / dashboard Refresh Usage: may prompt once
quickActions.onRefreshUsage = { [weak self] in
    self?.refreshUsage(allowClaudeKeychainPrompt: true)
}
```

Intent flag names differ by layer but mean the same gate:
`allowClaudeKeychainPrompt` (AppDelegate) → `allowKeychainPrompt`
(`ProviderQuotaClient`) → `allowPrompt` (`ClaudeCredentialsStore`).

In [`ClaudeCredentialsStore.swift`](../../../Sources/PetRunner/ClaudeCredentialsStore.swift):
prefer `~/.claude/.credentials.json`, then memory + Application Support
(`claude-oauth-cache.json`, mode `0600`). Silent callers stop before any Claude
Keychain probe — even `KeychainNoUIQuery` can sheet on ad-hoc builds.
(session history) Explicit Refresh may prompt once, then `persistCache`.
`credentialsPresent()` never touches Keychain (dashboard polls it).

Do not cache into `vn.hodinhminh.petrunner.claude-credentials`: bare
`SecItemCopyMatching` / `SecItemDelete` on that ACL-bound item re-prompts after
ad-hoc re-sign. (session history)

[`ProviderQuotaClient`](../../../Sources/PetRunner/ProviderQuotaClient.swift)
passes the gate into `fetchClaude`. On 401/403, invalidate the file cache and
re-prompt only if the caller allowed prompts.

### 2. Fetch quota beside usage; resolve bars in shared core

`refreshUsage` loads spend and plan quota together, then `refreshQuotaBar()` maps
prefs + snapshots through `QuotaBarResolver` and pushes segments to the overlay.
Segment math lives in
[`QuotaBarResolver`](../../../Sources/PetRunnerCore/QuotaBarResolver.swift)
(+ Windows twin); snapshots/parsers in
[`ProviderQuota.swift`](../../../Sources/PetRunnerCore/ProviderQuota.swift);
drawing only in
[`PetQuotaBarView`](../../../Sources/PetRunner/PetQuotaBarView.swift) /
Windows `OverlayWindow`. Prefs: `quotaBarVisible`, `quotaBarMode` (default
`.auto`).

Auto order: daily budget → monthly budget → plan windows → seed defaults and
persist. Keep macOS/Windows resolver behavior aligned (Windows plan fetch may
lag; budget path should still match).

### 3. Wire every duplicate control to one real handler

Menu items that look like "reset" must call the same teardown as the bubble
close affordance — not a presentation refresh. (session history)

```swift
menu.onRefreshMonitorBubble = { [weak self] in self?.resetMonitorSessions() }
quickActions.onRefreshMonitorBubble = { [weak self] in self?.resetMonitorSessions() }
sessionBubble.onReset = { [weak self] in self?.resetMonitorSessions() }
```

`resetMonitorSessions()` clears live sessions, drops recovery journal state,
hides the bubble, and restores pet animation. Prefer adding the `onX` property
and wiring it in `AppDelegate` in the same change that introduces the menu title.

## Why This Matters

Ad-hoc desktop apps that read another app's Keychain credentials will re-prompt
whenever codesign identity churns. File/cache reuse plus intent gating fixes UX
without fighting Security.framework.

Quota UI stays consistent across menu, overlay, and dashboard when segment math
lives in PetRunnerCore, not in AppKit/WPF.

Duplicate menu labels without shared handlers recreate "looks fixed, does
nothing" bugs — Reset Monitor Bubble originally called
`refreshMonitorPresentation()` and appeared broken. (session history)

## When to Apply

- Polling or auto-refresh needs third-party OAuth/Keychain material.
- Overlay/dashboard must show provider limits from both local spend budgets and
  remote plan windows.
- macOS and Windows must stay behavior-aligned for resolver modes.
- Any new Monitor/menu control that mirrors an in-overlay button.

## Examples

### Quiet Claude auth (ask once, reuse)

| Path | `allowPrompt` | Behavior |
|------|---------------|----------|
| App launch / timer | `false` | File / `~/.claude` / cache only; no Keychain |
| Refresh Usage | `true` | May prompt once; persist Application Support cache |
| `credentialsPresent()` | n/a | File/cache only — never Keychain |

### Pixel HP bar pipeline

```
ProviderQuotaClient.fetchAll
  → quotaSnapshots[UsageProvider]
QuotaBarResolver.resolve (mode: auto|daily|monthly|plan|off)
  → [QuotaBarSegment]
PetQuotaBarView / OverlayWindow draws remainingPercent
```

Without a quiet cached Claude token, Claude quota stays empty until the user
runs Refresh Usage once. (session history)

### Reset Monitor Bubble alias

Treat status-menu and quick-actions callbacks as aliases of
`sessionBubble.onReset` → `resetMonitorSessions()`, not
`refreshMonitorPresentation()`.

## Related

- [Separate live agent session state from durable session history](./local-agent-monitor-live-state-and-session-history.md) — live store, history, and recovery journal (Reset Monitor Bubble clears live presentation).
- [Run locally guide](../../RUN_LOCAL.md) — Agent Monitor setup and troubleshooting.
