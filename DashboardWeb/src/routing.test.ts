import { describe, expect, it } from "vitest";
import {
  buildHash,
  hasExplicitAnalyticsTab,
  isAnalyticsTab,
  isProvider,
  isProviderPanel,
  isRouteHash,
  parseLocation,
  resolveAnalyticsTab,
  resolveProvider,
  resolveProviderPanel,
} from "./routing";

describe("dashboard routing", () => {
  it("parses top-level hash routes", () => {
    expect(parseLocation("#/overview")).toMatchObject({ view: "overview", provider: null });
    expect(parseLocation("#/providers")).toMatchObject({ view: "provider", provider: null, panel: null });
    expect(parseLocation("#/pets")).toMatchObject({ view: "pets" });
    expect(parseLocation("#/monitor")).toMatchObject({ view: "monitor" });
    expect(parseLocation("")).toMatchObject({ view: "overview" });
  });

  it("parses analytics tabs and provider query", () => {
    expect(parseLocation("#/analytics")).toMatchObject({ view: "analytics", analyticsTab: "sessions" });
    expect(parseLocation("#/analytics/models")).toMatchObject({ view: "analytics", analyticsTab: "models" });
    expect(parseLocation("#/providers?provider=cursor")).toMatchObject({ view: "provider", provider: "cursor" });
    expect(parseLocation("#/analytics/projects?provider=claude")).toMatchObject({
      view: "analytics",
      analyticsTab: "projects",
      provider: "claude",
    });
    expect(hasExplicitAnalyticsTab("#/analytics")).toBe(false);
    expect(hasExplicitAnalyticsTab("#/analytics/models")).toBe(true);
    expect(isAnalyticsTab("projects")).toBe(true);
    expect(isAnalyticsTab("overview")).toBe(false);
  });

  it("parses providers Usage | Pricing panel query", () => {
    expect(parseLocation("#/providers?provider=claude&panel=pricing")).toMatchObject({
      view: "provider",
      provider: "claude",
      panel: "pricing",
    });
    expect(parseLocation("#/providers?panel=usage")).toMatchObject({ panel: "usage" });
    expect(parseLocation("#/providers?panel=unknown").panel).toBeNull();
    expect(isProviderPanel("pricing")).toBe(true);
    expect(isProviderPanel("settings")).toBe(false);
  });

  it("ignores unknown providers in the query", () => {
    expect(parseLocation("#/providers?provider=unknown").provider).toBeNull();
    expect(isProvider("cursor")).toBe(true);
    expect(isProvider("gemini")).toBe(false);
  });

  it("builds hashes with optional provider query on provider-scoped views", () => {
    expect(buildHash({ view: "overview" })).toBe("#/overview");
    expect(buildHash({ view: "provider", provider: "cursor" })).toBe("#/providers?provider=cursor");
    expect(buildHash({ view: "provider", provider: "claude", panel: "pricing" })).toBe("#/providers?provider=claude&panel=pricing");
    expect(buildHash({ view: "provider", provider: "claude", panel: "usage" })).toBe("#/providers?provider=claude");
    expect(buildHash({ view: "analytics", analyticsTab: "models", provider: "codex" })).toBe("#/analytics/models?provider=codex");
    expect(buildHash({ view: "pets", provider: "cursor" })).toBe("#/pets");
  });

  it("prefers URL provider over stored fallback", () => {
    expect(resolveProvider("cursor", "providers", "codex")).toBe("cursor");
    expect(resolveProvider(null, undefined, "codex")).toBe("codex");
    expect(resolveProviderPanel("pricing")).toBe("pricing");
    expect(resolveProviderPanel(null)).toBe("usage");
    expect(resolveAnalyticsTab("models", true)).toBe("models");
  });

  it("treats only #/… hashes as app routes", () => {
    expect(isRouteHash("#/providers")).toBe(true);
    expect(isRouteHash("#content")).toBe(false);
    expect(isRouteHash("")).toBe(false);
  });
});
