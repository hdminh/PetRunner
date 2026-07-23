import { useCallback, useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import { AnalyticsModels, AnalyticsPageTabs, AnalyticsProjects, AnalyticsSessions, type AnalyticsTab } from "./analytics";
import { DashboardAPI } from "./api";
import {
  apiRangeForProviderSpend,
  buildSpendSeries,
  daySpendBreakdown,
  formatDayRangeLabel,
  formatSpendDayHeading,
  groupByProvider,
  localDayKey,
  normalizeActivity,
  normalizeState,
  normalizeUsage,
  normalizeUsageModels,
  normalizeUsageProjects,
  normalizeUsageSessions,
  providerDayKeys,
  splitSpendByUsageType,
  sumCost,
  sumTokens,
  type DaySpendBreakdown,
  type ProviderSpendRange,
  type SpendGroupBy,
  type SpendMetric,
  type SpendSeries,
} from "./data";
import { displayProvider, formatCost, formatDate, formatRatePerMillion, formatTokens } from "./format";
import { AppMark, GITHUB_REPO_URL, GitHubMark, ProviderIcon } from "./icons";
import { PetsView } from "./pets";
import { MonitorView } from "./monitor";
import {
  hasExplicitAnalyticsTab,
  isRouteHash,
  parseLocation,
  readInitialNavigation,
  resolveAnalyticsTab,
  syncHash,
  writeStoredAnalyticsTab,
  writeStoredProvider,
  writeStoredProviderPanel,
  type ProviderPanel,
  type View,
} from "./routing";
import { providers, type ActivityStats, type AppState, type Budget, type PricingCatalogEntry, type PricingCatalogResponse, type Provider, type ProviderInfo, type UsageModel, type UsageProject, type UsageRecord, type UsageResponse, type UsageSession } from "./types";
import "./styles.css";

const api = new DashboardAPI();
type ProviderSummary = NonNullable<UsageResponse["providers"][Provider]>;
const blankUsage: UsageResponse = { totals: { tokens: 0, input: 0, cachedInput: 0, output: 0, cost: 0, sessions: 0, recordCount: 0 }, providers: {}, buckets: [], records: [] };
const blankActivity: ActivityStats = {
  activeDays: 0,
  currentStreak: 0,
  longestStreak: 0,
  peakHour: -1,
  requestCount: 0,
  totalTokens: 0,
  heatmap: Array.from({ length: 7 }, () => Array.from({ length: 24 }, () => 0)),
  heatmapMax: 0,
  tokenHeatmap: Array.from({ length: 7 }, () => Array.from({ length: 24 }, () => 0)),
  comparison: null,
};
const spendRanges: { id: ProviderSpendRange; label: string }[] = [
  { id: "1d", label: "1d" },
  { id: "7d", label: "7d" },
  { id: "30d", label: "30d" },
  { id: "mtd", label: "MTD" },
];
// Dark-UI series palette: muted teal/slate/coral/amber — no neon lime.
const modelColors = ["#5a8f86", "#6e8499", "#c17d6a", "#b9945c", "#6a8570", "#8b7d8f", "#7d8f9e", "#a8896a"];
const ACTIVITY_DOW = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;
const ACTIVITY_HOUR_LABELS = new Set([0, 3, 6, 9, 12, 15, 18, 21]);

function Card({ children, className = "" }: { children: React.ReactNode; className?: string }) { return <article className={`card ${className}`}>{children}</article>; }
function Empty({ children }: { children: React.ReactNode }) { return <div className="empty">{children}</div>; }

function App() {
  const initial = useMemo(() => readInitialNavigation(), []);
  const [view, setView] = useState<View>(initial.view);
  const [analyticsTab, setAnalyticsTab] = useState<AnalyticsTab>(initial.analyticsTab);
  const [selectedProvider, setSelectedProvider] = useState<Provider>(initial.selectedProvider);
  const [providerPanel, setProviderPanel] = useState<ProviderPanel>(initial.providerPanel);
  const [range, setRange] = useState<ProviderSpendRange>("7d");
  const [state, setState] = useState<AppState>({});
  const [usage, setUsage] = useState<UsageResponse>(blankUsage);
  const [activity, setActivity] = useState<ActivityStats>(blankActivity);
  const [usageSessions, setUsageSessions] = useState<UsageSession[]>([]);
  const [usageProjects, setUsageProjects] = useState<UsageProject[]>([]);
  const [usageModels, setUsageModels] = useState<UsageModel[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [activityError, setActivityError] = useState<string | null>(null);
  const [sessionsError, setSessionsError] = useState<string | null>(null);
  const [projectsError, setProjectsError] = useState<string | null>(null);
  const [modelsError, setModelsError] = useState<string | null>(null);
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);

  const load = useCallback(async (quiet = false) => {
    if (!quiet) setLoading(true);
    try {
      const usageQuery: Record<string, string> = { range: apiRangeForProviderSpend(range) };
      // Provider detail charts need the full filtered window. Without a provider
      // filter, the shared preview truncates recent Codex rows over older Cursor days.
      if (view === "provider") usageQuery.provider = selectedProvider;
      const [rawState, rawUsage] = await Promise.all([
        api.get<unknown>("overview").catch(() => api.get<unknown>("state")),
        api.get<unknown>("usage", usageQuery),
      ]);
      setState(normalizeState(rawState)); setUsage(normalizeUsage(rawUsage));
      const [activityResult, sessionsResult, projectsResult, modelsResult] = await Promise.allSettled([
        api.get<unknown>("activity", { range: "all" }),
        api.get<unknown>("sessions", { range: "all" }),
        api.get<unknown>("projects", { range: "all" }),
        api.get<unknown>("models", { range: "all" }),
      ]);
      if (activityResult.status === "fulfilled") { setActivity(normalizeActivity(activityResult.value)); setActivityError(null); }
      else setActivityError(errorMessage(activityResult.reason, "Activity is unavailable."));
      if (sessionsResult.status === "fulfilled") { setUsageSessions(normalizeUsageSessions(sessionsResult.value)); setSessionsError(null); }
      else setSessionsError(errorMessage(sessionsResult.reason, "Sessions are unavailable."));
      if (projectsResult.status === "fulfilled") { setUsageProjects(normalizeUsageProjects(projectsResult.value)); setProjectsError(null); }
      else setProjectsError(errorMessage(projectsResult.reason, "Projects are unavailable."));
      if (modelsResult.status === "fulfilled") { setUsageModels(normalizeUsageModels(modelsResult.value)); setModelsError(null); }
      else setModelsError(errorMessage(modelsResult.reason, "Models are unavailable."));
      setError(null); setLastUpdated(new Date());
    } catch (exception) {
      setError(exception instanceof Error ? exception.message : "Dashboard is unavailable.");
    } finally { setLoading(false); }
  }, [range, selectedProvider, view]);

  useEffect(() => { void load(); }, [load]);
  useEffect(() => { const timer = window.setInterval(() => void load(true), 15_000); return () => window.clearInterval(timer); }, [load]);

  // Normalize empty hash on first paint so reload restores a concrete route.
  useEffect(() => {
    syncHash({
      view: initial.view,
      analyticsTab: initial.analyticsTab,
      provider: initial.selectedProvider,
      panel: initial.view === "provider" ? initial.providerPanel : null,
    }, "replace");
  }, [initial]);

  useEffect(() => {
    const onHashChange = () => {
      if (!isRouteHash()) return;
      const parsed = parseLocation();
      setView(parsed.view);
      if (parsed.view === "analytics") {
        const tab = resolveAnalyticsTab(parsed.analyticsTab, hasExplicitAnalyticsTab());
        setAnalyticsTab(tab);
        writeStoredAnalyticsTab(tab);
      }
      if (parsed.provider) {
        setSelectedProvider(parsed.provider);
        writeStoredProvider(parsed.provider);
      }
      if (parsed.view === "provider" && parsed.panel) {
        setProviderPanel(parsed.panel);
        writeStoredProviderPanel(parsed.panel);
      }
    };
    window.addEventListener("hashchange", onHashChange);
    return () => window.removeEventListener("hashchange", onHashChange);
  }, []);

  const navigate = useCallback((next: {
    view: View;
    analyticsTab?: AnalyticsTab;
    provider?: Provider;
    panel?: ProviderPanel;
    mode?: "push" | "replace";
  }) => {
    const tab = next.analyticsTab ?? analyticsTab;
    const provider = next.provider ?? selectedProvider;
    const panel = next.panel ?? providerPanel;
    setView(next.view);
    if (next.analyticsTab) {
      setAnalyticsTab(next.analyticsTab);
      writeStoredAnalyticsTab(next.analyticsTab);
    } else if (next.view === "analytics") {
      writeStoredAnalyticsTab(tab);
    }
    if (next.provider) {
      setSelectedProvider(next.provider);
      writeStoredProvider(next.provider);
    }
    if (next.panel) {
      setProviderPanel(next.panel);
      writeStoredProviderPanel(next.panel);
    }
    syncHash({
      view: next.view,
      analyticsTab: tab,
      provider,
      panel: next.view === "provider" ? panel : null,
    }, next.mode ?? "push");
  }, [analyticsTab, selectedProvider, providerPanel]);

  const grouped = useMemo(() => groupByProvider(usage.records), [usage.records]);
  const providerInfos = useMemo(() => providers.map((id) => state.providers?.[id] ?? defaultProviderInfo(id)), [state.providers]);
  const enabledCount = providerInfos.filter((info) => info.enabled).length;
  // Top-nav spend chip follows Monitor’s active provider only — hide when monitor is off or unset.
  const monitorProvider = state.monitor?.enabled ? state.monitor.provider : null;
  const monitorTodayCost = monitorProvider == null
    ? null
    : (state.providers?.[monitorProvider]?.todayCost ?? 0);
  const selectProvider = (provider: Provider) => { navigate({ view: "provider", provider }); };
  const setAnalyticsProvider = (provider: Provider) => { navigate({ view: "analytics", analyticsTab, provider, mode: "replace" }); };
  const setProvidersPanel = (panel: ProviderPanel) => { navigate({ view: "provider", panel, mode: "replace" }); };
  const openAnalytics = () => { navigate({ view: "analytics", analyticsTab }); };
  const setAnalyticsViewTab = (tab: AnalyticsTab) => { navigate({ view: "analytics", analyticsTab: tab }); };
  const openProviders = () => { navigate({ view: "provider" }); };
  const refresh = async () => { try { await api.post("refresh"); window.setTimeout(() => void load(), 350); } catch (exception) { setError(exception instanceof Error ? exception.message : "Could not refresh usage."); } };
  const setProviderEnabled = async (provider: Provider, enabled: boolean) => {
    try {
      await api.put(`providers/${provider}`, { enabled });
      setState((current) => {
        const previous = current.providers?.[provider] ?? defaultProviderInfo(provider);
        return { ...current, providers: { ...current.providers, [provider]: { ...previous, enabled, status: enabled ? previous.status : "Disabled" } } };
      });
      window.setTimeout(() => void load(true), 350);
    } catch (exception) {
      setError(exception instanceof Error ? exception.message : "Could not update provider.");
    }
  };

  return <div className="shell">
    <a className="skip" href="#content" onClick={(event) => {
      event.preventDefault();
      const main = document.getElementById("content");
      main?.setAttribute("tabIndex", "-1");
      main?.focus();
    }}>Skip to content</a>
    <header className="topbar">
      <div className="brand">
        <button className="wordmark" onClick={() => navigate({ view: "overview" })} aria-label="PetRunner usage overview"><AppMark /><strong>PetRunner</strong><em>usage</em></button>
        {monitorProvider && monitorTodayCost != null ? (
          <span
            className="monitor-spend"
            title={`${displayProvider(monitorProvider)} today’s spend`}
            aria-label={`${displayProvider(monitorProvider)} today’s spend ${formatCost(monitorTodayCost)}`}
          >
            <span className={`provider-mark chip ${monitorProvider}`} aria-hidden="true"><ProviderIcon provider={monitorProvider} /></span>
            <strong>{formatCost(monitorTodayCost)}</strong>
          </span>
        ) : null}
      </div>
      <nav aria-label="Dashboard">
        <button className={view === "overview" ? "active" : ""} onClick={() => navigate({ view: "overview" })}>Overview</button>
        <button className={view === "provider" ? "active" : ""} onClick={() => openProviders()}>Providers</button>
        <button className={view === "analytics" ? "active" : ""} onClick={() => openAnalytics()}>Analytics</button>
        <button className={view === "pets" ? "active" : ""} onClick={() => navigate({ view: "pets" })}>Pets</button>
        <button className={view === "monitor" ? "active" : ""} onClick={() => navigate({ view: "monitor" })}>Monitor</button>
      </nav>
      <div className="top-actions">
        <span className={`connection ${error ? "offline" : ""}`}>{error ? "Offline" : lastUpdated ? "Local" : "Connecting"}</span>
        <button className="refresh" onClick={() => void refresh()} disabled={loading}>{loading ? "Loading…" : "Refresh"}</button>
        <a className="github-link" href={GITHUB_REPO_URL} target="_blank" rel="noopener noreferrer" aria-label="PetRunner on GitHub" title="GitHub">
          <GitHubMark />
        </a>
      </div>
    </header>
    {error && <div className="notice" role="alert"><span>{error}</span><button onClick={() => void load()}>Retry</button></div>}
    <main id="content">
      {view === "overview" && <Overview state={state} usage={usage} grouped={grouped} activity={activity} activityError={activityError} range={range} onProvider={selectProvider} onOpenProviders={openProviders} />}
      {view === "provider" && <ProviderView provider={selectedProvider} panel={providerPanel} onPanelChange={setProvidersPanel} providerInfos={providerInfos} enabledCount={enabledCount} records={grouped[selectedProvider]} summary={usage.providers[selectedProvider]} range={range} setRange={setRange} onProvider={selectProvider} onSetEnabled={setProviderEnabled} info={state.providers?.[selectedProvider]} cursor={state.cursor} budget={state.settings?.budgets?.[selectedProvider]} onSaveBudget={async (budget) => { await api.put("budgets", { budgets: { [selectedProvider]: budget } }); await load(); }} />}
      {view === "analytics" && (
        <section className="page analytics-page">
          <AnalyticsPageTabs active={analyticsTab} onChange={setAnalyticsViewTab} />
          {analyticsTab === "sessions" && <AnalyticsSessions sessions={usageSessions} error={sessionsError} provider={selectedProvider} onProviderChange={setAnalyticsProvider} />}
          {analyticsTab === "projects" && <AnalyticsProjects projects={usageProjects} error={projectsError} provider={selectedProvider} onProviderChange={setAnalyticsProvider} />}
          {analyticsTab === "models" && <AnalyticsModels models={usageModels} error={modelsError} provider={selectedProvider} onProviderChange={setAnalyticsProvider} />}
        </section>
      )}
      {view === "pets" && <PetsView state={state} api={api} onReload={async () => { await load(true); }} onError={setError} />}
      {view === "monitor" && <MonitorView state={state} api={api} onReload={async () => { await load(true); }} onError={setError} />}
    </main>
    <footer>Usage stays on this device. Claude and Codex costs are calculated estimates. Cursor usage is shown only when Cursor reports it.</footer>
  </div>;
}

function Overview({ state, usage, grouped, activity, activityError, range, onProvider, onOpenProviders }: { state: AppState; usage: UsageResponse; grouped: Record<Provider, UsageRecord[]>; activity: ActivityStats; activityError: string | null; range: ProviderSpendRange; onProvider: (provider: Provider) => void; onOpenProviders: () => void }) {
  const today = state.kpis ?? {};
  const enabledProviders = providers.filter((provider) => state.providers?.[provider]?.enabled !== false);
  const enabledRecords = usage.records.filter((record) => enabledProviders.includes(record.provider));
  const monthlyCost = today.monthCost ?? sumCost(enabledRecords);
  return <section className="page"><div className="intro"><div><p className="kicker">Local usage cockpit</p><h1>Know where the work went.</h1><p>Tokens, costs, and when you usually code across the tools you use.</p></div><span className="range-label overview-range">{formatDayRangeLabel(providerDayKeys(range))}</span></div>
    <div className="metrics"><Metric label="Today’s tokens" value={formatTokens(today.todayTokens ?? 0)} note={`${today.sessionCount ?? 0} sessions`} /><Metric label="Today’s cost" value={formatCost(today.todayCost)} note="Calculated / reported" /><Metric label="This month" value={formatCost(monthlyCost)} note="Known cost only" /><Metric label="Cache reads" value={`${Math.round((today.cacheRatio ?? 0) * 100)}%`} note="Of input tokens" /></div>
    <div className="section-head"><div><p className="kicker">Providers</p><h2>At a glance</h2></div><button className="text-button" onClick={onOpenProviders}>Open providers</button></div>
    <div className="provider-grid">{enabledProviders.map((provider) => <ProviderCard key={provider} provider={provider} info={state.providers?.[provider]} records={grouped[provider]} summary={usage.providers[provider]} budget={state.settings?.budgets?.[provider]} cursor={state.cursor} onClick={() => onProvider(provider)} />)}</div>
    <div className="split"><Card className="trend"><div className="section-head"><div><p className="kicker">Daily volume</p><h2>Usage rhythm</h2></div><span>{formatTokens(usage.totals.tokens)} total</span></div><Bars buckets={usage.buckets} /></Card><ActivityPanel activity={activity} error={activityError} /></div>
  </section>;
}

function ActivityPanel({ activity, error }: { activity: ActivityStats; error: string | null }) {
  if (error) {
    return <Card className="activity-card"><div className="section-head"><div><h2>Activity</h2><p className="activity-subtitle">Lifetime stats and when you usually code</p></div></div><Empty>Activity error: {error}</Empty></Card>;
  }
  const streak = `${activity.currentStreak} / ${activity.longestStreak} d`;
  const peak = activity.peakHour < 0 ? "—" : formatPeakHour(activity.peakHour);
  return <Card className="activity-card">
    <div className="section-head activity-head">
      <div>
        <h2>Activity</h2>
        <p className="activity-subtitle">Lifetime stats and when you usually code</p>
      </div>
    </div>
    <div className="activity-body">
      <div className="activity-tiles">
        <ActivityTile label="Active days" value={activity.activeDays.toLocaleString()} />
        <ActivityTile label="Streak (cur / max)" value={streak} />
        <ActivityTile label="Peak hour" value={peak} />
      </div>
      <div className="activity-heatmap-wrap">
        {activity.requestCount > 0 ? <ActivityHeatmap heatmap={activity.heatmap} max={activity.heatmapMax} /> : <Empty>No usage yet to chart a weekly rhythm.</Empty>}
        {activity.comparison ? <p className="activity-footer">You&apos;ve used ~{formatActivityMultiplier(activity.comparison.multiplier)}× more tokens than {activity.comparison.label}.</p> : null}
      </div>
    </div>
  </Card>;
}

function ActivityTile({ label, value }: { label: string; value: string }) {
  return <div className="activity-tile"><span>{label}</span><strong>{value}</strong></div>;
}

function ActivityHeatmap({ heatmap, max }: { heatmap: number[][]; max: number }) {
  return <div className="activity-heatmap" role="img" aria-label="Week by hour activity heatmap">
    {heatmap.map((row, dow) => (
      <div className="activity-heatmap-row" key={ACTIVITY_DOW[dow]}>
        <span className="activity-dow">{ACTIVITY_DOW[dow]}</span>
        <div className="activity-heatmap-cells">
          {row.map((count, hour) => {
            const intensity = max > 0 && count > 0 ? Math.sqrt(count / max) : 0;
            const alpha = count > 0 ? 0.18 + intensity * 0.82 : 0;
            return <span
              key={hour}
              className={`activity-cell${count ? " active" : ""}`}
              title={`${ACTIVITY_DOW[dow]} ${formatPeakHour(hour)} · ${count} request${count === 1 ? "" : "s"}`}
              style={count ? { backgroundColor: `rgba(110, 148, 156, ${alpha.toFixed(2)})` } : undefined}
            />;
          })}
        </div>
      </div>
    ))}
    <div className="activity-heatmap-row hours">
      <span className="activity-dow" aria-hidden="true" />
      <div className="activity-heatmap-cells hour-labels">
        {Array.from({ length: 24 }, (_, hour) => (
          <span key={hour}>{ACTIVITY_HOUR_LABELS.has(hour) ? formatHourShort(hour) : ""}</span>
        ))}
      </div>
    </div>
  </div>;
}

function formatPeakHour(hour: number): string {
  if (hour === 0) return "12 AM";
  if (hour < 12) return `${hour} AM`;
  if (hour === 12) return "12 PM";
  return `${hour - 12} PM`;
}

function formatHourShort(hour: number): string {
  if (hour === 0) return "12a";
  if (hour < 12) return `${hour}a`;
  if (hour === 12) return "12p";
  return `${hour - 12}p`;
}

function formatActivityMultiplier(value: number): string {
  if (value < 10) return value.toFixed(1);
  if (value < 1000) return String(Math.round(value));
  if (value < 1_000_000) return `${(value / 1000).toFixed(1)}K`;
  return `${(value / 1_000_000).toFixed(1)}M`;
}

function Metric({ label, value, note }: { label: string; value: string; note: string }) { return <Card className="metric"><span>{label}</span><strong>{value}</strong><small>{note}</small></Card>; }

function ProviderCard({ provider, info, records, summary, budget, cursor, onClick }: { provider: Provider; info?: ProviderInfo; records: UsageRecord[]; summary?: ProviderSummary; budget?: { monthlyUSD: number | null }; cursor?: AppState["cursor"]; onClick: () => void }) {
  // Home glance cards use the shared usage range (default 7d), matching Claude/Codex today.
  const total = summary?.cost ?? sumCost(records);
  const totalTokens = summary?.tokens ?? sumTokens(records);
  const budgetValue = budget?.monthlyUSD ?? null;
  const percent = budgetValue ? Math.min(100, Math.round(total / budgetValue * 100)) : null;
  const account = info?.account ?? info?.email ?? (provider === "cursor" ? (cursor?.connected ? "Connected" : "Not connected") : null);
  const meta = [account, info?.plan].filter(Boolean).join(" · ") || (provider === "cursor" ? "Cloud usage, not local context counters" : "tokens in this range");
  const footer = provider === "cursor"
    ? (cursor?.connected ? "Provider-reported usage is available when Cursor returns it." : "Sign in to Cursor.app to see provider-reported usage.")
    : (percent === null ? "Calculated from local session logs" : `${percent}% of ${formatCost(budgetValue)} monthly budget`);
  return <button className={`provider-card ${provider}`} onClick={onClick}>
    <div className="provider-top"><span className="provider-mark" aria-hidden="true"><ProviderIcon provider={provider} /></span><span className="arrow">↗</span></div>
    <h3>{displayProvider(provider)}</h3>
    <strong>{formatTokens(totalTokens)}</strong>
    <span className="provider-cost">{formatCost(total)}</span>
    <small>{meta}</small>
    {percent !== null && <div className="meter"><i style={{ width: `${percent}%` }} /></div>}
    <p>{footer}</p>
  </button>;
}

export function ProviderView({ provider, panel, onPanelChange, providerInfos, enabledCount, records, summary, range, setRange, onProvider, onSetEnabled, info, cursor, budget, onSaveBudget }: {
  provider: Provider;
  panel: ProviderPanel;
  onPanelChange: (panel: ProviderPanel) => void;
  providerInfos: ProviderInfo[];
  enabledCount: number;
  records: UsageRecord[];
  summary?: ProviderSummary;
  range: ProviderSpendRange;
  setRange: (range: ProviderSpendRange) => void;
  onProvider: (provider: Provider) => void;
  onSetEnabled: (provider: Provider, enabled: boolean) => Promise<void>;
  info?: ProviderInfo;
  cursor?: AppState["cursor"];
  budget?: Budget;
  onSaveBudget: (budget: Budget) => Promise<void>;
}) {
  const detail = info ?? defaultProviderInfo(provider);
  const [groupBy, setGroupBy] = useState<SpendGroupBy>("model");
  const [metric, setMetric] = useState<SpendMetric>("spend");
  const dayKeys = useMemo(() => providerDayKeys(range), [range]);
  const series = useMemo(() => buildSpendSeries(records, dayKeys, { groupBy, metric }), [records, dayKeys, groupBy, metric]);
  const totalSpend = summary?.cost ?? sumCost(records);
  const spendSplit = useMemo(() => splitSpendByUsageType(records), [records]);
  const models = summary?.models ?? Object.entries(records.reduce<Record<string, UsageRecord[]>>((all, record) => { const key = record.model ?? "Unknown model"; (all[key] ??= []).push(record); return all; }, {})).map(([model, values]) => ({ model, tokens: sumTokens(values), cost: sumCost(values), recordCount: values.length })).sort((a, b) => b.tokens - a.tokens);
  const rangeLabel = formatDayRangeLabel(dayKeys);
  const subtitle = range === "1d"
    ? "Your usage for today"
    : range === "mtd"
      ? "Your usage per day from the start of this month"
      : `Your usage per day across the last ${range === "7d" ? "7" : "30"} days`;

  return <section className="page providers-page">
    <div className="providers-layout">
      <aside className="providers-sidebar" aria-label="Providers">
        <div className="providers-sidebar-head"><p className="kicker">Providers</p><strong>{enabledCount} on</strong></div>
        <div className="providers-list" role="listbox" aria-label="Provider list">
          {providerInfos.map((entry) => <button key={entry.id} role="option" aria-selected={entry.id === provider} className={`providers-list-item ${entry.id === provider ? "active" : ""} ${entry.enabled ? "on" : "off"}`} onClick={() => onProvider(entry.id)}>
            <span className={`provider-mark sidebar ${entry.id}`} aria-hidden="true"><ProviderIcon provider={entry.id} /></span>
            <span><strong>{displayProvider(entry.id)}</strong><small>{entry.enabled ? (entry.account ?? entry.status ?? "Enabled") : "Disabled"}</small></span>
          </button>)}
        </div>
      </aside>
      <div className="providers-detail">
        <Card className="provider-settings-card">
          <div className="provider-settings-head">
            <div className="provider-settings-title"><span className={`provider-mark settings ${provider}`} aria-hidden="true"><ProviderIcon provider={provider} /></span><div><p className="kicker">{displayProvider(provider)}</p><h1>Provider settings</h1></div></div>
            <label className="toggle">
              <span>Enabled</span>
              <input type="checkbox" checked={detail.enabled} onChange={(event) => void onSetEnabled(provider, event.target.checked)} aria-label={`Enable ${displayProvider(provider)}`} />
              <i aria-hidden="true" />
            </label>
          </div>
          <dl className="info-rows">
            <div><dt>Source</dt><dd>{detail.source ?? "—"}</dd></div>
            <div><dt>Updated</dt><dd>{detail.updatedAt ? formatDate(detail.updatedAt) : "—"}</dd></div>
            <div><dt>Status</dt><dd>{detail.enabled ? (detail.status ?? "Unknown") : "Disabled"}</dd></div>
            <div><dt>Account</dt><dd>{detail.account ?? detail.email ?? "—"}</dd></div>
            <div><dt>Plan</dt><dd>{detail.plan ?? "—"}</dd></div>
            {detail.organization ? <div><dt>Organization</dt><dd>{detail.organization}</dd></div> : null}
          </dl>
          <div className="provider-connection">
            <p className="kicker">Connection</p>
            <p>{connectionNote(provider, detail, cursor)}</p>
            <ExternalLinks links={detail} />
          </div>
          <ProviderBudgetEditor key={provider} provider={provider} budget={budget} onSave={onSaveBudget} />
        </Card>
        <div className="providers-panel-toggle" role="tablist" aria-label="Provider panel">
          <button role="tab" aria-selected={panel === "usage"} className={panel === "usage" ? "active" : ""} onClick={() => onPanelChange("usage")}>Usage</button>
          <button role="tab" aria-selected={panel === "pricing"} className={panel === "pricing" ? "active" : ""} onClick={() => onPanelChange("pricing")}>Pricing</button>
        </div>
        {panel === "pricing" ? (
          <ProviderPricingPanel provider={provider} />
        ) : detail.enabled ? <>
          <div className="spend-toolbar">
            <span className="range-label">{rangeLabel}</span>
            <div className="range-pills" role="tablist" aria-label="Spend range">
              {spendRanges.map((entry) => (
                <button key={entry.id} role="tab" aria-selected={range === entry.id} className={range === entry.id ? "active" : ""} onClick={() => setRange(entry.id)}>{entry.label}</button>
              ))}
            </div>
          </div>
          <div className="spend-metrics">
            <Metric label="Total spend" value={formatCost(totalSpend)} note={detail.costLabel ?? "Known cost in range"} />
            <Metric label="Included" value={formatCost(spendSplit.included)} note={provider === "cursor" ? "Included in plan" : "Not applicable"} />
            <Metric label="On-demand" value={formatCost(spendSplit.onDemand)} note={provider === "cursor" ? "Usage-based overage" : "Calculated local cost"} />
          </div>
          <Card className="usage-chart-card">
            <div className="usage-chart-head">
              <div>
                <h2>Your Usage</h2>
                <p>{subtitle}</p>
              </div>
              <div className="usage-chart-controls">
                <label className="chart-control">
                  <span>Group by</span>
                  <select value={groupBy} onChange={(event) => setGroupBy(event.target.value as SpendGroupBy)} aria-label="Group by">
                    <option value="model">Model</option>
                    <option value="usageType">Usage type</option>
                  </select>
                </label>
                <label className="chart-control">
                  <span>Metric</span>
                  <select value={metric} onChange={(event) => setMetric(event.target.value as SpendMetric)} aria-label="Metric">
                    <option value="spend">Spend</option>
                    <option value="tokens">Tokens</option>
                  </select>
                </label>
              </div>
            </div>
            <ModelSpendChart series={series} />
          </Card>
          <div className="split">
            <Card>
              <div className="section-head"><div><p className="kicker">Models</p><h2>Where spend went</h2></div></div>
              {models.length ? <div className="model-list">{models.map((model) => <div key={model.model}><span>{model.model}</span><strong>{formatTokens(model.tokens)}</strong><small>{formatCost(model.cost)}</small></div>)}</div> : <Empty>No {provider === "cursor" ? "provider-reported Cursor" : `local ${displayProvider(provider)}`} records in this range.</Empty>}
            </Card>
            <Card>
              <div className="section-head"><div><p className="kicker">Provenance</p><h2>Cost confidence</h2></div></div>
              <Provenance records={records} />
            </Card>
          </div>
          <Records records={records} />
        </> : <Card className="provider-disabled-note"><Empty>{displayProvider(provider)} is disabled. Turn it on to refresh usage and show account activity.</Empty></Card>}
      </div>
    </div>
  </section>;
}

function normalizePricingCatalog(raw: unknown): PricingCatalogResponse {
  const object = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  const providersRaw = (object.providers && typeof object.providers === "object" ? object.providers : {}) as Record<string, Record<string, unknown>>;
  const modelsRaw = Array.isArray(object.models) ? object.models : [];
  return {
    source: typeof object.source === "string" ? object.source : "bundled",
    version: typeof object.version === "string" ? object.version : "",
    label: typeof object.label === "string" ? object.label : "Bundled catalog",
    providers: Object.fromEntries(providers.map((id) => {
      const entry = providersRaw[id] ?? {};
      return [id, {
        id,
        name: typeof entry.name === "string" ? entry.name : displayProvider(id),
        hasLocalCatalog: Boolean(entry.hasLocalCatalog),
        note: typeof entry.note === "string" ? entry.note : null,
      }];
    })) as PricingCatalogResponse["providers"],
    models: modelsRaw.map((row): PricingCatalogEntry => {
      const entry = (row && typeof row === "object" ? row : {}) as Record<string, unknown>;
      const provider = (typeof entry.provider === "string" && providers.includes(entry.provider as Provider) ? entry.provider : "codex") as Provider;
      const numberOrNull = (value: unknown) => typeof value === "number" && Number.isFinite(value) ? value : null;
      return {
        id: typeof entry.id === "string" ? entry.id : "unknown",
        displayName: typeof entry.displayName === "string" ? entry.displayName : String(entry.id ?? "Unknown"),
        provider,
        inputPerMillionUSD: typeof entry.inputPerMillionUSD === "number" ? entry.inputPerMillionUSD : 0,
        outputPerMillionUSD: typeof entry.outputPerMillionUSD === "number" ? entry.outputPerMillionUSD : 0,
        cacheReadPerMillionUSD: numberOrNull(entry.cacheReadPerMillionUSD),
        cacheWritePerMillionUSD: numberOrNull(entry.cacheWritePerMillionUSD),
        contextThreshold: numberOrNull(entry.contextThreshold),
        inputAboveThresholdPerMillionUSD: numberOrNull(entry.inputAboveThresholdPerMillionUSD),
        outputAboveThresholdPerMillionUSD: numberOrNull(entry.outputAboveThresholdPerMillionUSD),
        cacheReadAboveThresholdPerMillionUSD: numberOrNull(entry.cacheReadAboveThresholdPerMillionUSD),
        cacheWriteAboveThresholdPerMillionUSD: numberOrNull(entry.cacheWriteAboveThresholdPerMillionUSD),
      };
    }),
    count: typeof object.count === "number" ? object.count : modelsRaw.length,
    refreshed: Boolean(object.refreshed),
    refreshSource: typeof object.refreshSource === "string" ? object.refreshSource : undefined,
  };
}

function ProviderPricingPanel({ provider }: { provider: Provider }) {
  const [catalog, setCatalog] = useState<PricingCatalogResponse | null>(null);
  const [query, setQuery] = useState("");
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadCatalog = useCallback(async (mode: "get" | "refresh" = "get") => {
    if (mode === "refresh") setRefreshing(true);
    else setLoading(true);
    try {
      const raw = mode === "refresh"
        ? await api.request<unknown>("pricing/refresh", { method: "POST", body: "{}" }, { provider })
        : await api.get<unknown>("pricing", { provider });
      setCatalog(normalizePricingCatalog(raw));
      setError(null);
    } catch (exception) {
      setError(exception instanceof Error ? exception.message : "Pricing catalog is unavailable.");
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [provider]);

  useEffect(() => { void loadCatalog("get"); }, [loadCatalog]);

  const providerMeta = catalog?.providers?.[provider];
  const hasLocalCatalog = provider !== "cursor" && (providerMeta?.hasLocalCatalog ?? true);
  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase();
    const rows = (catalog?.models ?? []).filter((row) => row.provider === provider);
    if (!needle) return rows;
    return rows.filter((row) => row.id.toLowerCase().includes(needle) || row.displayName.toLowerCase().includes(needle));
  }, [catalog, provider, query]);

  if (provider === "cursor" || !hasLocalCatalog) {
    return <Card className="pricing-panel">
      <div className="pricing-head">
        <div>
          <p className="kicker">Agent pricing</p>
          <h2>No local catalog</h2>
        </div>
      </div>
      <Empty>
        {providerMeta?.note
          ?? "Cursor spend is provider-reported (chargedCents). PetRunner does not maintain a local rate catalog for Cursor models."}
      </Empty>
    </Card>;
  }

  return <Card className="pricing-panel">
    <div className="pricing-head">
      <div>
        <p className="kicker">Agent pricing</p>
        <h2>{displayProvider(provider)} rates</h2>
        <p className="pricing-label">{catalog?.label ?? (loading ? "Loading catalog…" : "Bundled catalog")}</p>
      </div>
      <div className="pricing-actions">
        <label className="pricing-search">
          <span>Search</span>
          <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Filter models" aria-label="Filter pricing models" />
        </label>
        <button className="refresh" type="button" disabled={loading || refreshing} onClick={() => void loadCatalog("refresh")}>
          {refreshing ? "Refreshing…" : "Refresh prices"}
        </button>
      </div>
    </div>
    {error ? <div className="notice" role="alert"><span>{error}</span><button type="button" onClick={() => void loadCatalog("get")}>Retry</button></div> : null}
    {loading && !catalog ? <Empty>Loading pricing catalog…</Empty> : filtered.length ? (
      <div className="pricing-table-wrap">
        <table className="pricing-table">
          <thead>
            <tr>
              <th scope="col">Model</th>
              <th scope="col">Input / 1M</th>
              <th scope="col">Output / 1M</th>
              <th scope="col">Cache write / 1M</th>
              <th scope="col">Cache read / 1M</th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((row) => (
              <tr key={row.id}>
                <td>
                  <strong>{row.displayName}</strong>
                  <small>{row.id}{row.contextThreshold ? ` · >${row.contextThreshold.toLocaleString()} tok` : ""}</small>
                </td>
                <td>{formatRatePerMillion(row.inputPerMillionUSD)}</td>
                <td>{formatRatePerMillion(row.outputPerMillionUSD)}</td>
                <td>{formatRatePerMillion(row.cacheWritePerMillionUSD)}</td>
                <td>{formatRatePerMillion(row.cacheReadPerMillionUSD)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    ) : <Empty>No models match “{query.trim()}”.</Empty>}
  </Card>;
}

function ModelSpendChart({ series }: { series: SpendSeries }) {
  const width = 720;
  const height = 280;
  const pad = { top: 18, right: 18, bottom: 36, left: 52 };
  const plotW = width - pad.left - pad.right;
  const plotH = height - pad.top - pad.bottom;
  const max = Math.max(1, ...series.days.map((day) => day.total));
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((fraction) => max * fraction);
  const colorFor = (group: string) => modelColors[Math.abs(hashString(group)) % modelColors.length];
  const formatValue = (value: number) => series.metric === "tokens" ? formatTokens(value) : formatCost(value);
  const formatAxis = (value: number) => series.metric === "tokens" ? formatAxisTokens(value) : formatAxisCost(value);
  const axisLabel = series.metric === "tokens" ? "Tokens" : "Spend";
  const emptyLabel = series.metric === "tokens" ? "No tokens in this range yet." : "No spend in this range yet.";
  const dayLabel = (date: string) => {
    const value = new Date(`${date}T12:00:00`);
    return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" }).format(value);
  };
  const todayKey = localDayKey(new Date());
  const [hoverIndex, setHoverIndex] = useState<number | null>(null);
  const breakdown = hoverIndex == null ? null : daySpendBreakdown(series, hoverIndex);
  const dayCount = Math.max(1, series.days.length);
  const slotWidth = plotW / dayCount;
  const barWidth = dayCount === 1
    ? Math.min(96, plotW * 0.28)
    : Math.max(6, Math.min(slotWidth * 0.72, 42));
  const columnX = (index: number) => dayCount === 1
    ? pad.left + (plotW - barWidth) / 2
    : pad.left + index * slotWidth + (slotWidth - barWidth) / 2;
  const columnCenter = (index: number) => columnX(index) + barWidth / 2;
  const columns = series.days.map((day) => {
    let cursorY = pad.top + plotH;
    const segments = series.groups.flatMap((group) => {
      const value = day.byGroup[group] ?? 0;
      if (value <= 0) return [];
      const h = (value / max) * plotH;
      cursorY -= h;
      return [{ group, y: cursorY, h }];
    });
    return { day, segments };
  });
  const pickIndex = (clientX: number, target: SVGSVGElement) => {
    if (dayCount === 1) return 0;
    const rect = target.getBoundingClientRect();
    const x = ((clientX - rect.left) / rect.width) * width;
    const index = Math.floor((x - pad.left) / slotWidth);
    return Math.max(0, Math.min(dayCount - 1, index));
  };

  if (!series.groups.length || series.days.every((day) => day.total <= 0)) {
    return <Empty>{emptyLabel}</Empty>;
  }

  return <div className="usage-chart">
    <div className="usage-chart-plot" onMouseLeave={() => setHoverIndex(null)}>
      <svg
        viewBox={`0 0 ${width} ${height}`}
        role="img"
        aria-label={`${axisLabel} by ${series.groupBy} across days`}
        onMouseMove={(event) => setHoverIndex(pickIndex(event.clientX, event.currentTarget))}
      >
        {ticks.map((tick) => {
          const ty = pad.top + plotH - (tick / max) * plotH;
          return <g key={tick}>
            <line x1={pad.left} x2={width - pad.right} y1={ty} y2={ty} className="chart-grid" />
            <text x={pad.left - 8} y={ty + 4} className="chart-tick" textAnchor="end">{formatAxis(tick)}</text>
          </g>;
        })}
        {hoverIndex != null ? <rect
          className="chart-column-highlight"
          x={columnX(hoverIndex) - 2}
          y={pad.top}
          width={barWidth + 4}
          height={plotH}
          rx="4"
        /> : null}
        {columns.map((column, index) => (
          <g key={column.day.date} className="chart-column">
            {column.segments.map((segment) => (
              <rect
                key={segment.group}
                className="chart-bar"
                x={columnX(index)}
                y={segment.y}
                width={barWidth}
                height={segment.h}
                fill={colorFor(segment.group)}
                rx={Math.min(3, barWidth / 4)}
              />
            ))}
            <rect
              className="chart-column-hit"
              x={dayCount === 1 ? pad.left : pad.left + index * slotWidth}
              y={pad.top}
              width={dayCount === 1 ? plotW : slotWidth}
              height={plotH}
            />
          </g>
        ))}
        {series.days.map((day, index) => {
          const show = series.days.length <= 10 || index === 0 || index === series.days.length - 1 || index % Math.ceil(series.days.length / 7) === 0;
          return show ? <text key={day.date} x={columnCenter(index)} y={height - 12} className="chart-tick" textAnchor="middle">{dayLabel(day.date)}</text> : null;
        })}
        {hoverIndex != null ? <SpendHoverGuide
          x={columnCenter(hoverIndex)}
          padTop={pad.top}
          plotH={plotH}
          isToday={series.days[hoverIndex]?.date === todayKey}
          stacks={columns[hoverIndex].segments.map((segment) => ({ group: segment.group, y: segment.y }))}
          colorFor={colorFor}
        /> : null}
        <text x={14} y={pad.top + plotH / 2} className="chart-axis-label" transform={`rotate(-90 14 ${pad.top + plotH / 2})`}>{axisLabel}</text>
      </svg>
      {breakdown && hoverIndex != null ? <SpendHoverTooltip
        breakdown={breakdown}
        colorFor={colorFor}
        anchorRatio={(columnCenter(hoverIndex) - pad.left) / Math.max(plotW, 1)}
        formatValue={formatValue}
      /> : null}
    </div>
    <ChartLegend groups={series.groups} colorFor={colorFor} />
  </div>;
}

function SpendHoverGuide({
  x, padTop, plotH, isToday, stacks, colorFor,
}: {
  x: number;
  padTop: number;
  plotH: number;
  isToday: boolean;
  stacks: { group: string; y: number }[];
  colorFor: (group: string) => string;
}) {
  return <g className="chart-hover-guide" pointerEvents="none">
    <line x1={x} x2={x} y1={padTop} y2={padTop + plotH} className="chart-hover-line" />
    {isToday ? <g transform={`translate(${x}, ${Math.max(10, padTop - 4)})`}>
      <rect x={-22} y={-14} width={44} height={18} rx={9} className="chart-today-badge" />
      <text x={0} y={-1} textAnchor="middle" className="chart-today-label">Today</text>
    </g> : null}
    {stacks.map((point) => (
      <circle key={point.group} cx={x} cy={point.y} r={4} fill={colorFor(point.group)} className="chart-hover-dot" />
    ))}
  </g>;
}

function SpendHoverTooltip({
  breakdown, colorFor, anchorRatio, formatValue,
}: {
  breakdown: DaySpendBreakdown;
  colorFor: (group: string) => string;
  anchorRatio: number;
  formatValue: (value: number) => string;
}) {
  const preferLeft = anchorRatio > 0.58;
  return <div
    className={`spend-tooltip ${preferLeft ? "left" : "right"}`}
    style={{ left: `${Math.min(92, Math.max(8, anchorRatio * 100))}%` }}
    role="tooltip"
  >
    <div className="spend-tooltip-head">
      <strong>{formatSpendDayHeading(breakdown.date)}</strong>
      <span>Daily breakdown</span>
    </div>
    {breakdown.rows.length ? <ul className="spend-tooltip-rows">
      {breakdown.rows.map((row) => (
        <li key={row.group}>
          <i style={{ background: colorFor(row.group) }} aria-hidden="true" />
          <em>{row.group}</em>
          <span>{formatValue(row.amount)} <small>{row.percent.toFixed(1)}%</small></span>
        </li>
      ))}
    </ul> : <p className="spend-tooltip-empty">No usage this day</p>}
    <div className="spend-tooltip-totals">
      <div><span>Daily total</span><strong>{formatValue(breakdown.dailyTotal)}</strong></div>
      <div><span>Cumulative total</span><strong>{formatValue(breakdown.cumulativeTotal)}</strong></div>
    </div>
  </div>;
}

function ChartLegend({ groups, colorFor }: { groups: string[]; colorFor: (group: string) => string }) {
  return <div className="chart-legend" aria-label="Series">
    {groups.map((group) => <span key={group}><i style={{ background: colorFor(group) }} /><em>{group}</em></span>)}
  </div>;
}

function hashString(value: string) {
  let hash = 0;
  for (let index = 0; index < value.length; index += 1) hash = (hash * 31 + value.charCodeAt(index)) | 0;
  return hash;
}

function formatAxisCost(value: number) {
  if (value >= 10) return `$${value.toFixed(0)}`;
  if (value >= 1) return `$${value.toFixed(1)}`;
  return `$${value.toFixed(2)}`;
}

function formatAxisTokens(value: number) {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(value >= 10_000 ? 0 : 1)}K`;
  return `${Math.round(value)}`;
}

export function ExternalLinks({ links }: { links?: Pick<ProviderInfo, "usageURL" | "statusURL"> }) { return (links?.usageURL || links?.statusURL) ? <div className="external-links" aria-label="Provider links">{links.usageURL && <a href={links.usageURL} target="_blank" rel="noopener noreferrer">Usage Dashboard ↗</a>}{links.statusURL && <a href={links.statusURL} target="_blank" rel="noopener noreferrer">Status Page ↗</a>}</div> : null; }

function defaultProviderInfo(id: Provider): ProviderInfo {
  return {
    id, name: id, enabled: true, connected: false, account: null, email: null, plan: null, organization: null,
    source: null, status: null, updatedAt: null, todayTokens: 0, todayCost: 0, monthCost: 0, sessionCount: 0, costLabel: null,
  };
}

function connectionNote(provider: Provider, info: ProviderInfo, cursor?: AppState["cursor"]): string {
  if (!info.enabled) return "This provider is disabled. PetRunner skips refresh and hides it from overview totals.";
  if (provider === "cursor") {
    if (cursor?.message) return cursor.message;
    return info.connected
      ? "Signed in via Cursor.app local session. Usage is provider-reported when Cursor returns it."
      : "Sign in to Cursor.app so PetRunner can read the local session and fetch provider-reported usage.";
  }
  if (info.connected) return `Signed in via ${info.source ?? "local auth"}. Usage is calculated from local session logs.`;
  return `No local account metadata found yet. Usage still indexes local session logs when available.`;
}
function Provenance({ records }: { records: UsageRecord[] }) { const reported = records.filter((record) => record.provenance === "providerReported").length; const labeled = records.filter((record) => record.cost !== null).length; return <div className="provenance"><strong>{reported ? "Provider-reported usage" : "Calculated estimate"}</strong><p>{reported ? "Cursor costs are shown only when the provider reports an authoritative usage event." : "Prices use the bundled catalog active when each local session was indexed."}</p><small>{labeled} priced records · unknown models remain visible without a price.</small></div>; }

const RECORDS_PAGE_SIZE = 20;

function Records({ records }: { records: UsageRecord[] }) {
  const [page, setPage] = useState(0);
  const pageCount = Math.max(1, Math.ceil(records.length / RECORDS_PAGE_SIZE));
  const safePage = Math.min(page, pageCount - 1);
  const start = safePage * RECORDS_PAGE_SIZE;
  const pageRecords = records.slice(start, start + RECORDS_PAGE_SIZE);
  const end = start + pageRecords.length;
  const showPager = records.length > RECORDS_PAGE_SIZE;
  const datasetKey = `${records.length}:${records[0]?.id ?? ""}:${records[records.length - 1]?.id ?? ""}`;

  useEffect(() => {
    setPage(0);
  }, [datasetKey]);

  return <Card className="records">
    <div className="section-head"><div><p className="kicker">Records</p><h2>Recent activity</h2></div><span>{records.length} records</span></div>
    {records.length ? <>
      {showPager && <div className="records-pager" aria-label="Records pagination">
        <span>{start + 1}–{end} of {records.length}</span>
        <div className="records-pager-actions">
          <button type="button" className="secondary" disabled={safePage <= 0} onClick={() => setPage(safePage - 1)}>Previous</button>
          <button type="button" className="secondary" disabled={safePage >= pageCount - 1} onClick={() => setPage(safePage + 1)}>Next</button>
        </div>
      </div>}
      <div className={`table-wrap${showPager ? " table-wrap-paged" : ""}`}><table><thead><tr><th>Time</th><th>Model</th><th>Tokens</th><th>Cost</th><th>Source</th></tr></thead><tbody>{pageRecords.map((record) => <tr key={record.id}><td>{formatDate(record.occurredAt)}</td><td>{record.model ?? "Unknown"}</td><td>{formatTokens(record.tokens.total)}</td><td>{formatCost(record.cost)}</td><td>{record.provenance === "providerReported" ? "Reported" : record.cost === null ? "Unpriced" : "Calculated"}</td></tr>)}</tbody></table></div>
    </> : <Empty>No usage records match this selection.</Empty>}
  </Card>;
}

export function LiveSessionList({ sessions, error }: { sessions: { id: string; name: string; provider: Provider; status: string; activity: string; updatedAt: string }[]; error: string | null }) { if (error) return <Empty>Live session error: {error}</Empty>; return sessions.length ? <div className="session-rows">{sessions.map((session) => <div key={`${session.provider}:${session.id}`}><span className={`status ${session.status}`} /><div><strong>{session.name}</strong><small>{displayProvider(session.provider)} · {session.activity}</small></div><time>{formatDate(session.updatedAt)}</time></div>)}</div> : <Empty>No live session activity has been received.</Empty>; }

function ProviderBudgetEditor({ provider, budget, onSave }: { provider: Provider; budget?: Budget; onSave: (budget: Budget) => Promise<void> }) {
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [dailyUSD, setDailyUSD] = useState<number | null>(budget?.dailyUSD ?? null);
  const [monthlyUSD, setMonthlyUSD] = useState<number | null>(budget?.monthlyUSD ?? null);
  useEffect(() => {
    setDailyUSD(budget?.dailyUSD ?? null);
    setMonthlyUSD(budget?.monthlyUSD ?? null);
    setMessage(null);
  }, [provider, budget?.dailyUSD, budget?.monthlyUSD]);
  const save = async () => {
    setSaving(true);
    try {
      await onSave({ dailyUSD, monthlyUSD });
      setMessage("Budget saved for this provider.");
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Could not save budget.");
    } finally {
      setSaving(false);
    }
  };
  return (
    <div className="provider-budget">
      <p className="kicker">Cost monitor</p>
      <h2>Budget for {displayProvider(provider)}</h2>
      <p>Local alerts only. Leave a field blank to disable that limit.</p>
      <div className="provider-budget-fields">
        <label>Daily USD
          <input type="number" min="0" step="0.01" value={dailyUSD ?? ""} onChange={(event) => setDailyUSD(event.target.value === "" ? null : Number(event.target.value))} />
        </label>
        <label>Monthly USD
          <input type="number" min="0" step="0.01" value={monthlyUSD ?? ""} onChange={(event) => setMonthlyUSD(event.target.value === "" ? null : Number(event.target.value))} />
        </label>
      </div>
      <button type="button" className="secondary" onClick={() => void save()} disabled={saving}>{saving ? "Saving…" : "Save budget"}</button>
      {message ? <p className="form-message" role="status">{message}</p> : null}
    </div>
  );
}

function Bars({ buckets }: { buckets: UsageResponse["buckets"] }) { const data = buckets.slice(-14); const max = Math.max(1, ...data.map((bucket) => bucket.tokens)); return data.length ? <div className="bars" aria-label="Daily token usage">{data.map((bucket) => <div key={bucket.date} title={`${bucket.date}: ${formatTokens(bucket.tokens)}`}><i style={{ height: `${Math.max(5, bucket.tokens / max * 100)}%` }} /><span>{bucket.date.slice(5)}</span></div>)}</div> : <Empty>No daily usage records in this range.</Empty>; }
function errorMessage(value: unknown, fallback: string) { return value instanceof Error ? value.message : fallback; }

const rootElement = document.getElementById("root");
if (rootElement) createRoot(rootElement).render(<App />);
