import { useCallback, useEffect, useRef, useState } from "react";
import { Loader2 } from "lucide-react";
import {
  getTokenAtCursor,
  applyCompletion,
  type TokenContext,
} from "@/lib/tantivy-tokens";

interface DiscoveredField {
  field: string;
  kind: "text" | "bool";
}

interface RawQueryInputProps {
  value: string;
  onChange: (value: string) => void;
  onSubmit: () => void;
  discoveredFields: DiscoveredField[];
  fetchValues: (field: string) => Promise<string[]>;
}

export function RawQueryInput({
  value,
  onChange,
  onSubmit,
  discoveredFields,
  fetchValues,
}: RawQueryInputProps) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [tokenCtx, setTokenCtx] = useState<TokenContext>({ type: "none" });
  const [suggestions, setSuggestions] = useState<string[]>([]);
  const [selectedIdx, setSelectedIdx] = useState(0);
  const [loading, setLoading] = useState(false);

  // Cache fetched values per field name
  const valueCacheRef = useRef<Map<string, string[]>>(new Map());
  // Track fetchValues identity to clear cache when it changes
  const fetchValuesRef = useRef(fetchValues);
  useEffect(() => {
    if (fetchValuesRef.current !== fetchValues) {
      fetchValuesRef.current = fetchValues;
      valueCacheRef.current.clear();
    }
  }, [fetchValues]);

  // Re-parse token context from current input + cursor.
  // Uses functional setState to avoid setting a new object when the content
  // is identical — prevents the suggestions effect from re-firing needlessly
  // (and cancelling in-flight fetches) on clicks/focus within the input.
  const updateContext = useCallback(() => {
    const input = inputRef.current;
    if (!input) return;
    const cursor = input.selectionStart ?? value.length;
    const next = getTokenAtCursor(value, cursor);
    setTokenCtx((prev) => {
      if (
        prev.type === next.type &&
        prev.type !== "none" &&
        next.type !== "none" &&
        prev.partial === next.partial &&
        prev.start === next.start &&
        prev.end === next.end &&
        (prev.type === "field"
          ? next.type === "field"
          : prev.type === "value" &&
            next.type === "value" &&
            prev.field === next.field)
      ) {
        return prev; // same reference → no re-render
      }
      return next;
    });
  }, [value]);

  // Update context when value changes
  useEffect(() => {
    updateContext();
  }, [updateContext]);

  // Compute suggestions from tokenCtx
  useEffect(() => {
    if (tokenCtx.type === "none") {
      setSuggestions([]);
      setLoading(false);
      return;
    }

    if (tokenCtx.type === "field") {
      const lower = tokenCtx.partial.toLowerCase();
      const matches = discoveredFields
        .map((f) => f.field)
        .filter((f) => f.toLowerCase().includes(lower));
      setSuggestions(matches);
      setSelectedIdx(0);
      setLoading(false);
      return;
    }

    // tokenCtx.type === "value"
    const { field, partial } = tokenCtx;
    const cached = valueCacheRef.current.get(field);
    if (cached) {
      const lower = partial.toLowerCase();
      setSuggestions(
        lower ? cached.filter((v) => v.toLowerCase().includes(lower)) : cached,
      );
      setSelectedIdx(0);
      setLoading(false);
      return;
    }

    // Fetch values
    setLoading(true);
    setSuggestions([]);
    let cancelled = false;
    fetchValues(field)
      .then((values) => {
        if (cancelled) return;
        valueCacheRef.current.set(field, values);
        const lower = partial.toLowerCase();
        setSuggestions(
          lower
            ? values.filter((v) => v.toLowerCase().includes(lower))
            : values,
        );
        setSelectedIdx(0);
      })
      .catch(() => {
        if (!cancelled) setSuggestions([]);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [tokenCtx, discoveredFields, fetchValues]);

  const showDropdown =
    tokenCtx.type !== "none" && (suggestions.length > 0 || loading);

  function applySelection(item: string) {
    if (tokenCtx.type === "none") return;
    const { newQuery, newCursor } = applyCompletion(value, tokenCtx, item);
    onChange(newQuery);
    // Set cursor position after React re-renders
    requestAnimationFrame(() => {
      const input = inputRef.current;
      if (input) {
        input.setSelectionRange(newCursor, newCursor);
        input.focus();
      }
    });
  }

  function handleKeyDown(e: React.KeyboardEvent<HTMLInputElement>) {
    if ((e.key === "Enter" && (e.ctrlKey || e.metaKey)) || (e.key === "Enter" && !showDropdown)) {
      e.preventDefault();
      setSuggestions([]);
      setTokenCtx({ type: "none" });
      onSubmit();
      return;
    }

    if (!showDropdown) return;

    if (e.key === "ArrowDown") {
      e.preventDefault();
      setSelectedIdx((i) => Math.min(i + 1, suggestions.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setSelectedIdx((i) => Math.max(i - 1, 0));
    } else if (e.key === "Tab" || e.key === "Enter") {
      e.preventDefault();
      if (suggestions.length > 0) {
        applySelection(suggestions[selectedIdx]);
      }
    } else if (e.key === "Escape") {
      e.preventDefault();
      setSuggestions([]);
      setTokenCtx({ type: "none" });
    }
  }

  return (
    <div className="relative flex-1">
      <input
        ref={inputRef}
        type="text"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        onKeyDown={handleKeyDown}
        onClick={updateContext}
        onFocus={updateContext}
        onBlur={() => {
          // Delay to allow mousedown on dropdown items
          setTimeout(() => {
            setSuggestions([]);
            setTokenCtx({ type: "none" });
          }, 150);
        }}
        placeholder='service_name:"api" AND severity_number:>8'
        className="h-7 w-full rounded-md border border-input bg-transparent px-2 font-mono text-xs text-foreground outline-none placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 dark:bg-input/30"
      />
      {showDropdown && (
        <div className="absolute left-0 right-0 top-full z-50 mt-1 max-h-48 overflow-y-auto rounded-md border border-border bg-popover py-1 shadow-md">
          {loading && suggestions.length === 0 ? (
            <div className="flex items-center justify-center gap-1.5 px-3 py-4 text-xs text-muted-foreground">
              <Loader2 className="h-3.5 w-3.5 animate-spin" />
              Loading values...
            </div>
          ) : (
            suggestions.map((item, i) => (
              <button
                key={item}
                onMouseDown={(e) => {
                  e.preventDefault(); // Prevent input blur
                  applySelection(item);
                }}
                className={`flex w-full items-center px-3 py-1.5 text-left text-xs ${
                  i === selectedIdx
                    ? "bg-muted text-foreground"
                    : "text-foreground hover:bg-muted"
                }`}
              >
                <span className="truncate font-mono">{item}</span>
                {tokenCtx.type === "field" && (
                  <span className="ml-auto pl-2 text-[10px] text-muted-foreground">
                    {discoveredFields.find((f) => f.field === item)?.kind}
                  </span>
                )}
              </button>
            ))
          )}
        </div>
      )}
    </div>
  );
}
