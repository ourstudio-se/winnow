import { useEffect, useState } from "react";

export interface UiConfig {
  login_url: string | null;
  logout_url: string | null;
}

const emptyConfig: UiConfig = { login_url: null, logout_url: null };

let configPromise: Promise<UiConfig> | null = null;

/**
 * Fetch the UI bootstrap config (login/logout URLs from the winnow config).
 * The endpoint is served outside the auth gate, so this works while logged
 * out. Cached for the lifetime of the page; failures resolve to an empty
 * config so the app degrades to its unauthenticated behavior.
 */
export function getUiConfig(): Promise<UiConfig> {
  configPromise ??= fetch("/api/v1/ui-config")
    .then((res): Promise<UiConfig> | UiConfig =>
      res.ok ? res.json() : emptyConfig,
    )
    .catch(() => emptyConfig);
  return configPromise;
}

export function useUiConfig(): UiConfig | null {
  const [config, setConfig] = useState<UiConfig | null>(null);

  useEffect(() => {
    let alive = true;
    void getUiConfig().then((cfg) => {
      if (alive) setConfig(cfg);
    });
    return () => {
      alive = false;
    };
  }, []);

  return config;
}
