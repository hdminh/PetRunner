export function formatTokens(value: number) {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(value >= 10_000_000 ? 1 : 2)}M`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(value >= 100_000 ? 0 : 1)}K`;
  return Math.round(value).toLocaleString();
}
export function formatCost(value: number | null | undefined) {
  if (value == null) return "—";
  return new Intl.NumberFormat(undefined, { style: "currency", currency: "USD", minimumFractionDigits: value < 1 ? 3 : 2, maximumFractionDigits: value < 1 ? 3 : 2 }).format(value);
}
export function formatDate(value: string) {
  const date = new Date(value); if (Number.isNaN(date.valueOf())) return "—";
  return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }).format(date);
}
export function formatRelative(value: string) {
  const date = new Date(value);
  if (Number.isNaN(date.valueOf())) return "—";
  const deltaMs = Date.now() - date.valueOf();
  const minute = 60_000;
  const hour = 60 * minute;
  const day = 24 * hour;
  if (deltaMs < minute) return "just now";
  if (deltaMs < hour) return `${Math.round(deltaMs / minute)}m ago`;
  if (deltaMs < day) return `${Math.round(deltaMs / hour)}h ago`;
  if (deltaMs < 7 * day) return `${Math.round(deltaMs / day)}d ago`;
  if (deltaMs < 30 * day) return `${Math.round(deltaMs / (7 * day))}w ago`;
  return `${Math.round(deltaMs / (30 * day))}mo ago`;
}
export function formatDuration(seconds: number) {
  if (!Number.isFinite(seconds) || seconds <= 0) return "0ms";
  if (seconds < 1) return `${Math.round(seconds * 1_000)}ms`;
  if (seconds < 60) return `${Math.round(seconds)}s`;
  if (seconds < 3600) {
    const minutes = Math.floor(seconds / 60);
    const rem = Math.round(seconds % 60);
    return rem ? `${minutes}m ${rem}s` : `${minutes}m`;
  }
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.round((seconds % 3600) / 60);
  return minutes ? `${hours}h ${minutes}m` : `${hours}h`;
}
export function formatPct(value: number, digits = 1) {
  return `${(value * 100).toFixed(digits)}%`;
}
export const displayProvider = (provider: string) => provider.slice(0, 1).toUpperCase() + provider.slice(1);

/** USD per 1M tokens for pricing catalog tables. */
export function formatRatePerMillion(value: number | null | undefined) {
  if (value == null) return "—";
  if (value === 0) return "$0";
  const digits = value < 0.01 ? 4 : value < 1 ? 3 : 2;
  return new Intl.NumberFormat(undefined, {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  }).format(value);
}

