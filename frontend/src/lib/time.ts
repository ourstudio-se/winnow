/** Shared time selection types and utilities used by FilterBar, TimeHistogram, and views. */

export type TimeSelection =
  | { type: "relative"; key: string; label: string; seconds: number }
  | { type: "absolute"; from: Date; to: Date }
  | { type: "all" };

export interface QuickPreset {
  key: string;
  label: string;
  seconds: number;
}

export const QUICK_PRESETS: QuickPreset[] = [
  { key: "15m", label: "Last 15 minutes", seconds: 900 },
  { key: "1h", label: "Last 1 hour", seconds: 3600 },
  { key: "4h", label: "Last 4 hours", seconds: 14400 },
  { key: "12h", label: "Last 12 hours", seconds: 43200 },
  { key: "24h", label: "Last 24 hours", seconds: 86400 },
  { key: "2d", label: "Last 2 days", seconds: 172800 },
  { key: "7d", label: "Last 7 days", seconds: 604800 },
  { key: "30d", label: "Last 30 days", seconds: 2592000 },
];

export const DEFAULT_PRESET = QUICK_PRESETS[1]; // "Last 1 hour"
export const STORAGE_KEY = "winnow-time-preset";

export function parseTimeParam(param: string | null): TimeSelection {
  if (!param) return { type: "relative", ...DEFAULT_PRESET };
  if (param === "all") return { type: "all" };
  if (param.startsWith("abs:")) {
    const parts = param.slice(4).split(",");
    if (parts.length === 2) {
      const from = new Date(parts[0]);
      const to = new Date(parts[1]);
      if (!isNaN(from.getTime()) && !isNaN(to.getTime())) {
        return { type: "absolute", from, to };
      }
    }
    return { type: "relative", ...DEFAULT_PRESET };
  }
  const preset = QUICK_PRESETS.find((p) => p.key === param);
  if (preset) return { type: "relative", ...preset };
  return { type: "relative", ...DEFAULT_PRESET };
}

export function serializeTimeParam(sel: TimeSelection): string {
  if (sel.type === "all") return "all";
  if (sel.type === "absolute") {
    const fmt = (d: Date) => {
      const y = d.getFullYear();
      const mo = String(d.getMonth() + 1).padStart(2, "0");
      const da = String(d.getDate()).padStart(2, "0");
      const h = String(d.getHours()).padStart(2, "0");
      const mi = String(d.getMinutes()).padStart(2, "0");
      const s = String(d.getSeconds()).padStart(2, "0");
      // Include seconds only when non-zero (histogram selections need precision)
      return s === "00"
        ? `${y}-${mo}-${da}T${h}:${mi}`
        : `${y}-${mo}-${da}T${h}:${mi}:${s}`;
    };
    return `abs:${fmt(sel.from)},${fmt(sel.to)}`;
  }
  return sel.key;
}

export function fmtDate(d: Date): string {
  const y = d.getFullYear();
  const mo = String(d.getMonth() + 1).padStart(2, "0");
  const da = String(d.getDate()).padStart(2, "0");
  return `${y}-${mo}-${da}`;
}

export function fmtTime(d: Date): string {
  const h = String(d.getHours()).padStart(2, "0");
  const mi = String(d.getMinutes()).padStart(2, "0");
  return `${h}:${mi}`;
}

export function timeSelectionLabel(sel: TimeSelection): string {
  if (sel.type === "all") return "All time";
  if (sel.type === "relative") return sel.label;
  return `${fmtDate(sel.from)} ${fmtTime(sel.from)} → ${fmtDate(sel.to)} ${fmtTime(sel.to)}`;
}

/** Compute the time window boundaries in milliseconds from a TimeSelection. Returns null for "all". */
export function computeTimeRange(sel: TimeSelection): { startMs: number; endMs: number } | null {
  if (sel.type === "all") return null;
  if (sel.type === "absolute") {
    return { startMs: sel.from.getTime(), endMs: sel.to.getTime() };
  }
  const endMs = Date.now();
  return { startMs: endMs - sel.seconds * 1000, endMs };
}

/** "Nice" bucket intervals in milliseconds, from 1 second to 1 day. */
const NICE_INTERVALS_MS = [
  1_000,       // 1s
  5_000,       // 5s
  10_000,      // 10s
  15_000,      // 15s
  30_000,      // 30s
  60_000,      // 1m
  300_000,     // 5m
  600_000,     // 10m
  900_000,     // 15m
  1_800_000,   // 30m
  3_600_000,   // 1h
  10_800_000,  // 3h
  21_600_000,  // 6h
  43_200_000,  // 12h
  86_400_000,  // 1d
];

/** Pick the smallest "nice" interval that produces at most `maxBuckets` buckets for the given window. */
export function pickInterval(windowMs: number, maxBuckets = 80): number {
  for (const interval of NICE_INTERVALS_MS) {
    if (windowMs / interval <= maxBuckets) return interval;
  }
  return NICE_INTERVALS_MS[NICE_INTERVALS_MS.length - 1];
}
