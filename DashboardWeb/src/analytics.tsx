import { useEffect, useMemo, useState } from "react";
import { displayProvider, formatCost, formatDuration, formatPct, formatRelative, formatTokens } from "./format";
import { ProviderIcon } from "./icons";
import type { AnalyticsTab } from "./routing";
import { providers, type Provider, type UsageModel, type UsageProject, type UsageSession } from "./types";

export type { AnalyticsTab };

const ANALYTICS_TABS: { id: AnalyticsTab; label: string }[] = [
  { id: "sessions", label: "Sessions" },
  { id: "projects", label: "Projects" },
  { id: "models", label: "Models" },
];

export function AnalyticsPageTabs({
  active,
  onChange,
}: {
  active: AnalyticsTab;
  onChange: (tab: AnalyticsTab) => void;
}) {
  return (
    <div className="analytics-page-tabs" role="tablist" aria-label="Analytics views">
      {ANALYTICS_TABS.map((tab) => (
        <button
          key={tab.id}
          type="button"
          role="tab"
          aria-selected={active === tab.id}
          className={active === tab.id ? "active" : ""}
          onClick={() => onChange(tab.id)}
        >
          {tab.label}
        </button>
      ))}
    </div>
  );
}

const SESSIONS_PAGE_SIZE = 10;

function Empty({ children }: { children: React.ReactNode }) {
  return <div className="empty">{children}</div>;
}

function shortHash(value: string, length = 12) {
  const stripped = value.replace(/^(conv|gap):/, "");
  return stripped.length <= length ? stripped : stripped.slice(0, length);
}

function ProviderTabs({
  active,
  counts,
  onChange,
}: {
  active: Provider;
  counts: Record<Provider, number>;
  onChange: (provider: Provider) => void;
}) {
  return (
    <div className="provider-tabs session-provider-tabs" role="tablist" aria-label="Analytics provider">
      {providers.map((provider) => (
        <button
          key={provider}
          type="button"
          role="tab"
          aria-selected={active === provider}
          className={active === provider ? "active" : ""}
          onClick={() => onChange(provider)}
        >
          <span className={`provider-mark tab ${provider}`} aria-hidden="true"><ProviderIcon provider={provider} /></span>
          {displayProvider(provider)}
          <em>{counts[provider] ?? 0}</em>
        </button>
      ))}
    </div>
  );
}

export function AnalyticsSessions({
  sessions,
  error,
  provider,
  onProviderChange,
}: {
  sessions: UsageSession[];
  error: string | null;
  provider: Provider;
  onProviderChange: (provider: Provider) => void;
}) {
  const counts = useMemo(
    () => Object.fromEntries(providers.map((entry) => [entry, sessions.filter((session) => session.provider === entry).length])) as Record<Provider, number>,
    [sessions],
  );
  const filtered = useMemo(() => sessions.filter((session) => session.provider === provider), [sessions, provider]);
  const [page, setPage] = useState(0);
  const pageCount = Math.max(1, Math.ceil(filtered.length / SESSIONS_PAGE_SIZE));
  const safePage = Math.min(page, pageCount - 1);
  const start = safePage * SESSIONS_PAGE_SIZE;
  const pageSessions = filtered.slice(start, start + SESSIONS_PAGE_SIZE);
  const end = start + pageSessions.length;
  const showPager = filtered.length > SESSIONS_PAGE_SIZE;
  const datasetKey = `${provider}:${filtered.length}:${filtered[0]?.id ?? ""}:${filtered[filtered.length - 1]?.id ?? ""}`;

  useEffect(() => {
    setPage(0);
  }, [datasetKey]);

  return (
    <div className="analytics-panel">
      <div className="section-head">
        <div>
          <p className="kicker">Analytics</p>
          <h1>Sessions</h1>
        </div>
        <span className="range-label">{filtered.length} sessions · sorted by most recent activity</span>
      </div>
      <div className="session-filters">
        <ProviderTabs active={provider} counts={counts} onChange={onProviderChange} />
      </div>
      {error ? <Empty>Session indexing error: {error}</Empty> : null}
      {!error && !filtered.length ? (
        <Empty>No {displayProvider(provider)} sessions yet. Sessions group usage records by conversation (or Cursor time-gap clusters).</Empty>
      ) : null}
      {filtered.length ? (
        <div className="card analytics-table-wrap">
          {showPager ? (
            <div className="records-pager sessions-pager" aria-label="Sessions pagination">
              <span>{start + 1}–{end} of {filtered.length}</span>
              <div className="records-pager-actions">
                <button type="button" className="secondary" disabled={safePage <= 0} onClick={() => setPage(safePage - 1)}>Previous</button>
                <button type="button" className="secondary" disabled={safePage >= pageCount - 1} onClick={() => setPage(safePage + 1)}>Next</button>
              </div>
            </div>
          ) : null}
          <table className="analytics-table">
            <thead>
              <tr>
                <th>Session</th>
                <th>Project</th>
                <th>Model(s)</th>
                <th className="num">Requests</th>
                <th className="num">Tokens</th>
                <th className="num">Cost</th>
                <th className="num">Duration</th>
                <th className="num">Last activity</th>
              </tr>
            </thead>
            <tbody>
              {pageSessions.map((session) => (
                <tr key={`${session.provider}:${session.id}`}>
                  <td>
                    <div className="session-title" title={session.title}>{session.title}</div>
                    <div className="session-id">{shortHash(session.id)}</div>
                  </td>
                  <td title={session.projectPath ?? undefined}>{session.project ?? "—"}</td>
                  <td className="models-cell">{session.models.join(", ") || "—"}</td>
                  <td className="num">{session.requestCount}</td>
                  <td className="num">{formatTokens(session.tokens.total)}</td>
                  <td className="num cost">{formatCost(session.knownCostUSD)}</td>
                  <td className="num muted">{formatDuration(session.durationSeconds)}</td>
                  <td className="num muted">{formatRelative(session.updatedAt)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : null}
    </div>
  );
}

export function AnalyticsProjects({
  projects,
  error,
  provider,
  onProviderChange,
}: {
  projects: UsageProject[];
  error: string | null;
  provider: Provider;
  onProviderChange: (provider: Provider) => void;
}) {
  const counts = useMemo(
    () => Object.fromEntries(providers.map((entry) => [entry, projects.filter((project) => project.provider === entry).length])) as Record<Provider, number>,
    [projects],
  );
  const filtered = useMemo(() => projects.filter((project) => project.provider === provider), [projects, provider]);
  const totalCost = filtered.reduce((sum, project) => sum + project.knownCostUSD, 0);

  return (
    <div className="analytics-panel">
      <div className="section-head">
        <div>
          <p className="kicker">Analytics</p>
          <h1>Projects</h1>
        </div>
        <span className="range-label">{filtered.length} projects · sorted by spend</span>
      </div>
      <div className="session-filters">
        <ProviderTabs active={provider} counts={counts} onChange={onProviderChange} />
      </div>
      {error ? <Empty>Project indexing error: {error}</Empty> : null}
      {!error && !filtered.length ? <Empty>No {displayProvider(provider)} projects yet.</Empty> : null}
      <div className="analytics-card-grid">
        {filtered.map((project) => {
          const share = totalCost > 0 ? project.knownCostUSD / totalCost : 0;
          return (
            <article key={`${project.provider}:${project.id}`} className="card analytics-project-card">
              <div className="project-card-head">
                <div>
                  <strong>{project.name}</strong>
                  <small title={project.path ?? undefined}>{project.path ?? "Path unknown"}</small>
                </div>
                <span className="cost">{formatCost(project.knownCostUSD)}</span>
              </div>
              <div className="project-stats">
                <div><span>Sessions</span><strong>{project.sessionCount}</strong></div>
                <div><span>Requests</span><strong>{project.requestCount}</strong></div>
                <div><span>Tokens</span><strong>{formatTokens(project.tokens.total)}</strong></div>
              </div>
              <div className="share-bar"><i style={{ width: `${Math.max(2, share * 100)}%` }} /></div>
              <div className="project-card-foot">
                <span>last activity {formatRelative(project.updatedAt)}</span>
                <span className="models-cell">{project.models.join(", ") || "—"}</span>
              </div>
            </article>
          );
        })}
      </div>
    </div>
  );
}

export function AnalyticsModels({
  models,
  error,
  provider,
  onProviderChange,
}: {
  models: UsageModel[];
  error: string | null;
  provider: Provider;
  onProviderChange: (provider: Provider) => void;
}) {
  const counts = useMemo(
    () => Object.fromEntries(providers.map((entry) => [entry, models.filter((model) => model.provider === entry).length])) as Record<Provider, number>,
    [models],
  );
  const filtered = useMemo(() => models.filter((model) => model.provider === provider), [models, provider]);

  return (
    <div className="analytics-panel">
      <div className="section-head">
        <div>
          <p className="kicker">Analytics</p>
          <h1>Models</h1>
        </div>
        <span className="range-label">{filtered.length} model(s) used in total</span>
      </div>
      <div className="session-filters">
        <ProviderTabs active={provider} counts={counts} onChange={onProviderChange} />
      </div>
      {error ? <Empty>Model indexing error: {error}</Empty> : null}
      {!error && !filtered.length ? <Empty>No {displayProvider(provider)} model usage yet.</Empty> : null}
      <div className="analytics-card-grid">
        {filtered.map((model) => (
          <article key={`${model.provider}:${model.model}`} className="card analytics-model-card">
            <div className="model-card-head">
              <div>
                <strong>
                  {model.displayName}
                  {!model.pricingResolved ? <em className="fallback-pill">fallback price</em> : null}
                </strong>
                <small>{model.model}</small>
              </div>
            </div>
            <div className="model-hero">{formatCost(model.knownCostUSD)}</div>
            <p className="model-meta">{formatPct(model.costShare, 0)} of total spend · {formatTokens(model.tokens.total)} tokens</p>
            <ProgressRow label="Cost share" value={model.costShare} tone="brand" right={formatPct(model.costShare)} />
            <ProgressRow label="Tokens share" value={model.tokenShare} tone="tokens" right={formatPct(model.tokenShare)} />
            <ProgressRow label="Cache hit" value={model.cacheHitRatio} tone="success" right={formatPct(model.cacheHitRatio, 0)} />
            <dl className="model-stats">
              <div><dt>Requests</dt><dd>{model.requestCount}</dd></div>
              <div><dt>Saved by cache</dt><dd className="saved">{formatCost(model.cacheSavedUSD)}</dd></div>
              {model.pricingResolved ? (
                <>
                  <div><dt>Input / 1M</dt><dd>{formatCost(model.inputPerMillionUSD)}</dd></div>
                  <div><dt>Output / 1M</dt><dd>{formatCost(model.outputPerMillionUSD)}</dd></div>
                  <div><dt>Cache read / 1M</dt><dd>{formatCost(model.cacheReadPerMillionUSD)}</dd></div>
                </>
              ) : null}
            </dl>
          </article>
        ))}
      </div>
    </div>
  );
}

function ProgressRow({
  label,
  value,
  right,
  tone,
}: {
  label: string;
  value: number;
  right: string;
  tone: "brand" | "tokens" | "success";
}) {
  return (
    <div className="progress-row">
      <div className="progress-row-label"><span>{label}</span><span>{right}</span></div>
      <div className="share-bar"><i className={`tone-${tone}`} style={{ width: `${Math.max(0, Math.min(1, value)) * 100}%` }} /></div>
    </div>
  );
}

