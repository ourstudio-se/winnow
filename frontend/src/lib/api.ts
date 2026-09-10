import {
  clearReloginMarker,
  redirectToLogin,
  signalForbidden,
} from "@/lib/auth";

export interface FieldMapping {
  name: string;
  type: string;
  tokenizer?: string;
  fast?: boolean;
}

export interface IndexMetadataResponse {
  index_config: {
    index_id: string;
    doc_mapping: {
      field_mappings: FieldMapping[];
      tag_fields: string[];
    };
  };
}

export interface SearchRequest {
  query: string;
  max_hits?: number;
  start_offset?: number;
  sort_by?: string;
  aggs?: Record<string, unknown>;
}

export interface SearchResponse<T> {
  num_hits: number;
  hits: T[];
  elapsed_secs: number;
  aggregations?: Record<string, unknown>;
}

class ApiError extends Error {
  status: number;

  constructor(status: number, message: string) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

/**
 * Shared response gate: routes auth failures to the auth layer (401 →
 * login redirect, 403 → forbidden page) before throwing for the caller's
 * error state.
 */
async function ensureOk(res: Response): Promise<Response> {
  if (res.ok) {
    // Auth works; drop the post-login marker so it doesn't linger in the
    // URL (see RELOGIN_PARAM in lib/auth.ts).
    clearReloginMarker();
    return res;
  }
  if (res.status === 401) {
    void redirectToLogin();
  } else if (res.status === 403) {
    signalForbidden();
  }
  throw new ApiError(res.status, await res.text());
}

/**
 * Translate ES-style sort syntax ("-field" = descending, "field" = ascending)
 * to Quickwit's, which is inverted: a bare field sorts descending and a "-"
 * prefix means ascending. App code uses ES-style throughout.
 */
function toQuickwitSortBy(sortBy: string): string {
  return sortBy
    .split(",")
    .map((part) => {
      const field = part.trim();
      return field.startsWith("-") ? field.slice(1) : `-${field}`;
    })
    .join(",");
}

async function searchIndex<T>(
  category: "traces" | "logs",
  request: SearchRequest,
): Promise<SearchResponse<T>> {
  const body: SearchRequest = request.sort_by
    ? { ...request, sort_by: toQuickwitSortBy(request.sort_by) }
    : request;
  const res = await fetch(`/api/v1/${category}/search`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  await ensureOk(res);
  return res.json();
}

export async function searchTraces<T>(
  request: SearchRequest,
): Promise<SearchResponse<T>> {
  return searchIndex("traces", request);
}

export async function searchLogs<T>(
  request: SearchRequest,
): Promise<SearchResponse<T>> {
  return searchIndex("logs", request);
}

async function getMetadata(
  category: "traces" | "logs",
): Promise<IndexMetadataResponse> {
  const res = await fetch(`/api/v1/${category}/metadata`);
  await ensureOk(res);
  return res.json();
}

export async function getTracesMetadata(): Promise<IndexMetadataResponse> {
  return getMetadata("traces");
}

export async function getLogsMetadata(): Promise<IndexMetadataResponse> {
  return getMetadata("logs");
}

export interface ServiceGraphResponse {
  svc: SearchResponse<never>;
  edges: SearchResponse<never>;
  connector: SearchResponse<never>;
}

export async function fetchServiceGraph(
  query: string,
): Promise<ServiceGraphResponse> {
  const res = await fetch("/api/v1/service-graph", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query }),
  });
  await ensureOk(res);
  return res.json();
}
