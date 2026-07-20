# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

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
