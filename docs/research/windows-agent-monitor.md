# Windows Agent Monitor feasibility

## Recommendation

**No-go for shipping in the Rust cutover; revisit as an opt-in preview after a
Windows host proof of concept.** The Rust monitor core and its provider payload
normalization can be reused, but Windows needs a dedicated launcher and IPC
adapter before it is safe to write any provider configuration.

## Provider evidence

| Provider | Finding | Recommendation |
| --- | --- | --- |
| Claude Code | Native Windows is supported with Git for Windows; WSL is also supported. [Anthropic setup](https://docs.anthropic.com/en/docs/claude-code/getting-started) | Investigate the Windows user settings path and command quoting with an owned test profile. Do not assume the macOS hook command works unchanged. |
| Codex | The macOS configuration shape is portable Rust logic, but no Windows hook-path/lifecycle evidence was found in the current public documentation review. | Block shipping until an official Windows hook contract and paths are verified. |
| Cursor | User hooks use `~/.cursor/hooks.json`, but Windows reports show shell and launcher inconsistencies. [Cursor hook discussion](https://forum.cursor.com/t/hooks-in-windows/150377), [Windows failure reports](https://forum.cursor.com/t/hooks-not-working-on-windows/149509) | Most feasible POC candidate, but require an explicit PowerShell or `.cmd` launcher, neutral JSON output, and a duplicate-event guard. |

## Required Windows adapter

- Keep `petrunner-core` responsible for event normalization, session state,
  ownership filtering, and JSON transformations.
- Add a Windows-only WPF/Win32 adapter for a loopback named pipe or TCP
  descriptor with a per-run token. Do not expose a fixed public port.
- Generate provider commands with an absolute quoted `.exe` path and a
  PowerShell/`.cmd` wrapper where the provider does not execute `.exe` directly.
- Write only user-scoped regular files; reject symlinks/reparse points, preserve
  ACLs, preflight all providers before a write, and rollback the owned changes
  on failure or uninstall.
- Keep prompt-derived labels bounded and ephemeral. Never persist provider
  payloads, prompts, command arguments, or Cursor conversation content.

## POC acceptance gate

1. Test each provider under native Windows and WSL separately with a disposable
   home directory.
2. Verify the hook runner emits the expected neutral response (Cursor) and
   always exits zero without opening a terminal.
3. Exercise install, repeat install, concurrent config edit, provider removal,
   and uninstall cleanup; confirm third-party entries and ACLs survive.
4. Validate named-pipe/TCP token rejection, partial frames, process restart,
   and duplicate events.
5. Run manual WPF visual QA only after the provider POC is reliable.
