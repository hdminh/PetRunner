# Experimental Marketplace Plugin Note

## Intent

Add an opt-in Claude Code marketplace plugin for PetRunner. This is a discovery,
setup, and pet-management integration; it does not embed PetRunner into Claude
Code or connect PetRunner to Codex.

## Packaging decision

- Add a standalone `pet-runner` plugin, rather than placing it in the existing
  `common`, `client`, or `experimental` plugin.
- Keep the plugin at a pre-1.0 version and label its README and marketplace
  description as experimental.
- This preserves the desired command namespace:

  ```text
  /plugin install pet-runner@sgvn-marketplace
  /pet-runner:setup
  /pet-runner:install
  ```

  A plugin named `experimental` would instead expose `/experimental:<skill>`.

## Initial skills

| Skill | Scope |
| --- | --- |
| `pet-runner:setup` | Check prerequisites, install/build, and start PetRunner; support a chosen `--pets-dir`. |
| `pet-runner:discover` | Find a pet from an approved catalog and present provider, slug, and source before installation. |
| `pet-runner:install` | Install an explicitly selected pet using Petdex or Pets Codex. |
| `pet-runner:import` | Inspect a local folder or ZIP, validate its pet package, then import only with user confirmation. |
| `pet-runner:doctor` | Read-only diagnostics for Node, PetRunner, the selected pet library, and invalid packages. |
| `pet-runner:reload` | Direct the user to reload pets from the running app's paw menu until a supported CLI/IPC reload exists. |
| `pet-runner:monitor` | Explain how to enable the existing monitor through the PetRunner UI; do not modify provider hooks directly. |
| `pet-runner:hatch-pet` | Prepare a pet brief and hand off to the Codex Hatch Pet workflow; no autonomous image generation in the first release. |

## Deferred skill

`pet-runner:publish` may later submit a pet to Petdex. It requires explicit
confirmation because it signs in and publishes user content externally.

## Safety and compatibility rules

- Discovery and doctor flows are read-only.
- Before every install, show the catalog/provider, exact slug, and command; do
  not install a fuzzy search result automatically.
- Import, installation, and publishing require explicit user confirmation.
- Treat PetRunner's package validator as the final compatibility gate, even if
  an external catalog accepts the package.
- Do not use plugin hooks to start an overlay automatically or modify user
  configuration. Use the app's existing explicit UI for monitor setup.
- The first release does not port Codex's `hatch-pet` image-generation pipeline
  or depend on a Codex CLI bridge.

## Implementation follow-up

When implementation begins, add a focused, read-only PetRunner CLI diagnostic
or validation command so `pet-runner:doctor` and local import use the same
package-validation rules as the app.
