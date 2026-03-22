export interface LogDocument {
  timestamp_nanos: number;
  observed_timestamp_nanos: number;
  service_name: string;
  severity_text: string;
  severity_number: number;
  body: Record<string, unknown>;
  attributes: Record<string, unknown> | null;
  trace_id: string;
  span_id: string;
  resource_attributes: Record<string, unknown> | null;
}

export function extractBody(body: Record<string, unknown>): string {
  if (typeof body?.message === "string") return body.message;
  return JSON.stringify(body);
}

export function severityColor(severity: string): string {
  const upper = severity.toUpperCase();
  if (upper.startsWith("FATAL") || upper.startsWith("ERROR"))
    return "text-red-400";
  if (upper.startsWith("WARN")) return "text-amber-400";
  if (upper.startsWith("INFO")) return "text-blue-400";
  return "text-muted-foreground";
}

// --- Column definitions ---

export interface LogColumnDef {
  id: string;
  label: string;
  type: "pseudo" | "data";
}

export const PSEUDO_COLUMNS: LogColumnDef[] = [
  { id: "_timestamp", label: "Timestamp", type: "pseudo" },
  { id: "_severity", label: "Severity", type: "pseudo" },
  { id: "_service", label: "Service", type: "pseudo" },
  { id: "_message", label: "Message", type: "pseudo" },
  { id: "_trace", label: "Trace", type: "pseudo" },
];

export const DEFAULT_COLUMNS = ["_timestamp", "_severity", "_service", "_message", "_trace"];

const STORAGE_KEY = "winnow-log-columns";

export function loadColumns(): string[] {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored) {
      const parsed = JSON.parse(stored);
      if (Array.isArray(parsed) && parsed.length > 0) return parsed;
    }
  } catch { /* ignore */ }
  return DEFAULT_COLUMNS;
}

export function saveColumns(columns: string[]) {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(columns));
}

// Fields already represented by pseudo columns — skip these when discovering data fields
const PSEUDO_RAW_FIELDS = new Set([
  "timestamp_nanos",
  "observed_timestamp_nanos",
  "service_name",
  "severity_text",
  "severity_number",
  "body",
  "trace_id",
  "span_id",
]);

export function discoverDataFields(logs: LogDocument[]): LogColumnDef[] {
  const seen = new Set<string>();
  const result: LogColumnDef[] = [];

  function collect(obj: Record<string, unknown>, prefix: string) {
    for (const [key, val] of Object.entries(obj)) {
      const path = prefix ? `${prefix}.${key}` : key;
      if (!prefix && PSEUDO_RAW_FIELDS.has(key)) continue;
      if (val != null && typeof val === "object" && !Array.isArray(val)) {
        collect(val as Record<string, unknown>, path);
      } else if (!seen.has(path)) {
        seen.add(path);
        result.push({ id: path, label: path, type: "data" });
      }
    }
  }

  for (const log of logs) {
    // Top-level fields (minus pseudo-covered ones)
    collect(log as unknown as Record<string, unknown>, "");
    // Nested objects
    if (log.attributes) collect(log.attributes, "attributes");
    if (log.resource_attributes) collect(log.resource_attributes, "resource_attributes");
  }

  result.sort((a, b) => a.label.localeCompare(b.label));
  return result;
}

export function getFieldValue(log: LogDocument, fieldPath: string): string {
  const parts = fieldPath.split(".");
  let current: unknown = log;

  // Walk the path, handling both nested objects and flat dotted keys.
  // At each level, try consuming 1 part first (nested), then 2, 3, ...
  // so "resource_attributes.service.name" resolves both
  // log.resource_attributes.service.name (nested) and
  // log.resource_attributes["service.name"] (flat dotted key).
  for (let i = 0; i < parts.length; ) {
    if (current == null || typeof current !== "object") return "";
    const obj = current as Record<string, unknown>;
    let found = false;
    for (let len = 1; len <= parts.length - i; len++) {
      const key = parts.slice(i, i + len).join(".");
      if (key in obj) {
        current = obj[key];
        i += len;
        found = true;
        break;
      }
    }
    if (!found) return "";
  }

  if (current == null) return "";
  if (typeof current === "string") return current;
  return JSON.stringify(current);
}
