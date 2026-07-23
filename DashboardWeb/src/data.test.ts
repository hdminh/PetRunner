import { describe, expect, it } from "vitest";
import { apiRangeForProviderSpend, buildModelSpendSeries, buildSpendSeries, daySpendBreakdown, formatDayRangeLabel, formatSpendDayHeading, groupSessionsByDay, localDayKey, normalizeActivity, normalizeMonitor, normalizeUsageSession, normalizeUsageSessions, normalizeState, normalizeUsage, providerDayKeys, splitSpendByUsageType, tokens } from "./data";

describe("activity normalization", () => {
  it("pads heatmap grids and keeps peak hour / comparison", () => {
    const activity = normalizeActivity({
      activeDays: 23,
      currentStreak: 0,
      longestStreak: 7,
      peakHour: 23,
      requestCount: 40,
      totalTokens: 500_000_000,
      heatmap: [[1], [0, 2]],
      heatmapMax: 2,
      tokenHeatmap: [[10]],
      comparison: { refKey: "encyclopediaBritannica", label: "the Encyclopedia Britannica", multiplier: 9.3 },
    });
    expect(activity.activeDays).toBe(23);
    expect(activity.peakHour).toBe(23);
    expect(activity.heatmap).toHaveLength(7);
    expect(activity.heatmap[0]).toHaveLength(24);
    expect(activity.heatmap[0][0]).toBe(1);
    expect(activity.heatmap[1][1]).toBe(2);
    expect(activity.comparison).toMatchObject({ refKey: "encyclopediaBritannica", multiplier: 9.3 });
  });

  it("treats missing peak hour as unset", () => {
    expect(normalizeActivity({ peakHour: -1 }).peakHour).toBe(-1);
    expect(normalizeActivity({}).peakHour).toBe(-1);
  });
});

describe("usage normalization", () => {
  it("keeps reasoning out of charged totals", () => {
    expect(tokens({ input: "4", cachedInput: 2, cacheCreation: 5, output: 3, reasoning: 9 })).toEqual({ input: 4, cachedInput: 2, cacheCreation: 5, cacheCreation1h: 0, output: 3, reasoning: 9, total: 14 });
  });
  it("accepts a v1 numeric cost and missing optional values", () => {
    const usage = normalizeUsage({ records: [{ id: "a", provider: "claude", tokens: { total: 4 }, cost: 0.12 }] });
    expect(usage.records[0]).toMatchObject({ provider: "claude", cost: 0.12, model: null });
  });
  it("keeps full provider aggregates when the record preview is truncated", () => {
    const usage = normalizeUsage({ providers: { codex: { tokens: 10_000, cost: 1.2, sessions: 12, recordCount: 900, models: [{ model: "gpt-5", tokens: 10_000, cost: 1.2, recordCount: 900 }] } }, records: [{ provider: "codex", tokens: { total: 1 } }], truncated: true });
    expect(usage.providers.codex).toMatchObject({ tokens: 10_000, recordCount: 900 });
  });
  it("preserves Cursor usageType for included vs on-demand grouping", () => {
    const usage = normalizeUsage({ records: [
      { id: "a", provider: "cursor", tokens: { total: 1 }, cost: 0.2, usageType: "included" },
      { id: "b", provider: "cursor", tokens: { total: 2 }, cost: 0.5, usageType: "onDemand" },
    ] });
    expect(usage.records.map((record) => record.usageType)).toEqual(["included", "onDemand"]);
  });
});

describe("usage session normalization", () => {
  it("keeps ledger session fields and timeline records", () => {
    const [session] = normalizeUsageSessions({ sessions: [{ id: "c-1", provider: "claude", title: "Fix parser", project: "PetRunner", projectPath: "/Users/me/PetRunner", startedAt: "2026-07-22T01:00:00Z", updatedAt: "2026-07-22T02:00:00Z", durationSeconds: "3600", models: ["claude-sonnet"], primaryModel: "claude-sonnet", requestCount: 3, tokens: { input: 2, output: 4 }, knownCostUSD: 0.12, unpricedRecordCount: 1, provenance: "calculated", records: [{ occurredAt: "2026-07-22T01:30:00Z", model: "claude-sonnet", tokens: { total: 6 }, knownCostUSD: 0.12 }] }] });
    expect(session).toMatchObject({ provider: "claude", title: "Fix parser", projectPath: "/Users/me/PetRunner", durationSeconds: 3600, primaryModel: "claude-sonnet", knownCostUSD: 0.12 });
    expect(session.records?.[0].tokens.total).toBe(6);
  });

  it("groups most recent local days first within a provider", () => {
    const sessions = normalizeUsageSessions({ sessions: [
      { id: "z", provider: "codex", title: "Codex", updatedAt: "2026-07-22T04:00:00Z" },
      { id: "a", provider: "codex", title: "Earlier", updatedAt: "2026-07-22T02:00:00Z" },
      { id: "old", provider: "codex", title: "Old", updatedAt: "2026-07-21T02:00:00Z" },
      { id: "cursor", provider: "cursor", title: "Cursor", updatedAt: "2026-07-22T05:00:00Z" },
    ] });
    const groups = groupSessionsByDay(sessions.filter((session) => session.provider === "codex"));
    expect(groups).toHaveLength(2);
    expect(groups[0].sessions.map((session) => session.id)).toEqual(["z", "a"]);
    expect(groups[0].knownCostUSD).toBe(0);
  });

  it("accepts Cursor sessions from the usage ledger", () => {
    const [session] = normalizeUsageSessions({ sessions: [{ id: "cursor-1", provider: "cursor", title: "composer", knownCostUSD: 0.2, updatedAt: "2026-07-22T01:00:00Z" }] });
    expect(session).toMatchObject({ provider: "cursor", title: "composer", knownCostUSD: 0.2 });
    expect(() => normalizeUsageSession({ id: "bad", provider: "unknown" })).toThrow(/known provider/);
  });
});

describe("provider links", () => {
  it("keeps Cursor's official HTTPS links for its provider dashboard", () => {
    const state = normalizeState({ providers: [{ id: "cursor", usageURL: "https://cursor.com/dashboard?tab=usage", statusURL: "http://status.cursor.com/" }] });
    expect(state.providers?.cursor?.usageURL).toBe("https://cursor.com/dashboard?tab=usage");
    expect(state.providers?.cursor?.statusURL).toBeUndefined();
  });

  it("normalizes enablement and account metadata for providers", () => {
    const state = normalizeState({
      providers: [
        { id: "claude", enabled: false, account: "claude@example.com", plan: "Claude Enterprise", source: "Local Claude config", status: "Disabled", connected: false },
        { id: "codex", enabled: true, email: "codex@example.com", plan: "Plus", source: "ChatGPT auth", status: "Signed in", connected: true },
      ],
    });
    expect(state.providers?.claude).toMatchObject({ enabled: false, account: "claude@example.com", plan: "Claude Enterprise", status: "Disabled" });
    expect(state.providers?.codex).toMatchObject({ enabled: true, account: "codex@example.com", plan: "Plus", connected: true });
    expect(state.providers?.cursor?.enabled).toBe(true);
  });

  it("normalizes pets, selection, and status-item settings", () => {
    const state = normalizeState({
      pets: [{ id: "missy", name: "Missy", description: "A calico", version: 2, author: "Guangyi Chen", tags: ["cute"], packageVersion: "2.3.2", kind: "mascot" }],
      pet: { selectedID: "missy", width: 160, autonomy: { enabled: true, minimumWait: 5, maximumWait: 20, actions: ["wave"] } },
      settings: {
        showStatusItem: false,
        petsDirectory: "/Users/me/.codex/pets",
        petsDirectorySource: "default",
        petsDirectoryEditable: true,
        budgets: { codex: { dailyUSD: 1, monthlyUSD: 20 } },
      },
      capabilities: { petImport: true, petRemove: true, statusItem: true, petPreview: true, petsDirectory: true, petsDirectoryBrowse: true },
      failures: [{ id: "broken", message: "bad atlas" }],
    });
    expect(state.pets?.[0]).toMatchObject({ id: "missy", name: "Missy", version: 2, author: "Guangyi Chen", packageVersion: "2.3.2" });
    expect(state.pets?.[0].tags).toEqual(["animated", "cute", "mascot"]);
    expect(state.pet).toMatchObject({ selectedID: "missy", width: 160 });
    expect(state.settings?.showStatusItem).toBe(false);
    expect(state.settings?.petsDirectory).toBe("/Users/me/.codex/pets");
    expect(state.settings?.petsDirectoryEditable).toBe(true);
    expect(state.capabilities?.petRemove).toBe(true);
    expect(state.capabilities?.petsDirectoryBrowse).toBe(true);
    expect(state.settings?.budgets?.codex).toEqual({ dailyUSD: 1, monthlyUSD: 20 });
    expect(state.failures).toEqual([{ id: "broken", message: "bad atlas" }]);
  });

  it("normalizes agent monitor settings and hook paths", () => {
    const monitor = normalizeMonitor({
      enabled: true,
      provider: "cursor",
      visibleFields: ["model", "job", "sessionName", "cost"],
      providers: [
        {
          id: "cursor",
          name: "CURSOR",
          detected: true,
          hooksDirectory: "/Users/demo/.cursor",
          configPath: "/Users/demo/.cursor/hooks.json",
          headerColor: { red: 0.23, green: 0.51, blue: 0.96 },
        },
      ],
    });
    expect(monitor).toMatchObject({
      enabled: true,
      provider: "cursor",
      visibleFields: ["model", "job", "sessionName", "cost"],
    });
    expect(monitor.providers[0]).toMatchObject({
      id: "cursor",
      detected: true,
      hooksDirectory: "/Users/demo/.cursor",
      configPath: "/Users/demo/.cursor/hooks.json",
    });
    const state = normalizeState({ monitor, capabilities: { agentMonitor: true } });
    expect(state.monitor?.provider).toBe("cursor");
    expect(state.capabilities?.agentMonitor).toBe(true);
  });
});

describe("provider spend series", () => {
  const now = new Date(2026, 6, 23, 15, 0, 0);

  it("maps UI ranges onto API range tokens", () => {
    expect(apiRangeForProviderSpend("1d")).toBe("today");
    expect(apiRangeForProviderSpend("7d")).toBe("7d");
    expect(apiRangeForProviderSpend("30d")).toBe("30d");
    expect(apiRangeForProviderSpend("mtd")).toBe("month");
  });

  it("builds contiguous local day keys for each range", () => {
    expect(providerDayKeys("1d", now)).toEqual(["2026-07-23"]);
    expect(providerDayKeys("7d", now)).toEqual([
      "2026-07-17", "2026-07-18", "2026-07-19", "2026-07-20", "2026-07-21", "2026-07-22", "2026-07-23",
    ]);
    expect(providerDayKeys("mtd", now)[0]).toBe("2026-07-01");
    expect(providerDayKeys("mtd", now).at(-1)).toBe("2026-07-23");
    expect(providerDayKeys("30d", now)).toHaveLength(30);
  });

  it("formats a compact day-range label", () => {
    expect(formatDayRangeLabel(["2026-07-23"])).toMatch(/Jul/);
    expect(formatDayRangeLabel(["2026-07-17", "2026-07-23"])).toContain("–");
  });

  it("buckets spend onto the local calendar day, not the UTC date prefix", () => {
    // 2026-07-21T20:00:00Z is Jul 22 03:00 in UTC+7 (Vietnam).
    const occurredAt = "2026-07-21T20:00:00Z";
    const key = localDayKey(occurredAt);
    const series = buildSpendSeries([
      { id: "1", provider: "cursor", sessionID: "a", occurredAt, model: "alpha", tokens: tokens({ total: 10 }), cost: 2, usageType: "included" },
    ], ["2026-07-21", "2026-07-22"], { groupBy: "model", metric: "spend" });
    if (key === "2026-07-22") {
      expect(series.days[0].total).toBe(0);
      expect(series.days[1]).toMatchObject({ date: "2026-07-22", total: 2, byGroup: { alpha: 2 } });
    } else {
      expect(series.days.find((day) => day.date === key)?.total).toBe(2);
    }
  });

  it("keeps empty days in the selected range on the axis", () => {
    const series = buildSpendSeries([
      { id: "1", provider: "cursor", sessionID: "a", occurredAt: "2026-07-23T10:00:00", model: "alpha", tokens: tokens({ total: 1 }), cost: 1 },
    ], ["2026-07-17", "2026-07-18", "2026-07-19", "2026-07-20", "2026-07-21", "2026-07-22", "2026-07-23"]);
    expect(series.days).toHaveLength(7);
    expect(series.days.slice(0, 6).every((day) => day.total === 0)).toBe(true);
    expect(series.days[6].total).toBe(1);
  });

  it("stacks daily spend by model and ranks models by total spend", () => {
    const series = buildModelSpendSeries([
      { id: "1", provider: "cursor", sessionID: "a", occurredAt: "2026-07-22T10:00:00", model: "alpha", tokens: tokens({ total: 1 }), cost: 1 },
      { id: "2", provider: "cursor", sessionID: "b", occurredAt: "2026-07-22T12:00:00", model: "beta", tokens: tokens({ total: 1 }), cost: 3 },
      { id: "3", provider: "cursor", sessionID: "c", occurredAt: "2026-07-23T09:00:00", model: "alpha", tokens: tokens({ total: 1 }), cost: 2 },
      { id: "4", provider: "cursor", sessionID: "d", occurredAt: "2026-07-21T09:00:00", model: null, tokens: tokens({ total: 1 }), cost: 0.5 },
    ], ["2026-07-22", "2026-07-23"]);
    expect(series.models).toEqual(["alpha", "beta"]);
    expect(series.days[0]).toMatchObject({ date: "2026-07-22", total: 4, byModel: { alpha: 1, beta: 3 } });
    expect(series.days[1]).toMatchObject({ date: "2026-07-23", total: 2, byModel: { alpha: 2 } });
  });

  it("groups by usage type and can stack tokens instead of spend", () => {
    const records = [
      { id: "1", provider: "cursor" as const, sessionID: "a", occurredAt: "2026-07-22T10:00:00", model: "alpha", tokens: tokens({ total: 100 }), cost: 1, usageType: "included" as const },
      { id: "2", provider: "cursor" as const, sessionID: "b", occurredAt: "2026-07-22T12:00:00", model: "beta", tokens: tokens({ total: 50 }), cost: 3, usageType: "onDemand" as const },
      { id: "3", provider: "cursor" as const, sessionID: "c", occurredAt: "2026-07-23T09:00:00", model: "alpha", tokens: tokens({ total: 25 }), cost: 2, usageType: "included" as const },
    ];
    const byType = buildSpendSeries(records, ["2026-07-22", "2026-07-23"], { groupBy: "usageType", metric: "spend" });
    expect(byType.groups).toEqual(["Included", "On-demand"]);
    expect(byType.days[0]).toMatchObject({ total: 4, byGroup: { Included: 1, "On-demand": 3 } });
    const byTokens = buildSpendSeries(records, ["2026-07-22", "2026-07-23"], { groupBy: "model", metric: "tokens" });
    expect(byTokens.groups).toEqual(["alpha", "beta"]);
    expect(byTokens.days[0]).toMatchObject({ total: 150, byGroup: { alpha: 100, beta: 50 } });
    expect(splitSpendByUsageType(records)).toEqual({ included: 3, onDemand: 3, total: 6 });
  });

  it("builds a hover breakdown with daily rows and cumulative totals", () => {
    const series = buildSpendSeries([
      { id: "1", provider: "cursor", sessionID: "a", occurredAt: "2026-07-22T10:00:00", model: "alpha", tokens: tokens({ total: 1 }), cost: 1 },
      { id: "2", provider: "cursor", sessionID: "b", occurredAt: "2026-07-22T12:00:00", model: "beta", tokens: tokens({ total: 1 }), cost: 3 },
      { id: "3", provider: "cursor", sessionID: "c", occurredAt: "2026-07-23T09:00:00", model: "alpha", tokens: tokens({ total: 1 }), cost: 2 },
      { id: "4", provider: "cursor", sessionID: "d", occurredAt: "2026-07-23T11:00:00", model: "gamma", tokens: tokens({ total: 1 }), cost: 1 },
    ], ["2026-07-22", "2026-07-23"]);
    expect(daySpendBreakdown(series, -1)).toBeNull();
    expect(daySpendBreakdown(series, 0)).toMatchObject({
      date: "2026-07-22",
      dailyTotal: 4,
      cumulativeTotal: 4,
      rows: [
        { group: "beta", amount: 3, percent: 75 },
        { group: "alpha", amount: 1, percent: 25 },
      ],
    });
    expect(daySpendBreakdown(series, 1)).toMatchObject({
      date: "2026-07-23",
      dailyTotal: 3,
      cumulativeTotal: 7,
      rows: [
        { group: "alpha", amount: 2, percent: expect.closeTo(66.666, 2) },
        { group: "gamma", amount: 1, percent: expect.closeTo(33.333, 2) },
      ],
    });
    expect(formatSpendDayHeading("2026-07-23")).toMatch(/Jul/);
    expect(formatSpendDayHeading("2026-07-23")).toMatch(/2026/);
  });
});
