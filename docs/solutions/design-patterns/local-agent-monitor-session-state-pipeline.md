---
title: Build local agent monitors as a bounded normalized state pipeline
date: 2026-07-15
category: design-patterns
module: agent-monitor
problem_type: design_pattern
component: tooling
severity: medium
applies_when:
  - "A local desktop app consumes events from more than one coding-agent provider."
  - "The UI needs at-a-glance current state for concurrent sessions without retaining an event log."
  - "Hook payloads cross a local process boundary and must tolerate TCP chunking."
tags: [agent-monitoring, local-ipc, session-state, appkit]
---

# Build local agent monitors as a bounded normalized state pipeline

## Context

PetRunner's optional monitor bridges local provider hooks to the floating pet.
The useful UI unit is one current status for each `(provider, sessionID)` pair,
not an event timeline. That makes the bubble useful away from the coding tab:
it identifies the provider, its latest broad state, and whether attention is
needed without exposing task content.

The state vocabulary is intentionally small: `working`, `reviewing`,
`needsApproval`, `finished`, and `failed`. Each has fixed copy and maps to a
pet animation ([AgentMonitor.swift](../../../Sources/PetRunnerCore/AgentMonitor.swift#L13)).

## Guidance

1. Treat provider hooks as adapters, never as the UI contract. Keep the
   provider-specific event spellings and configuration shapes at the edge;
   install only entries marked as owned by PetRunner and leave third-party
   hooks intact ([ProviderHookConfiguration.swift](../../../Sources/PetRunnerCore/ProviderHookConfiguration.swift#L18), [ProviderHookConfigurationTests.swift](../../../Tests/PetRunnerCoreTests/ProviderHookConfigurationTests.swift#L23)).

2. Normalize before crossing processes. `NormalizedAgentEvent` contains only
   a provider, session ID, and fixed status. The normalizer uses the
   provider-supplied session identifier and the event/tool signal needed to derive that status;
   it does not forward prompts, commands, file paths, or transcript content
   ([AgentMonitor.swift](../../../Sources/PetRunnerCore/AgentMonitor.swift#L51), [ProviderHookConfiguration.swift](../../../Sources/PetRunnerCore/ProviderHookConfiguration.swift#L77)).

3. Make the local delivery boundary explicit. The running app writes an
   ephemeral loopback port plus a per-run token to a private descriptor. The
   helper sends a length-prefixed envelope to `127.0.0.1`; the listener bounds
   accepted frames, accumulates bytes until a complete frame is available,
   validates its token, then dispatches it on the main queue ([AgentMonitorBridge.swift](../../../Sources/PetRunner/AgentMonitorBridge.swift#L42), [AgentMonitorBridgeContract.swift](../../../Sources/PetRunnerCore/AgentMonitorBridgeContract.swift#L11)).
   Framing is a robustness boundary for partial TCP reads, not a claim that it
   alone explains every historical delivery symptom.

4. Store a bounded MRU view of current sessions. Replacing an existing key,
   inserting it at index zero, and capping the list at five gives new activity
   both state-update and recency semantics. Do not append a new record for a
   status transition ([AgentMonitor.swift](../../../Sources/PetRunnerCore/AgentMonitor.swift#L82)).

   ```swift
   entries.removeAll { $0.key == event.key }
   entries.insert(snapshot, at: 0)
   if entries.count > Self.maximumEntries {
       entries.removeLast(entries.count - Self.maximumEntries)
   }
   selectedIndex = 0
   ```

5. Keep stored order separate from the user's viewing selection. Paging moves
   a clamped index without reordering entries. On removal, preserve the selected
   session by key when possible so terminal cleanup does not make the user lose
   the bubble they were reading ([AgentMonitor.swift](../../../Sources/PetRunnerCore/AgentMonitor.swift#L105), [AgentMonitorTests.swift](../../../Tests/PetRunnerCoreTests/AgentMonitorTests.swift#L81)).

6. Make multiplicity visible before the user clicks. The expanded bubble draws
   offset cards, an external pixel rail with selected-position markers, and a
   floating provider header. The card shows a deterministic anonymous session
   label plus fixed status. The compact header preserves the provider/count and
   one colored, accessible status light per retained session. The controller
   keeps real AppKit hit targets aligned with the drawn controls
   ([StackedBubbleBackgroundView.swift](../../../Sources/PetRunner/StackedBubbleBackgroundView.swift#L13), [SessionBubblePanelController.swift](../../../Sources/PetRunner/SessionBubblePanelController.swift#L38)).

7. Give terminal states a short lifecycle. PetRunner schedules `finished` and
   `failed` entries for removal after five seconds, cancels that removal if a
   later event arrives for the same session, and hides the bubble plus clears
   the monitor animation once no entry remains ([AppDelegate.swift](../../../Sources/PetRunner/AppDelegate.swift#L169)).

## Why This Matters

Raw event history becomes noisy and stale quickly. A bounded current-state
store means that an event updates one visible session and also expresses recent
activity, while paging still makes the other active sessions discoverable.

The bridge is local and deterministic: it reads hook JSON, normalizes it, and
sends a small authenticated envelope. It makes no model request, so the bridge
itself adds no LLM token usage. Constraining the envelope also keeps provider
payload content out of the overlay. Its contract rejects invalid versions,
tokens, blank session IDs, and oversized envelopes ([AgentMonitorBridgeContract.swift](../../../Sources/PetRunnerCore/AgentMonitorBridgeContract.swift#L29), [AgentMonitorBridgeContractTests.swift](../../../Tests/PetRunnerCoreTests/AgentMonitorBridgeContractTests.swift#L15)).

## When to Apply

Use this pattern when an optional desktop companion needs lightweight status
from one or more local developer tools, especially when the user may be in
another application. It fits when:

- provider configuration is selected explicitly by the user;
- incoming payloads can contain sensitive or high-volume data that the UI does
  not need;
- several sessions can be active but there is space for only one readable
  bubble; or
- a terminal result should remain visible briefly, then disappear without
  hiding still-active sessions.

This is not an audit trail. Persisted event history, task text, tool arguments,
or system notifications need separate product, privacy, and retention choices.

## Examples

A read-only Cursor tool event normalizes to `reviewing`; updating that same
session replaces its current snapshot rather than creating history:

```swift
let event = ProviderHookConfiguration(provider: .cursor).normalize(
    payload: ["conversation_id": "s-42", "tool_name": "Read"],
    eventName: "preToolUse"
)
// NormalizedAgentEvent(provider: .cursor, sessionID: "s-42", status: .reviewing)
```

The behavior is covered by the focused normalization test
([ProviderHookConfigurationTests.swift](../../../Tests/PetRunnerCoreTests/ProviderHookConfigurationTests.swift#L68)).

With three stored sessions, the foremost bubble shows `1/3` and renders three
offset cards. Selecting the next session changes the displayed provider and
status without mutating the MRU order. Core tests cover replacement without
history, five-entry capping, paging, and preservation of selection during
removal ([AgentMonitorTests.swift](../../../Tests/PetRunnerCoreTests/AgentMonitorTests.swift#L17)).

## Related

- [Agent Session Monitor plan](../../plans/2026-07-14-001-feat-agent-session-monitor-plan.md) records the original product and implementation decisions.
- [Run locally guide](../../RUN_LOCAL.md) contains user-facing setup and troubleshooting material.
