export const providers = ["claude", "codex", "cursor"] as const;
export type Provider = (typeof providers)[number];

export type Tokens = { input: number; cachedInput: number; cacheCreation: number; cacheCreation1h: number; output: number; reasoning: number; total: number };
export type UsageBillingType = "included" | "onDemand";
export type UsageRecord = {
  id: string;
  provider: Provider;
  sessionID: string;
  occurredAt: string;
  model: string | null;
  tokens: Tokens;
  cost: number | null;
  provenance?: string | null;
  pricingVersion?: string | null;
  usageType?: UsageBillingType | null;
};
export type UsageResponse = {
  totals: { tokens: number; input: number; cachedInput: number; output: number; cost: number; sessions: number; recordCount: number };
  providers: Partial<Record<Provider, { tokens: number; cost: number; sessions: number; recordCount: number; models: { model: string; tokens: number; cost: number; recordCount: number }[] }>>;
  buckets: { date: string; tokens: number; cost: number }[];
  records: UsageRecord[];
  truncated?: boolean;
};
export type Budget = { dailyUSD: number | null; monthlyUSD: number | null };
export type ProviderInfo = {
  id: Provider;
  name: string;
  enabled: boolean;
  connected: boolean;
  account: string | null;
  email: string | null;
  plan: string | null;
  organization: string | null;
  source: string | null;
  status: string | null;
  updatedAt: string | null;
  todayTokens: number;
  todayCost: number;
  monthCost: number;
  sessionCount: number;
  costLabel: string | null;
  usageURL?: string;
  statusURL?: string;
};
export type PetInfo = {
  id: string;
  name: string;
  description: string | null;
  version: 1 | 2;
  author: string | null;
  tags: string[];
  packageVersion: string | null;
  kind: string | null;
};
export type PetSelection = {
  selectedID: string | null;
  width: number;
  autonomy?: { enabled: boolean; minimumWait: number; maximumWait: number; actions: string[] };
};
export type AppState = {
  platform?: string;
  kpis?: { todayTokens?: number; todayCost?: number; cacheRatio?: number; monthCost?: number; sessionCount?: number };
  settings?: {
    budgets?: Partial<Record<Provider, Budget>>;
    showStatusItem?: boolean;
    petsDirectory?: string | null;
    petsDirectorySource?: string | null;
    petsDirectoryEditable?: boolean;
  };
  cursor?: { connected?: boolean; status?: string; message?: string };
  providers?: Partial<Record<Provider, ProviderInfo>>;
  pets?: PetInfo[];
  pet?: PetSelection;
  monitor?: MonitorSettings;
  failures?: { id: string; message: string }[];
  capabilities?: {
    petImport?: boolean;
    petRemove?: boolean;
    statusItem?: boolean;
    petPreview?: boolean;
    petsDirectory?: boolean;
    petsDirectoryBrowse?: boolean;
    agentMonitor?: boolean;
  };
};
export type MonitorProviderOption = {
  id: Provider;
  name: string;
  detected: boolean;
  hooksDirectory: string;
  configPath: string;
  headerColor?: { red: number; green: number; blue: number };
};
export type MonitorSettings = {
  enabled: boolean;
  provider: Provider | null;
  visibleFields: string[];
  providers: MonitorProviderOption[];
};
export type ProviderLinks = Pick<ProviderInfo, "usageURL" | "statusURL">;
export type LiveSession = { id: string; name: string; provider: Provider; model: string | null; status: string; activity: string; updatedAt: string; cost: number | null };
export type UsageSession = {
  id: string;
  provider: Provider;
  title: string;
  project: string | null;
  projectPath: string | null;
  startedAt: string;
  updatedAt: string;
  durationSeconds: number;
  models: string[];
  primaryModel: string | null;
  requestCount: number;
  tokens: Tokens;
  knownCostUSD: number | null;
  unpricedRecordCount: number;
  provenance: string | null;
  records?: SessionTimelineEntry[];
};
export type UsageProject = {
  id: string;
  provider: Provider;
  name: string;
  path: string | null;
  sessionCount: number;
  requestCount: number;
  tokens: Tokens;
  knownCostUSD: number;
  updatedAt: string;
  models: string[];
};
export type UsageModel = {
  id: string;
  provider: Provider;
  model: string;
  displayName: string;
  requestCount: number;
  tokens: Tokens;
  knownCostUSD: number;
  cacheSavedUSD: number;
  costShare: number;
  tokenShare: number;
  cacheHitRatio: number;
  pricingResolved: boolean;
  inputPerMillionUSD: number | null;
  outputPerMillionUSD: number | null;
  cacheReadPerMillionUSD: number | null;
};
export type ActivityComparison = { refKey: string; label: string; multiplier: number };
export type ActivityStats = {
  activeDays: number;
  currentStreak: number;
  longestStreak: number;
  peakHour: number;
  requestCount: number;
  totalTokens: number;
  heatmap: number[][];
  heatmapMax: number;
  tokenHeatmap: number[][];
  comparison: ActivityComparison | null;
};
export type SessionTimelineEntry = { occurredAt: string; model: string | null; tokens: Tokens; knownCostUSD: number | null; provenance: string | null };
/** @deprecated Use UsageSession */
export type HistoricalSession = UsageSession;
export type HistoricalTimelineEntry = SessionTimelineEntry;

export type PricingCatalogEntry = {
  id: string;
  displayName: string;
  provider: Provider;
  inputPerMillionUSD: number;
  outputPerMillionUSD: number;
  cacheReadPerMillionUSD: number | null;
  cacheWritePerMillionUSD: number | null;
  contextThreshold: number | null;
  inputAboveThresholdPerMillionUSD: number | null;
  outputAboveThresholdPerMillionUSD: number | null;
  cacheReadAboveThresholdPerMillionUSD: number | null;
  cacheWriteAboveThresholdPerMillionUSD: number | null;
};

export type PricingCatalogResponse = {
  source: string;
  version: string;
  label: string;
  providers: Partial<Record<Provider, { id: Provider; name: string; hasLocalCatalog: boolean; note: string | null }>>;
  models: PricingCatalogEntry[];
  count: number;
  refreshed?: boolean;
  refreshSource?: string;
};
