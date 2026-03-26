export type IndexId = string;

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

export async function search<T>(
  index: IndexId,
  request: SearchRequest,
): Promise<SearchResponse<T>> {
  const res = await fetch(`/api/v1/${index}/search`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(request),
  });
  if (!res.ok) {
    throw new ApiError(res.status, await res.text());
  }
  return res.json();
}

export interface IndexMap {
  traces: string;
  logs: string;
}

export async function listIndexes(): Promise<IndexMap> {
  const res = await fetch("/api/v1/indexes");
  if (!res.ok) {
    throw new ApiError(res.status, await res.text());
  }
  return res.json();
}

export async function getIndexMetadata(index: IndexId): Promise<IndexMetadataResponse> {
  const res = await fetch(`/api/v1/indexes/${index}`);
  if (!res.ok) {
    throw new ApiError(res.status, await res.text());
  }
  return res.json();
}
