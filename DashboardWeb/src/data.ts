import type { ActivityStats, AppState, LiveSession, MonitorProviderOption, MonitorSettings, Provider, ProviderInfo, SessionTimelineEntry, Tokens, UsageModel, UsageProject, UsageRecord, UsageResponse, UsageSession } from "./types";

const asObject = (value: unknown): Record<string, unknown> => value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
const finite = (value: unknown): number => {
  const number = typeof value === "number" ? value : typeof value === "string" ? Number(value) : NaN;
  return Number.isFinite(number) ? number : 0;
};
const string = (value: unknown): string | null => typeof value === "string" && value.trim() ? value : null;
const provider = (value: unknown): Provider => value === "claude" || value === "cursor" ? value : "codex";

export function tokens(value: unknown): Tokens {
  const input = asObject(value);
  const rawTotal = finite(input.total);
  const parsed = { input: finite(input.input), cachedInput: finite(input.cachedInput), cacheCreation: finite(input.cacheCreation), cacheCreation1h: finite(input.cacheCreation1h), output: finite(input.output), reasoning: finite(input.reasoning), total: rawTotal };
  return { ...parsed, total: parsed.total || parsed.input + parsed.cachedInput + parsed.cacheCreation + parsed.output };
}

export function normalizeUsage(value: unknown): UsageResponse {
  const object = asObject(value);
  const total = asObject(object.totals);
  const records = Array.isArray(object.records) ? object.records.map((value, index): UsageRecord => {
    const record = asObject(value);
    const cost = record.cost;
    const costObject = asObject(cost);
    const usageTypeRaw = string(record.usageType);
    return {
      id: string(record.id) ?? `record-${index}`,
      provider: provider(record.provider),
      sessionID: string(record.sessionID) ?? "unknown",
      occurredAt: string(record.occurredAt) ?? "",
      model: string(record.model),
      tokens: tokens(record.tokens),
      cost: cost === null || cost === undefined ? null : finite(costObject.usd ?? cost),
      provenance: string(record.provenance ?? costObject.provenance),
      pricingVersion: string(record.pricingVersion ?? costObject.pricingVersion),
      usageType: usageTypeRaw === "included" || usageTypeRaw === "onDemand" ? usageTypeRaw : null,
    };
  }) : [];
  const buckets = Array.isArray(object.buckets) ? object.buckets.map((value) => {
    const bucket = asObject(value);
    return { date: string(bucket.date) ?? "", tokens: finite(bucket.tokens), cost: finite(bucket.cost) };
  }) : [];
  const rawProviders = asObject(object.providers);
  const providerSummaries = Object.fromEntries(["claude", "codex", "cursor"].map((name) => {
    const summary = asObject(rawProviders[name]);
    const models = Array.isArray(summary.models) ? summary.models.map((value) => {
      const model = asObject(value);
      return { model: string(model.model) ?? "Unknown model", tokens: finite(model.tokens), cost: finite(model.cost), recordCount: finite(model.recordCount) };
    }) : [];
    return [name, { tokens: finite(summary.tokens), cost: finite(summary.cost), sessions: finite(summary.sessions), recordCount: finite(summary.recordCount), models }];
  }));
  return { totals: { tokens: finite(total.tokens), input: finite(total.input), cachedInput: finite(total.cachedInput), output: finite(total.output), cost: finite(total.cost), sessions: finite(total.sessions), recordCount: finite(total.recordCount) || records.length }, providers: providerSummaries, records, buckets, truncated: Boolean(object.truncated) };
}

export function normalizeState(value: unknown): AppState {
  const object = asObject(value); const kpis = asObject(object.kpis); const settings = asObject(object.settings);
  const budgets = Object.fromEntries(["claude", "codex", "cursor"].map((name) => {
    const budget = asObject(asObject(settings.budgets)[name]);
    return [name, { dailyUSD: budget.dailyUSD == null ? null : finite(budget.dailyUSD), monthlyUSD: budget.monthlyUSD == null ? null : finite(budget.monthlyUSD) }];
  }));
  const cursor = asObject(object.cursor);
  const rawProviders = Array.isArray(object.providers) ? object.providers : [];
  const providerInfos = rawProviders.reduce<Partial<Record<Provider, ProviderInfo>>>((infos, value) => {
    const entry = asObject(value);
    const name = provider(entry.provider ?? entry.id);
    const enabled = entry.enabled === undefined ? true : Boolean(entry.enabled);
    infos[name] = {
      id: name,
      name: string(entry.name) ?? name,
      enabled,
      connected: Boolean(entry.connected),
      account: string(entry.account) ?? string(entry.email) ?? string(entry.displayName),
      email: string(entry.email),
      plan: string(entry.plan),
      organization: string(entry.organization),
      source: string(entry.source),
      status: string(entry.status),
      updatedAt: string(entry.updatedAt),
      todayTokens: finite(entry.todayTokens),
      todayCost: finite(entry.todayCost),
      monthCost: finite(entry.monthCost),
      sessionCount: finite(entry.sessionCount),
      costLabel: string(entry.costLabel),
      usageURL: safeURL(entry.usageURL),
      statusURL: safeURL(entry.statusURL),
    };
    return infos;
  }, {});
  for (const name of ["claude", "codex", "cursor"] as const) {
    if (!providerInfos[name]) {
      providerInfos[name] = {
        id: name, name, enabled: true, connected: false, account: null, email: null, plan: null, organization: null,
        source: null, status: null, updatedAt: null, todayTokens: 0, todayCost: 0, monthCost: 0, sessionCount: 0, costLabel: null,
      };
    }
  }
  const pets = Array.isArray(object.pets) ? object.pets.flatMap((value) => {
    const pet = asObject(value);
    const id = string(pet.id);
    if (!id) return [];
    const version = finite(pet.version) === 2 ? 2 as const : 1 as const;
    const tags = Array.isArray(pet.tags) ? pet.tags.map(string).filter((tag): tag is string => Boolean(tag)) : [];
    const kind = string(pet.kind);
    if (kind && !tags.includes(kind)) tags.push(kind);
    if (!tags.includes("animated")) tags.unshift("animated");
    return [{
      id,
      name: string(pet.name) ?? string(pet.displayName) ?? id,
      description: string(pet.description),
      version,
      author: string(pet.author),
      tags,
      packageVersion: string(pet.packageVersion),
      kind,
    }];
  }) : [];
  const pet = asObject(object.pet);
  const autonomy = asObject(pet.autonomy);
  const capabilities = asObject(object.capabilities);
  const failures = Array.isArray(object.failures) ? object.failures.flatMap((value) => {
    const failure = asObject(value);
    const id = string(failure.id);
    const message = string(failure.message);
    return id && message ? [{ id, message }] : [];
  }) : [];
  return {
    platform: string(object.platform) ?? undefined,
    kpis: { todayTokens: finite(kpis.todayTokens), todayCost: finite(kpis.todayCost), cacheRatio: finite(kpis.cacheRatio), monthCost: finite(kpis.monthCost), sessionCount: finite(kpis.sessionCount) },
    settings: {
      budgets,
      showStatusItem: settings.showStatusItem === undefined ? true : Boolean(settings.showStatusItem),
      petsDirectory: string(settings.petsDirectory),
      petsDirectorySource: string(settings.petsDirectorySource),
      petsDirectoryEditable: settings.petsDirectoryEditable === undefined
        ? Boolean(capabilities.petsDirectoryBrowse)
        : Boolean(settings.petsDirectoryEditable),
    },
    cursor: {
      connected: Boolean(cursor.connected ?? settings.cursorConnected),
      status: string(cursor.status) ?? undefined,
      message: string(cursor.message) ?? undefined,
    },
    providers: providerInfos,
    pets,
    pet: {
      selectedID: string(pet.selectedID),
      width: finite(pet.width) || 112,
      autonomy: {
        enabled: Boolean(autonomy.enabled),
        minimumWait: finite(autonomy.minimumWait) || 8,
        maximumWait: finite(autonomy.maximumWait) || 24,
        actions: Array.isArray(autonomy.actions) ? autonomy.actions.map(string).filter((action): action is string => Boolean(action)) : [],
      },
    },
    monitor: normalizeMonitor(object.monitor),
    failures,
    capabilities: {
      petImport: capabilities.petImport === undefined ? true : Boolean(capabilities.petImport),
      petRemove: capabilities.petRemove === undefined ? true : Boolean(capabilities.petRemove),
      statusItem: Boolean(capabilities.statusItem),
      petPreview: capabilities.petPreview === undefined ? true : Boolean(capabilities.petPreview),
      petsDirectory: capabilities.petsDirectory === undefined ? true : Boolean(capabilities.petsDirectory),
      petsDirectoryBrowse: Boolean(capabilities.petsDirectoryBrowse ?? settings.petsDirectoryEditable),
      agentMonitor: capabilities.agentMonitor === undefined ? true : Boolean(capabilities.agentMonitor),
    },
  };
}

export function normalizeMonitor(value: unknown): MonitorSettings {
  const object = asObject(value);
  const rawProviders = Array.isArray(object.providers) ? object.providers : [];
  const providers = rawProviders.flatMap((entry): MonitorProviderOption[] => {
    const item = asObject(entry);
    const id = string(item.id);
    if (id !== "claude" && id !== "codex" && id !== "cursor") return [];
    const color = asObject(item.headerColor);
    return [{
      id,
      name: string(item.name) ?? id.toUpperCase(),
      detected: Boolean(item.detected),
      hooksDirectory: string(item.hooksDirectory) ?? `~/.${id === "claude" ? "claude" : id === "codex" ? "codex" : "cursor"}`,
      configPath: string(item.configPath) ?? (id === "claude" ? "~/.claude/settings.json" : `~/.${id}/hooks.json`),
      headerColor: color.red == null && color.green == null && color.blue == null
        ? undefined
        : { red: finite(color.red), green: finite(color.green), blue: finite(color.blue) },
    }];
  });
  const fallback: MonitorProviderOption[] = providers.length ? providers : (["claude", "codex", "cursor"] as const).map((id) => ({
    id,
    name: id.toUpperCase(),
    detected: false,
    hooksDirectory: `~/.${id}`,
    configPath: id === "claude" ? "~/.claude/settings.json" : `~/.${id}/hooks.json`,
  }));
  const rawProvider = string(object.provider);
  const provider = rawProvider === "claude" || rawProvider === "codex" || rawProvider === "cursor" ? rawProvider : null;
  const visibleFields = Array.isArray(object.visibleFields)
    ? object.visibleFields.map(string).filter((field): field is string => Boolean(field))
    : ["model", "job", "sessionName", "cost"];
  return {
    enabled: Boolean(object.enabled),
    provider,
    visibleFields,
    providers: fallback,
  };
}

export function normalizeLiveSessions(value: unknown): LiveSession[] {
  const object = asObject(value); const source = Array.isArray(object.sessions) ? object.sessions : [];
  return source.map((value, index) => {
    const session = asObject(value);
    return { id: string(session.id) ?? String(index), name: string(session.name) ?? "Unnamed session", provider: provider(session.provider), model: string(session.model), status: string(session.status) ?? "unknown", activity: string(session.activity) ?? "No activity", updatedAt: string(session.updatedAt) ?? "", cost: session.cost == null ? null : finite(session.cost) };
  });
}

export function normalizeUsageSessions(value: unknown): UsageSession[] {
  const object = asObject(value); const source = Array.isArray(object.sessions) ? object.sessions : [];
  return source.flatMap((value, index) => {
    try { return [normalizeUsageSession(value, index)]; } catch { return []; }
  });
}

export function normalizeUsageSession(value: unknown, index = 0): UsageSession {
  const session = asObject(value);
  const rawProvider = session.provider;
  if (rawProvider !== "claude" && rawProvider !== "codex" && rawProvider !== "cursor") {
    throw new Error("Sessions require a known provider.");
  }
  const rawTimeline = Array.isArray(session.records) ? session.records : Array.isArray(session.timeline) ? session.timeline : undefined;
  const records = rawTimeline?.map(normalizeTimelineEntry);
  return {
    id: string(session.id) ?? String(index), provider: rawProvider,
    title: string(session.title) ?? "Untitled session", project: string(session.project),
    projectPath: string(session.projectPath),
    startedAt: string(session.startedAt) ?? "", updatedAt: string(session.updatedAt) ?? "",
    durationSeconds: finite(session.durationSeconds), models: Array.isArray(session.models) ? session.models.map(string).filter((model): model is string => Boolean(model)) : [],
    primaryModel: string(session.primaryModel), requestCount: finite(session.requestCount), tokens: tokens(session.tokens),
    knownCostUSD: session.knownCostUSD == null ? null : finite(session.knownCostUSD), unpricedRecordCount: finite(session.unpricedRecordCount), provenance: string(session.provenance), records,
  };
}

export function normalizeUsageProjects(value: unknown): UsageProject[] {
  const object = asObject(value);
  const source = Array.isArray(object.projects) ? object.projects : [];
  return source.flatMap((entry, index) => {
    const project = asObject(entry);
    const rawProvider = project.provider;
    if (rawProvider !== "claude" && rawProvider !== "codex" && rawProvider !== "cursor") return [];
    return [{
      id: string(project.id) ?? String(index),
      provider: rawProvider,
      name: string(project.name) ?? "Unknown project",
      path: string(project.path),
      sessionCount: finite(project.sessionCount),
      requestCount: finite(project.requestCount),
      tokens: tokens(project.tokens),
      knownCostUSD: finite(project.knownCostUSD),
      updatedAt: string(project.updatedAt) ?? "",
      models: Array.isArray(project.models) ? project.models.map(string).filter((model): model is string => Boolean(model)) : [],
    }];
  });
}

export function normalizeUsageModels(value: unknown): UsageModel[] {
  const object = asObject(value);
  const source = Array.isArray(object.models) ? object.models : [];
  return source.flatMap((entry, index) => {
    const model = asObject(entry);
    const rawProvider = model.provider;
    if (rawProvider !== "claude" && rawProvider !== "codex" && rawProvider !== "cursor") return [];
    const id = string(model.model) ?? string(model.id) ?? String(index);
    return [{
      id,
      provider: rawProvider,
      model: id,
      displayName: string(model.displayName) ?? id,
      requestCount: finite(model.requestCount),
      tokens: tokens(model.tokens),
      knownCostUSD: finite(model.knownCostUSD),
      cacheSavedUSD: finite(model.cacheSavedUSD),
      costShare: finite(model.costShare),
      tokenShare: finite(model.tokenShare),
      cacheHitRatio: finite(model.cacheHitRatio),
      pricingResolved: Boolean(model.pricingResolved),
      inputPerMillionUSD: model.inputPerMillionUSD == null ? null : finite(model.inputPerMillionUSD),
      outputPerMillionUSD: model.outputPerMillionUSD == null ? null : finite(model.outputPerMillionUSD),
      cacheReadPerMillionUSD: model.cacheReadPerMillionUSD == null ? null : finite(model.cacheReadPerMillionUSD),
    }];
  });
}

function normalizeHeatmap(value: unknown): number[][] {
  const rows = Array.isArray(value) ? value : [];
  return Array.from({ length: 7 }, (_, dow) => {
    const row = Array.isArray(rows[dow]) ? rows[dow] as unknown[] : [];
    return Array.from({ length: 24 }, (_, hour) => finite(row[hour]));
  });
}

export function normalizeActivity(value: unknown): ActivityStats {
  const object = asObject(value);
  const comparisonObject = asObject(object.comparison);
  const comparison = string(comparisonObject.refKey) && string(comparisonObject.label)
    ? {
      refKey: string(comparisonObject.refKey)!,
      label: string(comparisonObject.label)!,
      multiplier: finite(comparisonObject.multiplier),
    }
    : null;
  const peakHourRaw = Object.prototype.hasOwnProperty.call(object, "peakHour")
    ? (typeof object.peakHour === "number" ? object.peakHour : finite(object.peakHour))
    : -1;
  return {
    activeDays: finite(object.activeDays),
    currentStreak: finite(object.currentStreak),
    longestStreak: finite(object.longestStreak),
    peakHour: peakHourRaw >= 0 && peakHourRaw <= 23 ? Math.trunc(peakHourRaw) : -1,
    requestCount: finite(object.requestCount),
    totalTokens: finite(object.totalTokens),
    heatmap: normalizeHeatmap(object.heatmap),
    heatmapMax: finite(object.heatmapMax),
    tokenHeatmap: normalizeHeatmap(object.tokenHeatmap),
    comparison,
  };
}

/** @deprecated Prefer normalizeUsageSessions */
export const normalizeHistoricalSessions = normalizeUsageSessions;
/** @deprecated Prefer normalizeUsageSession */
export const normalizeHistoricalSession = normalizeUsageSession;

function normalizeTimelineEntry(value: unknown): SessionTimelineEntry {
  const entry = asObject(value);
  return { occurredAt: string(entry.occurredAt) ?? "", model: string(entry.model), tokens: tokens(entry.tokens), knownCostUSD: entry.knownCostUSD == null ? null : finite(entry.knownCostUSD), provenance: string(entry.provenance) };
}

/** Group sessions by local calendar day of last activity (newest day first). */
export function groupSessionsByDay(sessions: UsageSession[]): { day: string; dayKey: string; sessions: UsageSession[]; knownCostUSD: number }[] {
  const groups = new Map<string, { day: string; dayKey: string; sessions: UsageSession[] }>();
  for (const session of sessions) {
    const key = localDayKey(session.updatedAt);
    const group = groups.get(key) ?? { day: localDay(session.updatedAt), dayKey: key, sessions: [] };
    group.sessions.push(session);
    groups.set(key, group);
  }
  return [...groups.entries()]
    .sort(([a], [b]) => b.localeCompare(a))
    .map(([, group]) => ({
      day: group.day,
      dayKey: group.dayKey,
      sessions: group.sessions.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt)),
      knownCostUSD: group.sessions.reduce((total, session) => total + (session.knownCostUSD ?? 0), 0),
    }));
}

/** @deprecated Prefer groupSessionsByDay */
export function groupHistoricalSessions(sessions: UsageSession[]): { day: string; sessions: UsageSession[] }[] {
  return groupSessionsByDay(sessions).map(({ day, sessions }) => ({ day, sessions }));
}

export function localDay(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.valueOf())) return "Unknown date";
  return new Intl.DateTimeFormat(undefined, { year: "numeric", month: "short", day: "numeric" }).format(date);
}

export function localDayKey(value: string | Date): string {
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.valueOf())) return "";
  return [date.getFullYear(), String(date.getMonth() + 1).padStart(2, "0"), String(date.getDate()).padStart(2, "0")].join("-");
}

export type ProviderSpendRange = "1d" | "7d" | "30d" | "mtd";
export type SpendGroupBy = "model" | "usageType";
export type SpendMetric = "spend" | "tokens";

export function apiRangeForProviderSpend(range: ProviderSpendRange): string {
  switch (range) {
    case "1d": return "today";
    case "mtd": return "month";
    default: return range;
  }
}

export function providerDayKeys(range: ProviderSpendRange, now: Date = new Date()): string[] {
  const end = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  let start = new Date(end);
  switch (range) {
    case "1d":
      break;
    case "7d":
      start.setDate(end.getDate() - 6);
      break;
    case "30d":
      start.setDate(end.getDate() - 29);
      break;
    case "mtd":
      start = new Date(end.getFullYear(), end.getMonth(), 1);
      break;
  }
  const keys: string[] = [];
  for (let cursor = new Date(start); cursor <= end; cursor.setDate(cursor.getDate() + 1)) {
    keys.push(localDayKey(cursor));
  }
  return keys;
}

export function formatDayRangeLabel(dayKeys: string[]): string {
  if (!dayKeys.length) return "";
  const first = new Date(`${dayKeys[0]}T12:00:00`);
  const last = new Date(`${dayKeys[dayKeys.length - 1]}T12:00:00`);
  const format = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" });
  if (dayKeys.length === 1) return format.format(first);
  return `${format.format(first)} – ${format.format(last)}`;
}

export type SpendDay = { date: string; byGroup: Record<string, number>; total: number };
export type SpendSeries = { groups: string[]; days: SpendDay[]; metric: SpendMetric; groupBy: SpendGroupBy };
export type ModelSpendDay = { date: string; byModel: Record<string, number>; total: number };
export type ModelSpendSeries = { models: string[]; days: ModelSpendDay[] };
export type DaySpendBreakdownRow = { group: string; amount: number; percent: number };
export type DaySpendBreakdown = {
  date: string;
  rows: DaySpendBreakdownRow[];
  dailyTotal: number;
  cumulativeTotal: number;
};

export function usageTypeLabel(value: string | null | undefined): string {
  if (value === "included") return "Included";
  if (value === "onDemand") return "On-demand";
  return "On-demand";
}

export function spendGroupKey(record: UsageRecord, groupBy: SpendGroupBy): string {
  if (groupBy === "usageType") {
    return usageTypeLabel(record.usageType ?? (record.provider === "cursor" ? "included" : "onDemand"));
  }
  return record.model?.trim() || "Unknown model";
}

export function spendMetricValue(record: UsageRecord, metric: SpendMetric): number {
  if (metric === "tokens") return Math.max(0, record.tokens.total);
  return Math.max(0, record.cost ?? 0);
}

export function buildSpendSeries(
  records: UsageRecord[],
  dayKeys: string[],
  options: { groupBy?: SpendGroupBy; metric?: SpendMetric } = {},
): SpendSeries {
  const groupBy = options.groupBy ?? "model";
  const metric = options.metric ?? "spend";
  const days = dayKeys.map((date) => ({ date, byGroup: {} as Record<string, number>, total: 0 }));
  const index = new Map(dayKeys.map((date, offset) => [date, offset]));
  const groupTotals = new Map<string, number>();

  for (const record of records) {
    const key = localDayKey(record.occurredAt);
    const offset = index.get(key);
    if (offset == null) continue;
    const value = spendMetricValue(record, metric);
    if (value <= 0) continue;
    const group = spendGroupKey(record, groupBy);
    days[offset].byGroup[group] = (days[offset].byGroup[group] ?? 0) + value;
    days[offset].total += value;
    groupTotals.set(group, (groupTotals.get(group) ?? 0) + value);
  }

  const preferredOrder = groupBy === "usageType" ? ["Included", "On-demand"] : null;
  const groups = [...groupTotals.entries()]
    .sort((a, b) => {
      if (preferredOrder) {
        const left = preferredOrder.indexOf(a[0]);
        const right = preferredOrder.indexOf(b[0]);
        if (left !== -1 || right !== -1) return (left === -1 ? 99 : left) - (right === -1 ? 99 : right);
      }
      return b[1] - a[1] || a[0].localeCompare(b[0]);
    })
    .map(([group]) => group);
  return { groups, days, metric, groupBy };
}

/** Back-compat wrapper used by older tests and call sites. */
export function buildModelSpendSeries(records: UsageRecord[], dayKeys: string[]): ModelSpendSeries {
  const series = buildSpendSeries(records, dayKeys, { groupBy: "model", metric: "spend" });
  return {
    models: series.groups,
    days: series.days.map((day) => ({ date: day.date, byModel: day.byGroup, total: day.total })),
  };
}

export function splitSpendByUsageType(records: UsageRecord[]): { included: number; onDemand: number; total: number } {
  let included = 0;
  let onDemand = 0;
  for (const record of records) {
    const cost = record.cost ?? 0;
    if (cost <= 0) continue;
    if ((record.usageType ?? (record.provider === "cursor" ? "included" : "onDemand")) === "included") included += cost;
    else onDemand += cost;
  }
  return { included, onDemand, total: included + onDemand };
}

/** Full date heading for the spend-chart hover tooltip (e.g. "Jul 23, 2026"). */
export function formatSpendDayHeading(dayKey: string): string {
  const date = new Date(`${dayKey}T12:00:00`);
  if (Number.isNaN(date.valueOf())) return dayKey;
  return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", year: "numeric" }).format(date);
}

/** Per-day group breakdown plus running total through that day in the selected range. */
export function daySpendBreakdown(series: SpendSeries, dayIndex: number): DaySpendBreakdown | null {
  if (dayIndex < 0 || dayIndex >= series.days.length) return null;
  const day = series.days[dayIndex];
  const dailyTotal = day.total;
  let cumulativeTotal = 0;
  for (let index = 0; index <= dayIndex; index += 1) cumulativeTotal += series.days[index].total;
  const rows = Object.entries(day.byGroup)
    .filter(([, amount]) => amount > 0)
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .map(([group, amount]) => ({
      group,
      amount,
      percent: dailyTotal > 0 ? (amount / dailyTotal) * 100 : 0,
    }));
  return { date: day.date, rows, dailyTotal, cumulativeTotal };
}

function safeURL(value: unknown): string | undefined {
  const candidate = string(value); if (!candidate) return undefined;
  try { const url = new URL(candidate); return url.protocol === "https:" ? url.toString() : undefined; } catch { return undefined; }
}

export function groupByProvider(records: UsageRecord[]): Record<Provider, UsageRecord[]> {
  return { claude: records.filter((record) => record.provider === "claude"), codex: records.filter((record) => record.provider === "codex"), cursor: records.filter((record) => record.provider === "cursor") };
}

export const sumTokens = (records: UsageRecord[]) => records.reduce((total, record) => total + record.tokens.total, 0);
export const sumCost = (records: UsageRecord[]) => records.reduce((total, record) => total + (record.cost ?? 0), 0);
