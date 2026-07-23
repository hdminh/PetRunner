import { providers, type Provider } from "./types";

export type View = "overview" | "provider" | "analytics" | "pets" | "monitor";
export type AnalyticsTab = "sessions" | "projects" | "models";
export type ProviderPanel = "usage" | "pricing";

export type DashboardRoute = {
  view: View;
  analyticsTab: AnalyticsTab;
  provider: Provider | null;
  panel: ProviderPanel | null;
};

const GLOBAL_PROVIDER_KEY = "petrunner.dashboard.provider";
const PROVIDERS_PROVIDER_KEY = "petrunner.dashboard.provider.providers";
const ANALYTICS_PROVIDER_KEY = "petrunner.dashboard.provider.analytics";
const ANALYTICS_TAB_KEY = "petrunner.dashboard.analytics.tab";
const PROVIDERS_PANEL_KEY = "petrunner.dashboard.providers.panel";

export function isProvider(value: string | null | undefined): value is Provider {
  return value != null && (providers as readonly string[]).includes(value);
}

export function isProviderPanel(value: string | null | undefined): value is ProviderPanel {
  return value === "usage" || value === "pricing";
}

export function isAnalyticsTab(value: string | null | undefined): value is AnalyticsTab {
  return value === "sessions" || value === "projects" || value === "models";
}

/** True when the hash encodes a dashboard route (not a11y targets like #content). */
export function isRouteHash(hash = typeof window !== "undefined" ? window.location.hash : ""): boolean {
  if (!hash || hash === "#" || hash === "#content") return false;
  return hash.startsWith("#/");
}

function readStorage(key: string): string | null {
  try {
    return window.localStorage.getItem(key);
  } catch {
    return null;
  }
}

function writeStorage(key: string, value: string) {
  try {
    window.localStorage.setItem(key, value);
  } catch {
    // Ignore quota / private-mode failures; in-memory state still works.
  }
}

/** Last selected provider for Providers / Analytics (global + optional per-view). */
export function readStoredProvider(scope?: "providers" | "analytics"): Provider | null {
  if (scope === "providers") {
    const scoped = readStorage(PROVIDERS_PROVIDER_KEY);
    if (isProvider(scoped)) return scoped;
  }
  if (scope === "analytics") {
    const scoped = readStorage(ANALYTICS_PROVIDER_KEY);
    if (isProvider(scoped)) return scoped;
  }
  const global = readStorage(GLOBAL_PROVIDER_KEY);
  return isProvider(global) ? global : null;
}

export function writeStoredProvider(provider: Provider) {
  // Global + both view keys so Providers and Analytics stay aligned.
  writeStorage(GLOBAL_PROVIDER_KEY, provider);
  writeStorage(PROVIDERS_PROVIDER_KEY, provider);
  writeStorage(ANALYTICS_PROVIDER_KEY, provider);
}

export function readStoredProviderPanel(): ProviderPanel {
  const stored = readStorage(PROVIDERS_PANEL_KEY);
  return isProviderPanel(stored) ? stored : "usage";
}

export function writeStoredProviderPanel(panel: ProviderPanel) {
  writeStorage(PROVIDERS_PANEL_KEY, panel);
}

export function readStoredAnalyticsTab(): AnalyticsTab {
  const stored = readStorage(ANALYTICS_TAB_KEY);
  return isAnalyticsTab(stored) ? stored : "sessions";
}

export function writeStoredAnalyticsTab(tab: AnalyticsTab) {
  writeStorage(ANALYTICS_TAB_KEY, tab);
}

export function resolveProvider(
  urlProvider: Provider | null,
  scope?: "providers" | "analytics",
  fallback: Provider = "codex",
): Provider {
  return urlProvider ?? readStoredProvider(scope) ?? fallback;
}

export function resolveProviderPanel(urlPanel: ProviderPanel | null): ProviderPanel {
  return urlPanel ?? readStoredProviderPanel();
}

/** Explicit `/sessions|projects|models` wins; bare `#/analytics` restores the last tab. */
export function resolveAnalyticsTab(pathTab: AnalyticsTab | null, hadExplicitTab: boolean): AnalyticsTab {
  if (hadExplicitTab && pathTab) return pathTab;
  return readStoredAnalyticsTab();
}

/** Parse `#/providers?provider=cursor` or `#/analytics/models`. */
export function parseLocation(hash = typeof window !== "undefined" ? window.location.hash : ""): DashboardRoute {
  const raw = hash.replace(/^#\/?/, "");
  const [pathPart = "", queryPart = ""] = raw.split("?");
  const path = pathPart.replace(/\/+$/, "") || "overview";
  const params = new URLSearchParams(queryPart);
  const providerParam = params.get("provider");
  const provider = isProvider(providerParam) ? providerParam : null;
  const panelParam = params.get("panel");
  const panel = isProviderPanel(panelParam) ? panelParam : null;

  if (path === "providers" || path === "provider") {
    return { view: "provider", analyticsTab: "sessions", provider, panel };
  }
  if (path === "pets") {
    return { view: "pets", analyticsTab: "sessions", provider, panel: null };
  }
  if (path === "monitor") {
    return { view: "monitor", analyticsTab: "sessions", provider, panel: null };
  }
  const analyticsMatch = /^analytics(?:\/(sessions|projects|models))?$/.exec(path);
  if (analyticsMatch) {
    const explicit = analyticsMatch[1] as AnalyticsTab | undefined;
    const tab = explicit ?? "sessions";
    return { view: "analytics", analyticsTab: tab, provider, panel: null };
  }
  return { view: "overview", analyticsTab: "sessions", provider, panel: null };
}

/** True when the hash names an analytics sub-tab (`#/analytics/models`). */
export function hasExplicitAnalyticsTab(hash = typeof window !== "undefined" ? window.location.hash : ""): boolean {
  const raw = hash.replace(/^#\/?/, "");
  const [pathPart = ""] = raw.split("?");
  const path = pathPart.replace(/\/+$/, "");
  return /^analytics\/(sessions|projects|models)$/.test(path);
}

export function buildHash(route: {
  view: View;
  analyticsTab?: AnalyticsTab;
  provider?: Provider | null;
  panel?: ProviderPanel | null;
}): string {
  let path = "/overview";
  switch (route.view) {
    case "overview":
      path = "/overview";
      break;
    case "provider":
      path = "/providers";
      break;
    case "pets":
      path = "/pets";
      break;
    case "monitor":
      path = "/monitor";
      break;
    case "analytics":
      path = `/analytics/${route.analyticsTab ?? "sessions"}`;
      break;
  }
  const params = new URLSearchParams();
  if (route.provider && (route.view === "provider" || route.view === "analytics")) {
    params.set("provider", route.provider);
  }
  if (route.view === "provider" && route.panel && route.panel !== "usage") {
    params.set("panel", route.panel);
  }
  const query = params.toString();
  return `#${path}${query ? `?${query}` : ""}`;
}

export function readInitialNavigation(): {
  view: View;
  analyticsTab: AnalyticsTab;
  selectedProvider: Provider;
  providerPanel: ProviderPanel;
} {
  const parsed = parseLocation();
  const scope = parsed.view === "provider" ? "providers" : parsed.view === "analytics" ? "analytics" : undefined;
  const analyticsTab = parsed.view === "analytics"
    ? resolveAnalyticsTab(parsed.analyticsTab, hasExplicitAnalyticsTab())
    : readStoredAnalyticsTab();
  return {
    view: parsed.view,
    analyticsTab,
    selectedProvider: resolveProvider(parsed.provider, scope),
    providerPanel: parsed.view === "provider" ? resolveProviderPanel(parsed.panel) : "usage",
  };
}

/** Update the hash without creating a duplicate history entry when unchanged. */
export function syncHash(
  route: { view: View; analyticsTab?: AnalyticsTab; provider?: Provider | null; panel?: ProviderPanel | null },
  mode: "push" | "replace" = "push",
) {
  const next = buildHash(route);
  if (window.location.hash === next) return;
  if (mode === "replace") {
    const url = `${window.location.pathname}${window.location.search}${next}`;
    window.history.replaceState(null, "", url);
    return;
  }
  window.location.hash = next;
}
