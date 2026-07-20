---
title: Separate live agent session state from durable session history
date: 2026-07-20
category: design-patterns
module: agent-monitor
problem_type: design_pattern
component: tooling
severity: medium
last_updated: 2026-07-20
applies_when:
  - "A local desktop app consumes events from more than one coding-agent provider."
  - "The UI needs both at-a-glance session state and reviewable local session history."
  - "Hook payloads cross a local process boundary and must tolerate TCP chunking."
tags: [agent-monitoring, local-ipc, session-state, session-history, appkit]
---

# Separate live agent session state from durable session history

## Context

PetRunner's optional monitor bridges local provider hooks to the floating pet.
The monitor has two intentionally separate representations of a normalized
event: live presentation state for the session bubble and durable session
history for the dashboard. Both operate on the same constrained event vocabulary
of `working`, `reviewing`, `needsApproval`, `finished`, and `failed`
([AgentMonitor.swift](../../../Sources/PetRunnerCore/AgentMonitor.swift)).

This separation keeps the overlay focused on the current session while allowing
the dashboard to show an independent local history. Neither representation
stores a provider's raw payload, prompt, tool result, or transcript.

## Guidance

1. Treat provider hooks as adapters, never as the UI contract. Keep
   provider-specific spellings and configuration at the edge; install only
   entries owned by PetRunner and leave third-party hooks intact
   ([ProviderHookConfiguration.swift](../../../Sources/PetRunnerCore/ProviderHookConfiguration.swift), [ProviderHookConfigurationTests.swift](../../../Tests/PetRunnerCoreTests/ProviderHookConfigurationTests.swift)).

2. Normalize before crossing processes. `NormalizedAgentEvent` contains a
   provider, session ID, fixed status, model, and bounded derived activity.
   The normalizer selects only allow-listed contextual fields and does not
   forward prompts, tool output, full commands, raw payloads, or transcript
   content ([AgentMonitor.swift](../../../Sources/PetRunnerCore/AgentMonitor.swift), [ProviderHookConfiguration.swift](../../../Sources/PetRunnerCore/ProviderHookConfiguration.swift)).

3. Make local delivery explicit. The helper sends a length-prefixed,
   token-authenticated envelope through `127.0.0.1` to a TCP listener. The
   listener bounds frames, handles partial TCP reads, validates the token, and
   dispatches the accepted event on the main queue
   ([AgentMonitorBridge.swift](../../../Sources/PetRunner/AgentMonitorBridge.swift), [AgentMonitorBridgeContract.swift](../../../Sources/PetRunnerCore/AgentMonitorBridgeContract.swift)).

4. For every accepted event, record durable history before changing the live
   store. `AppDelegate` calls `AgentSessionHistoryStore.record` before
   `AgentSessionStore.upsert`; a semantically changed archived event refreshes
   the open dashboard ([AppDelegate.swift](../../../Sources/PetRunner/AppDelegate.swift)).

5. Keep `AgentSessionStore` as presentation state. It holds the current,
   ordered snapshot for each session key, replaces an existing
   snapshot in place, suppresses identical updates, and preserves the selected
   key across additions and removals. Its terminal entries expire after the
   configured grace period, and a later event cancels pending expiry
   ([AgentMonitor.swift](../../../Sources/PetRunnerCore/AgentMonitor.swift), [AppDelegate.swift](../../../Sources/PetRunner/AppDelegate.swift)).

6. Put durable history behind a separate store. `AgentSessionHistoryStore`
   opens a private SQLite database, maintains per-session summaries, appends a
   timeline entry only when the merged session is semantically different, and
   prunes sessions whose `updated_at` is older than its 90-day maximum age
   ([AgentSessionHistory.swift](../../../Sources/PetRunnerCore/AgentSessionHistory.swift)).

7. Make history an explicit dashboard concern. `DashboardWindowController`
   queries summaries, fetches the selected session's timeline for its detail
   view, and offers a confirmed clear action that removes the local history
   without disabling monitoring
   ([DashboardWindowController.swift](../../../Sources/PetRunner/DashboardWindowController.swift)).

8. Keep recovery separate from history. `AgentMonitorRecoveryJournal` contains
   only derived, nonterminal snapshots for restart recovery; it expires records
   after 15 minutes and removes a record when that session reaches a terminal
   status ([AgentMonitorRecoveryJournal.swift](../../../Sources/PetRunnerCore/AgentMonitorRecoveryJournal.swift)).

## Why This Matters

The live bubble and durable history answer different questions. The live store
needs responsive navigation, stable selection, and terminal cleanup; it should
not become a retention mechanism. The history store needs queryable summaries
and meaningful state transitions, without forcing historical detail into the
overlay.

History is best-effort rather than a dependency of the live monitor: a failed
history initialization or write leaves the presentation update path available,
while the dashboard can report that history is unavailable.

Recording only normalized, derived fields limits what reaches local storage.
The bridge similarly validates versions, tokens, session identifiers, and frame
sizes before events are accepted
([AgentMonitorBridgeContract.swift](../../../Sources/PetRunnerCore/AgentMonitorBridgeContract.swift), [AgentMonitorBridgeContractTests.swift](../../../Tests/PetRunnerCoreTests/AgentMonitorBridgeContractTests.swift)).

## When to Apply

Use this pattern when a desktop companion needs both live status from local
developer tools and a user-reviewable record of those sessions. It is especially
useful when:

- provider payloads may be sensitive or high volume, but the UI needs only a
  deliberately selected activity summary;
- several sessions can be active while the overlay has room for one readable
  selected session;
- terminal state should disappear from the overlay after a grace period; or
- users need to revisit session summaries and meaningful state changes later.

## Examples

A normalized event is processed through the two representations in order:

```swift
guard monitorStore.accepts(event) else { return }
let archived = recordHistory(event)
let changed = monitorStore.upsert(event)
if archived { dashboard?.refreshHistory() }
if changed { refreshMonitorPresentation() }
```

The history store does not add a timeline row for a repeated equivalent
snapshot; it updates the session summary and timeline only when the merged
session changes semantically
([AgentSessionHistory.swift](../../../Sources/PetRunnerCore/AgentSessionHistory.swift)).

When a user selects a history summary in the dashboard, the controller loads
that summary's timeline rather than deriving historical detail from the live
session bubble ([DashboardWindowController.swift](../../../Sources/PetRunner/DashboardWindowController.swift)).

## Related

- [Agent Session Monitor plan](../../plans/2026-07-14-001-feat-agent-session-monitor-plan.md) records the original monitor decisions.
- [Run locally guide](../../RUN_LOCAL.md) contains user-facing setup and troubleshooting material.
