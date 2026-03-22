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
