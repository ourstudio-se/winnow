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
  if (!res.ok) {
    throw new ApiError(res.status, await res.text());
  }
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
  if (!res.ok) {
    throw new ApiError(res.status, await res.text());
  }
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
  if (!res.ok) {
    throw new ApiError(res.status, await res.text());
  }
  return res.json();
}
