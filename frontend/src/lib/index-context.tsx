import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import { type IndexMap, listIndexes } from "./api";

const IndexContext = createContext<IndexMap | null>(null);

export function IndexProvider({ children }: { children: ReactNode }) {
  const [indexes, setIndexes] = useState<IndexMap | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    listIndexes()
      .then(setIndexes)
      .catch((e) => setError(e.message ?? "Failed to load indexes"));
  }, []);

  if (error) {
    return (
      <div className="flex h-screen items-center justify-center text-destructive">
        Failed to connect: {error}
      </div>
    );
  }

  if (!indexes) {
    return (
      <div className="flex h-screen items-center justify-center text-muted-foreground">
        Connecting...
      </div>
    );
  }

  return (
    <IndexContext.Provider value={indexes}>{children}</IndexContext.Provider>
  );
}

export function useIndexes(): IndexMap {
  const ctx = useContext(IndexContext);
  if (!ctx) throw new Error("useIndexes must be used within IndexProvider");
  return ctx;
}
