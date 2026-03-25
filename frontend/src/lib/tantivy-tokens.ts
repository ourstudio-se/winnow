/** Token-at-cursor parsing for Tantivy query autocomplete. */

export type TokenContext =
  | { type: "field"; partial: string; start: number; end: number }
  | { type: "value"; field: string; partial: string; start: number; end: number }
  | { type: "none" };

const BOOLEAN_OPS = new Set(["AND", "OR", "NOT"]);
const BOUNDARY = new Set([" ", "(", ")"]);

/**
 * Find the token at the cursor position in a Tantivy query string.
 *
 * - If the token has no `:`, returns `{ type: "field", partial }` for field name completion.
 * - If the token has a `:`, returns `{ type: "value", field, partial }` for value completion.
 * - Returns `{ type: "none" }` for boolean operators, empty tokens, or range syntax.
 */
export function getTokenAtCursor(query: string, cursor: number): TokenContext {
  // Scan left to find token start
  let start = cursor;
  while (start > 0 && !BOUNDARY.has(query[start - 1])) {
    start--;
  }

  // Scan right to find token end
  let end = cursor;
  while (end < query.length && !BOUNDARY.has(query[end])) {
    end++;
  }

  const token = query.slice(start, end);
  if (!token) return { type: "none" };

  // Boolean operators get no suggestions
  if (BOOLEAN_OPS.has(token)) return { type: "none" };

  const colonIdx = token.indexOf(":");
  if (colonIdx === -1) {
    // No colon — field name completion
    return { type: "field", partial: token, start, end };
  }

  const field = token.slice(0, colonIdx);
  const rawValue = token.slice(colonIdx + 1);

  // Range syntax (e.g. severity_number:>8, field:[a TO b]) — no suggestions
  if (rawValue.startsWith(">") || rawValue.startsWith("<") || rawValue.startsWith("[") || rawValue.startsWith("{")) {
    return { type: "none" };
  }

  // Strip surrounding quotes from partial value
  let partial = rawValue;
  if (partial.startsWith('"')) partial = partial.slice(1);
  if (partial.endsWith('"')) partial = partial.slice(0, -1);

  return { type: "value", field, partial, start: start + colonIdx + 1, end };
}

/**
 * Apply a completion to the query string, returning the new query and cursor position.
 *
 * - Field completion: inserts `fieldName:` with cursor after the colon.
 * - Value completion: inserts `fieldName:"value" ` with cursor after the trailing space.
 */
export function applyCompletion(
  query: string,
  ctx: TokenContext & { type: "field" | "value" },
  completion: string,
): { newQuery: string; newCursor: number } {
  if (ctx.type === "field") {
    // Replace the partial token with `completion:`
    const insertion = `${completion}:`;
    const newQuery = query.slice(0, ctx.start) + insertion + query.slice(ctx.end);
    return { newQuery, newCursor: ctx.start + insertion.length };
  }

  // Value completion: replace from field start to token end with `field:"value" `
  // Find the field start (scan left from ctx.start past the colon and field name)
  let fieldStart = ctx.start - 1; // skip the colon
  while (fieldStart > 0 && !BOUNDARY.has(query[fieldStart - 1])) {
    fieldStart--;
  }

  const insertion = `${ctx.field}:"${completion}" `;
  const newQuery = query.slice(0, fieldStart) + insertion + query.slice(ctx.end);
  return { newQuery, newCursor: fieldStart + insertion.length };
}
