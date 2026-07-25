---
name: PetRunner
last_updated: 2026-07-26
---

# PetRunner Strategy

## Target problem

A developer's desktop can feel sterile while they work with coding agents; they want a playful pet to keep them company. For developers on one screen, repeatedly returning to the agent tab to learn whether it is working, needs input, or has finished also interrupts their flow.

## Our approach

PetRunner is first a fun desktop pet that reacts to session state and feels alive. Monitoring remains a minimal ambient signal rather than a developer dashboard.

Ambient usage signals (quota bars and local spend) are allowed when they stay
glanceable under the pet and never require leaving the desktop flow. Detailed
cost, history, and budgets belong in the local loopback dashboard, not in the
overlay.

The product stays local-first: no cloud sync backend by default. Opt-in
outbound network is limited to provider plan-quota and pricing-catalog refresh.

## Who it's for

**Primary:** Developers using Codex, Claude, or Cursor on their personal machines — they hire PetRunner to make their desktop feel more alive and to notice when an agent needs input at a glance.

**Platform note (0.3.x):** Full Agent Monitor, Cursor usage, and remote plan
quota ship on macOS first. Windows ships the parity core (pet + local Claude/Codex
spend dashboard + budget quota bar). See `AGENTS.md` for the capability matrix.

## Key metrics

- **Usage** — Not defined before launch; define a repeat-use behavior once the project is public.
- **Downloads** — Track installation demand through npm.
- **Feedback** — Track issues, discussions, and contributions through GitHub.

## Tracks

### Core pet experience

Make the pet playful, smooth, and physically interactive.

_Why it serves the approach:_ The pet itself is the primary reason people want to keep PetRunner running.

### Agent-session monitoring

Provide minimal ambient status for Codex, Claude, and Cursor sessions (macOS
in 0.3.x). When Windows gains monitor support, share the normalized event
protocol and session-history schema first.

_Why it serves the approach:_ Useful status should enrich the pet without overtaking the pet experience.

### Local usage and quota

Show glanceable remaining-usage under the pet and deeper spend/budget detail in
the local dashboard. Prefer budgets everywhere; remote plan windows are
macOS-advanced until ported.

_Why it serves the approach:_ Ambient metering reduces tab-checking without turning the pet into an analytics suite.

### Open-source distribution and community

Make PetRunner easy to install and grow feedback and contributions through GitHub and npm.

_Why it serves the approach:_ Open source reaches the developers who already use coding agents.
