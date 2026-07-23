import { useEffect, useMemo, useState } from "react";
import { DashboardAPI } from "./api";
import { CloudDownloadIcon } from "./icons";
import { animationRowsFor, petPreviewURL, PetSpritePreview } from "./pet-preview";
import type { AppState, PetInfo } from "./types";

export const petWidths = [80, 112, 160, 224] as const;
export const autonomyActions = [
  { id: "walk", label: "Walk" },
  { id: "wave", label: "Wave" },
  { id: "jump", label: "Jump" },
  { id: "cry", label: "Cry" },
] as const;
export const autonomyWaitBounds = { min: 5, max: 30 } as const;

export {
  animationRowsFor,
  petAnimationRows,
  petPreviewURL,
  petSpritesheetURL,
  type PetAnimationRow,
} from "./pet-preview";

function petsDirectoryLabel(source: string | null | undefined) {
  switch (source) {
    case "cli": return "Set by --pets-dir";
    case "preference": return "Custom folder";
    case "codexHome": return "CODEX_HOME/pets";
    case "default": return "~/.codex/pets";
    default: return source ? source : "Resolved pets folder";
  }
}

function clampWait(value: number, fallback: number) {
  if (!Number.isFinite(value)) return fallback;
  return Math.min(autonomyWaitBounds.max, Math.max(autonomyWaitBounds.min, Math.round(value)));
}

export function PetsView({
  state,
  api,
  onReload,
  onError,
}: {
  state: AppState;
  api: DashboardAPI;
  onReload: () => Promise<void>;
  onError: (message: string) => void;
}) {
  const pets = state.pets ?? [];
  const selectedID = state.pet?.selectedID ?? pets[0]?.id ?? null;
  const autonomy = state.pet?.autonomy;
  const [focusID, setFocusID] = useState<string | null>(selectedID);
  const [busy, setBusy] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const [minimumWait, setMinimumWait] = useState(() => clampWait(autonomy?.minimumWait ?? 10, 10));
  const [maximumWait, setMaximumWait] = useState(() => clampWait(autonomy?.maximumWait ?? 20, 20));
  const [actions, setActions] = useState<string[]>(() =>
    autonomy?.actions?.length ? autonomy.actions : autonomyActions.map((action) => action.id),
  );
  const activeID = focusID && pets.some((pet) => pet.id === focusID) ? focusID : selectedID;
  const pet = pets.find((entry) => entry.id === activeID) ?? null;
  const petsDirectory = state.settings?.petsDirectory ?? null;
  const petsDirectoryEditable = state.settings?.petsDirectoryEditable ?? state.capabilities?.petsDirectoryBrowse ?? false;
  const canRemove = state.capabilities?.petRemove !== false;
  const autonomyEnabled = autonomy?.enabled !== false;

  useEffect(() => {
    if (!focusID && selectedID) setFocusID(selectedID);
  }, [focusID, selectedID]);

  useEffect(() => {
    if (focusID && !pets.some((entry) => entry.id === focusID)) {
      setFocusID(selectedID);
    }
  }, [focusID, pets, selectedID]);

  const autonomyKey = [
    autonomy?.enabled !== false ? "1" : "0",
    String(clampWait(autonomy?.minimumWait ?? 10, 10)),
    String(clampWait(autonomy?.maximumWait ?? 20, 20)),
    (autonomy?.actions?.length ? autonomy.actions : autonomyActions.map((action) => action.id)).slice().sort().join(","),
  ].join("|");

  useEffect(() => {
    const parts = autonomyKey.split("|");
    setMinimumWait(Number(parts[1]));
    setMaximumWait(Number(parts[2]));
    const actionsRaw = parts[3] ?? "";
    setActions(actionsRaw ? actionsRaw.split(",") : autonomyActions.map((action) => action.id));
  }, [autonomyKey]);

  const selectPet = async (id: string) => {
    setFocusID(id);
    setBusy("select");
    setMessage(null);
    try {
      await api.put("pet", { id });
      await onReload();
      setMessage(`Active pet set to ${id}.`);
    } catch (error) {
      onError(error instanceof Error ? error.message : "Could not select pet.");
    } finally {
      setBusy(null);
    }
  };

  const setWidth = async (width: number) => {
    setBusy("width");
    setMessage(null);
    try {
      await api.put("pet", { width });
      await onReload();
      setMessage(`Pet width set to ${width}px.`);
    } catch (error) {
      onError(error instanceof Error ? error.message : "Could not update pet width.");
    } finally {
      setBusy(null);
    }
  };

  const importPet = async () => {
    setBusy("import");
    setMessage(null);
    try {
      await api.post("pet/import");
      window.setTimeout(() => void onReload(), 600);
      setMessage("Import dialog opened in PetRunner. Choose a pet package to install.");
    } catch (error) {
      onError(error instanceof Error ? error.message : "Could not import pet.");
    } finally {
      setBusy(null);
    }
  };

  const setStatusItem = async (showStatusItem: boolean) => {
    setBusy("status");
    setMessage(null);
    try {
      await api.put("settings", { showStatusItem });
      await onReload();
    } catch (error) {
      onError(error instanceof Error ? error.message : "Could not update menu bar item.");
    } finally {
      setBusy(null);
    }
  };

  const resetPosition = async () => {
    setBusy("reset");
    setMessage(null);
    try {
      await api.post("pet/reset-position");
      setMessage("Pet moved to the center of the main screen.");
    } catch (error) {
      onError(error instanceof Error ? error.message : "Could not reset pet position.");
    } finally {
      setBusy(null);
    }
  };

  const removePet = async (id: string, name: string) => {
    if (!canRemove) return;
    const confirmed = window.confirm(
      `Remove “${name}” from your pets library?\n\nThis deletes the package folder from:\n${petsDirectory ?? "the pets folder"}`,
    );
    if (!confirmed) return;
    setBusy("remove");
    setMessage(null);
    try {
      const result = await api.delete<{ selectedID?: string | null }>(`pets/${encodeURIComponent(id)}`);
      await onReload();
      const nextID = result.selectedID ?? null;
      setFocusID(nextID);
      setMessage(`Removed ${name}.`);
    } catch (error) {
      onError(error instanceof Error ? error.message : "Could not remove pet.");
    } finally {
      setBusy(null);
    }
  };

  const choosePetsDirectory = async () => {
    if (!petsDirectoryEditable) return;
    setBusy("folder");
    setMessage(null);
    try {
      await api.post("pets/choose-directory");
      window.setTimeout(() => void onReload(), 600);
      setMessage("Folder picker opened in PetRunner.");
    } catch (error) {
      onError(error instanceof Error ? error.message : "Could not change pets folder.");
    } finally {
      setBusy(null);
    }
  };

  const revealPetsDirectory = async () => {
    setBusy("reveal");
    setMessage(null);
    try {
      await api.post("pets/reveal-directory");
      setMessage("Opening pets folder.");
    } catch (error) {
      onError(error instanceof Error ? error.message : "Could not open pets folder.");
    } finally {
      setBusy(null);
    }
  };

  const saveAutonomy = async (next: {
    enabled: boolean;
    minimumWait: number;
    maximumWait: number;
    actions: string[];
  }) => {
    const minimum = clampWait(next.minimumWait, 10);
    const maximum = clampWait(next.maximumWait, 20);
    const ordered = Math.min(minimum, maximum);
    const upper = Math.max(minimum, maximum);
    const enabledActions = autonomyActions
      .map((action) => action.id)
      .filter((id) => next.actions.includes(id));
    if (!enabledActions.length) {
      onError("Enable at least one autonomous action.");
      return;
    }
    setBusy("autonomy");
    setMessage(null);
    setMinimumWait(ordered);
    setMaximumWait(upper);
    setActions(enabledActions);
    try {
      await api.put("autonomy", {
        enabled: next.enabled,
        minimumWait: ordered,
        maximumWait: upper,
        actions: enabledActions,
      });
      await onReload();
      setMessage(next.enabled ? "Autonomous pet updated." : "Autonomous pet paused.");
    } catch (error) {
      onError(error instanceof Error ? error.message : "Could not update autonomy.");
    } finally {
      setBusy(null);
    }
  };

  const toggleAction = (actionID: string) => {
    const next = actions.includes(actionID)
      ? actions.filter((id) => id !== actionID)
      : [...actions, actionID];
    if (!next.length) {
      onError("Enable at least one autonomous action.");
      return;
    }
    void saveAutonomy({
      enabled: autonomyEnabled,
      minimumWait,
      maximumWait,
      actions: next,
    });
  };

  return (
    <section className="page pets-page">
      <div className="pets-layout">
        <aside className="pets-sidebar" aria-label="Installed pets">
          <div className="pets-sidebar-head">
            <div>
              <p className="kicker">Library</p>
              <strong>{pets.length} pets</strong>
            </div>
            <div className="pets-sidebar-actions">
              <a
                className="secondary pets-download-link"
                href="https://pet-runner.com"
                target="_blank"
                rel="noopener noreferrer"
                aria-label="Download pets"
                title="Download pets"
              >
                <CloudDownloadIcon />
              </a>
              {state.capabilities?.petImport !== false ? (
                <button type="button" className="secondary" onClick={() => void importPet()} disabled={busy === "import"}>
                  {busy === "import" ? "Opening…" : "Import"}
                </button>
              ) : null}
            </div>
          </div>
          <div className="pets-list" role="listbox" aria-label="Pet list">
            {pets.length ? pets.map((entry) => (
              <div key={entry.id} className={`pets-list-row ${entry.id === activeID ? "active" : ""} ${entry.id === selectedID ? "selected-live" : ""}`}>
                <button
                  type="button"
                  role="option"
                  aria-selected={entry.id === activeID}
                  className="pets-list-item"
                  onClick={() => setFocusID(entry.id)}
                >
                  <img
                    className="pets-list-thumb"
                    src={petPreviewURL(api, entry.id, { action: "idle" })}
                    alt=""
                    width={40}
                    height={44}
                    loading="lazy"
                  />
                  <span>
                    <strong>{entry.name}</strong>
                    <small>{entry.id === selectedID ? "Active on desktop" : entry.id}</small>
                  </span>
                </button>
                {canRemove ? (
                  <button
                    type="button"
                    className="pets-list-remove"
                    aria-label={`Remove ${entry.name}`}
                    title="Remove"
                    disabled={busy === "remove"}
                    onClick={() => void removePet(entry.id, entry.name)}
                  >
                    Remove
                  </button>
                ) : null}
              </div>
            )) : <div className="empty">No valid pets found in the pets library.</div>}
          </div>
          {(state.failures?.length ?? 0) > 0 ? (
            <p className="pets-failures" role="note">{state.failures!.length} package{state.failures!.length === 1 ? "" : "s"} failed to load.</p>
          ) : null}
        </aside>
        <div className="pets-detail">
          {pet ? (
            <PetDetail
              pet={pet}
              isActive={pet.id === selectedID}
              api={api}
              onActivate={() => void selectPet(pet.id)}
              onRemove={canRemove ? () => void removePet(pet.id, pet.name) : undefined}
              activating={busy === "select"}
              removing={busy === "remove"}
            />
          ) : (
            <article className="card pets-detail-empty"><div className="empty">Select a pet to preview animations and set it active on the desktop.</div></article>
          )}
        </div>
      </div>

      <aside className="pets-settings-bar" aria-label="Pet settings">
        <div className="pets-settings-row pets-settings-desktop">
          <div className="pets-settings-group">
            <p className="kicker">Size</p>
            <div className="width-pills" role="group" aria-label="Pet width">
              {petWidths.map((width) => (
                <button
                  key={width}
                  type="button"
                  className={(state.pet?.width ?? 112) === width ? "active" : ""}
                  onClick={() => void setWidth(width)}
                  disabled={busy === "width"}
                >
                  {width}
                </button>
              ))}
            </div>
          </div>

          {state.capabilities?.statusItem ? (
            <div className="pets-settings-group">
              <p className="kicker">Menu bar</p>
              <label className="toggle pets-status-toggle">
                <span>Icon</span>
                <input
                  type="checkbox"
                  checked={state.settings?.showStatusItem !== false}
                  onChange={(event) => void setStatusItem(event.target.checked)}
                  aria-label="Show PetRunner menu bar icon"
                />
                <i aria-hidden="true" />
              </label>
            </div>
          ) : null}

          <div className="pets-settings-group">
            <p className="kicker">Position</p>
            <button type="button" className="secondary pets-settings-button" onClick={() => void resetPosition()} disabled={busy === "reset"}>
              {busy === "reset" ? "Resetting…" : "Reset"}
            </button>
          </div>
        </div>

        <div className="pets-settings-row pets-settings-library">
          {state.capabilities?.petsDirectory !== false ? (
            <div className="pets-settings-group pets-settings-folder">
              <p className="kicker">Folder</p>
              <p className="pets-folder-source">{petsDirectoryLabel(state.settings?.petsDirectorySource)}</p>
              <code className="pets-folder-path" title={petsDirectory ?? undefined}>{petsDirectory ?? "Resolving…"}</code>
              <div className="pets-folder-actions">
                <button type="button" className="secondary" onClick={() => void revealPetsDirectory()} disabled={busy === "reveal" || !petsDirectory}>
                  Open
                </button>
                {petsDirectoryEditable ? (
                  <button type="button" className="secondary" onClick={() => void choosePetsDirectory()} disabled={busy === "folder"}>
                    {busy === "folder" ? "Opening…" : "Change…"}
                  </button>
                ) : (
                  <span className="pets-folder-locked">Locked by launch flag</span>
                )}
              </div>
            </div>
          ) : null}

          <div className="pets-settings-group pets-settings-autonomy">
            <div className="pets-autonomy-head">
              <p className="kicker">Autonomous</p>
              <label className="toggle">
                <span>{autonomyEnabled ? "On" : "Off"}</span>
                <input
                  type="checkbox"
                  checked={autonomyEnabled}
                  disabled={busy === "autonomy"}
                  onChange={(event) => void saveAutonomy({
                    enabled: event.target.checked,
                    minimumWait,
                    maximumWait,
                    actions,
                  })}
                  aria-label="Enable autonomous pet"
                />
                <i aria-hidden="true" />
              </label>
            </div>
            <div className={`pets-autonomy-controls ${autonomyEnabled ? "" : "is-disabled"}`}>
              <label className="pets-wait-field">
                <span>Min wait</span>
                <input
                  type="number"
                  min={autonomyWaitBounds.min}
                  max={autonomyWaitBounds.max}
                  step={1}
                  value={minimumWait}
                  disabled={!autonomyEnabled || busy === "autonomy"}
                  onChange={(event) => setMinimumWait(Number(event.target.value))}
                  onBlur={() => void saveAutonomy({
                    enabled: autonomyEnabled,
                    minimumWait,
                    maximumWait,
                    actions,
                  })}
                  aria-label="Minimum wait between autonomous actions"
                />
                <em>s</em>
              </label>
              <label className="pets-wait-field">
                <span>Max wait</span>
                <input
                  type="number"
                  min={autonomyWaitBounds.min}
                  max={autonomyWaitBounds.max}
                  step={1}
                  value={maximumWait}
                  disabled={!autonomyEnabled || busy === "autonomy"}
                  onChange={(event) => setMaximumWait(Number(event.target.value))}
                  onBlur={() => void saveAutonomy({
                    enabled: autonomyEnabled,
                    minimumWait,
                    maximumWait,
                    actions,
                  })}
                  aria-label="Maximum wait between autonomous actions"
                />
                <em>s</em>
              </label>
              <div className="pets-action-chips" role="group" aria-label="Autonomous actions">
                {autonomyActions.map((action) => (
                  <button
                    key={action.id}
                    type="button"
                    className={actions.includes(action.id) ? "active" : ""}
                    disabled={!autonomyEnabled || busy === "autonomy"}
                    onClick={() => toggleAction(action.id)}
                  >
                    {action.label}
                  </button>
                ))}
              </div>
            </div>
          </div>
        </div>

        {message ? <p className="form-message pets-settings-message" role="status">{message}</p> : null}
      </aside>
    </section>
  );
}

function PetDetail({
  pet,
  isActive,
  api,
  onActivate,
  onRemove,
  activating,
  removing,
}: {
  pet: PetInfo;
  isActive: boolean;
  api: DashboardAPI;
  onActivate: () => void;
  onRemove?: () => void;
  activating: boolean;
  removing: boolean;
}) {
  const rows = useMemo(() => animationRowsFor(pet.version), [pet.version]);
  const [activeRowID, setActiveRowID] = useState(rows[0]?.id ?? "idle");
  const activeRow = rows.find((row) => row.id === activeRowID) ?? rows[0];
  const titleVersion = pet.packageVersion ? ` (v${pet.packageVersion.replace(/^v/i, "")})` : pet.version === 2 ? " (v2)" : " (v1)";
  const tags = pet.tags.length ? pet.tags : ["animated"];

  useEffect(() => {
    setActiveRowID(rows[0]?.id ?? "idle");
  }, [pet.id, rows]);

  return (
    <article className="pets-detail-card">
      <header className="pets-detail-header">
        <p className="pets-meta">
          <span className="pets-meta-id"><i aria-hidden="true" />id / <strong>{pet.id}</strong></span>
          {pet.author ? <><span className="pets-meta-sep" aria-hidden="true">·</span><span>by {pet.author}</span></> : null}
          {isActive ? <span className="pets-active-pill">Active</span> : null}
        </p>
        <h1>{pet.name}{titleVersion}</h1>
        {pet.description ? <p className="pets-lede">{pet.description}</p> : null}
        <div className="pets-tags" aria-label="Tags">
          {tags.map((tag) => <span key={tag}>{tag}</span>)}
        </div>
        <div className="pets-detail-actions">
          {!isActive ? (
            <button type="button" className="primary" onClick={onActivate} disabled={activating}>
              {activating ? "Activating…" : "Use on desktop"}
            </button>
          ) : (
            <span className="pets-active-note">This pet is live on the desktop overlay.</span>
          )}
          {onRemove ? (
            <button type="button" className="danger-button" onClick={onRemove} disabled={removing}>
              {removing ? "Removing…" : "Remove"}
            </button>
          ) : null}
        </div>
      </header>

      <div className="pets-showcase">
        {pet.version === 2 ? (
          <button
            type="button"
            className={`pets-look-affordance ${activeRowID.startsWith("look-") ? "active" : ""}`}
            onClick={() => setActiveRowID(activeRowID === "look-right-side" ? "look-left-side" : "look-right-side")}
          >
            <span aria-hidden="true">{activeRowID.startsWith("look-") ? "✓" : "→"}</span>
            {activeRowID.startsWith("look-") ? "Looking around" : "Try its 16 look directions"}
          </button>
        ) : null}
        {activeRow ? <PetSpritePreview api={api} pet={pet} row={activeRow} /> : null}
        <div className="pets-state-chips" role="tablist" aria-label="Animation states">
          {rows.map((row) => (
            <button
              key={row.id}
              type="button"
              role="tab"
              aria-selected={row.id === activeRow?.id}
              className={row.id === activeRow?.id ? "active" : ""}
              onClick={() => setActiveRowID(row.id)}
            >
              {row.label}
            </button>
          ))}
        </div>
      </div>
    </article>
  );
}
