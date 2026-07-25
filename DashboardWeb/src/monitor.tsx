import { useEffect, useMemo, useState } from "react";
import { DashboardAPI } from "./api";
import { MonitorBubbleSection } from "./bubble";
import { displayProvider } from "./format";
import { ProviderIcon } from "./icons";
import type { AppState, MonitorProviderOption, MonitorSettings, Provider } from "./types";

function headerColorCSS(option?: MonitorProviderOption): string {
  const color = option?.headerColor;
  if (!color) return "#c8ff77";
  const channel = (value: number) => Math.round(Math.min(1, Math.max(0, value)) * 255);
  return `rgb(${channel(color.red)} ${channel(color.green)} ${channel(color.blue)})`;
}

export function MonitorView({
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
  const monitor = state.monitor;
  const options = monitor?.providers ?? [];
  const [draftProvider, setDraftProvider] = useState<Provider | null>(monitor?.provider ?? options[0]?.id ?? "claude");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  useEffect(() => {
    if (monitor?.provider) {
      setDraftProvider(monitor.provider);
      return;
    }
    if (!draftProvider && options[0]) setDraftProvider(options[0].id);
  }, [monitor?.provider, options, draftProvider]);

  const selected = useMemo(
    () => options.find((entry) => entry.id === draftProvider) ?? options[0],
    [options, draftProvider],
  );
  const enabled = Boolean(monitor?.enabled);
  const activeProvider = monitor?.provider ?? null;
  const canEnable = Boolean(selected?.id);

  const apply = async (nextEnabled: boolean, provider: Provider | null) => {
    if (nextEnabled && !provider) {
      onError("Choose a provider before enabling Agent Monitor.");
      return;
    }
    setBusy(true);
    setMessage(null);
    try {
      const body: { enabled: boolean; provider?: Provider } = { enabled: nextEnabled };
      if (provider) body.provider = provider;
      const result = await api.put<MonitorSettings>("monitor", body);
      await onReload();
      if (result.enabled) {
        setMessage(`Agent Monitor enabled for ${displayProvider(result.provider ?? provider ?? "provider")}.`);
      } else {
        setMessage("Agent Monitor disabled. PetRunner-owned hooks were removed.");
      }
    } catch (error) {
      onError(error instanceof Error ? error.message : "Could not update Agent Monitor.");
    } finally {
      setBusy(false);
    }
  };

  const onToggle = (checked: boolean) => {
    if (checked) void apply(true, selected?.id ?? null);
    else void apply(false, null);
  };

  const onSelectProvider = (provider: Provider) => {
    setDraftProvider(provider);
    if (enabled) void apply(true, provider);
  };

  const setQuotaBarVisible = async (quotaBarVisible: boolean) => {
    setBusy(true);
    setMessage(null);
    try {
      await api.put("settings", { quotaBarVisible });
      await onReload();
      setMessage(quotaBarVisible ? "Quota bar shown under the pet." : "Quota bar hidden.");
    } catch (error) {
      onError(error instanceof Error ? error.message : "Could not update quota bar.");
    } finally {
      setBusy(false);
    }
  };

  const setQuotaBarMode = async (quotaBarMode: NonNullable<AppState["settings"]>["quotaBarMode"]) => {
    setBusy(true);
    setMessage(null);
    try {
      await api.put("settings", { quotaBarMode, quotaBarVisible: true });
      await onReload();
      setMessage(`Quota bar mode: ${quotaBarMode}.`);
    } catch (error) {
      onError(error instanceof Error ? error.message : "Could not update quota bar mode.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="page monitor-page">
      <div className="intro">
        <div>
          <p className="kicker">Agent Monitor</p>
          <h1>Watch local agent sessions.</h1>
          <p>Install provider hooks, customize the desktop bubble, and show quota HP bars under the pet.</p>
        </div>
        <span className={`range-label ${enabled ? "monitor-live" : ""}`}>
          {enabled ? `Live · ${displayProvider(activeProvider ?? selected?.id ?? "provider")}` : "Off"}
        </span>
      </div>

      <article className="card monitor-settings-card">
        <div className="provider-settings-head">
          <div>
            <p className="kicker">Settings</p>
            <h2>Enable & provider</h2>
          </div>
          <label className="toggle">
            <span>Enabled</span>
            <input
              type="checkbox"
              checked={enabled}
              disabled={busy || (!enabled && !canEnable)}
              onChange={(event) => onToggle(event.target.checked)}
              aria-label="Enable Agent Monitor"
            />
            <i aria-hidden="true" />
          </label>
        </div>

        <p className="monitor-lede">
          Choose one provider for local monitor hooks. Provider and status are always shown in the bubble.
        </p>

        <div className="monitor-provider-grid" role="radiogroup" aria-label="Monitor provider">
          {(options.length ? options : fallbackOptions()).map((option) => {
            const checked = selected?.id === option.id;
            return (
              <button
                key={option.id}
                type="button"
                role="radio"
                aria-checked={checked}
                className={`monitor-provider-option ${option.id} ${checked ? "active" : ""}`}
                disabled={busy}
                onClick={() => onSelectProvider(option.id)}
              >
                <span className={`provider-mark ${option.id}`} style={{ background: headerColorCSS(option) }} aria-hidden="true">
                  <ProviderIcon provider={option.id} />
                </span>
                <span>
                  <strong>{displayProvider(option.id)}</strong>
                  <small>{option.detected ? "Detected on this Mac" : "Not detected yet"}</small>
                </span>
              </button>
            );
          })}
        </div>

        <div className="monitor-warning" role="note">
          <strong>Hook installation</strong>
          <p>
            Enabling Agent Monitor installs PetRunner-owned hooks for the selected provider and removes PetRunner hooks
            from the other providers. Existing third-party hooks stay untouched.
          </p>
        </div>

        <dl className="info-rows">
          <div>
            <dt>Hooks folder</dt>
            <dd><code>{selected?.hooksDirectory ?? "—"}</code></dd>
          </div>
          <div>
            <dt>Config file</dt>
            <dd><code>{selected?.configPath ?? "—"}</code></dd>
          </div>
          <div>
            <dt>Status</dt>
            <dd>{enabled ? `Monitoring ${displayProvider(activeProvider ?? selected?.id ?? "provider")}` : "Disabled"}</dd>
          </div>
        </dl>

        {message ? <p className="form-message" role="status">{message}</p> : null}
        {busy ? <p className="form-message" role="status">Updating…</p> : null}
      </article>

      <article className="card monitor-settings-card">
        <div className="provider-settings-head">
          <div>
            <p className="kicker">Desktop</p>
            <h2>Quota bar</h2>
          </div>
          <label className="toggle">
            <span>Show under pet</span>
            <input
              type="checkbox"
              checked={state.settings?.quotaBarVisible !== false}
              disabled={busy}
              onChange={(event) => void setQuotaBarVisible(event.target.checked)}
              aria-label="Show quota bar under pet"
            />
            <i aria-hidden="true" />
          </label>
        </div>
        <p className="monitor-lede">
          Pixel HP bars for the selected Monitor provider. Auto uses your daily limit when set, otherwise plan quota,
          otherwise $10/day and $100/month defaults.
        </p>
        <div className="width-pills" role="group" aria-label="Quota bar mode">
          {([
            ["auto", "Auto"],
            ["daily", "Daily"],
            ["monthly", "Monthly"],
            ["plan", "Plan"],
          ] as const).map(([mode, label]) => (
            <button
              key={mode}
              type="button"
              className={state.settings?.quotaBarMode === mode || (mode === "auto" && !state.settings?.quotaBarMode) ? "active" : ""}
              disabled={busy || state.settings?.quotaBarVisible === false}
              onClick={() => void setQuotaBarMode(mode)}
            >
              {label}
            </button>
          ))}
        </div>
      </article>

      <MonitorBubbleSection state={state} api={api} onReload={onReload} onError={onError} />
    </section>
  );
}

function fallbackOptions(): MonitorProviderOption[] {
  return (["claude", "codex", "cursor"] as const).map((id) => ({
    id,
    name: id.toUpperCase(),
    detected: false,
    hooksDirectory: `~/.${id}`,
    configPath: id === "claude" ? "~/.claude/settings.json" : `~/.${id}/hooks.json`,
  }));
}
