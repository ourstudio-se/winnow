import { getUiConfig } from "@/lib/config";

/**
 * "forbidden": backend answered 403 — signed in but no permission.
 * "login_loop": we came back from the login flow (the return URL carries
 * RELOGIN_PARAM) and still get 401 — the login server didn't produce a
 * usable session; redirecting again would loop forever.
 */
export type AuthFailure = "forbidden" | "login_loop";

type AuthFailureListener = (failure: AuthFailure) => void;

const failureListeners = new Set<AuthFailureListener>();

/** Subscribe to auth failures from the API layer. Returns an unsubscribe fn. */
export function onAuthFailure(listener: AuthFailureListener): () => void {
  failureListeners.add(listener);
  return () => failureListeners.delete(listener);
}

export function signalForbidden(): void {
  for (const listener of failureListeners) listener("forbidden");
}

/**
 * Marker appended to the return URL before redirecting to login. If it's
 * present on the current URL and we get another 401, the login round
 * didn't stick — surface an error instead of redirecting again.
 */
const RELOGIN_PARAM = "winnow_relogin";

function currentUrlHasReloginMarker(): boolean {
  return new URL(window.location.href).searchParams.has(RELOGIN_PARAM);
}

/** Drop the marker after auth is known to work, so it doesn't linger in
 * copied links or block a legitimate re-login hours later. */
export function clearReloginMarker(): void {
  if (!currentUrlHasReloginMarker()) return;
  const url = new URL(window.location.href);
  url.searchParams.delete(RELOGIN_PARAM);
  window.history.replaceState(window.history.state, "", url);
}

/**
 * Login/logout URLs from the winnow config may carry a `{winnow_return_url}`
 * placeholder (e.g. `https://idp/login?redirect_to={winnow_return_url}`).
 * The backend sends the template as-is; we substitute the current location,
 * URI-encoded, at the moment the URL is used. For login redirects the
 * return URL additionally carries RELOGIN_PARAM (see above).
 */
export function resolveAuthUrl(
  template: string,
  opts?: { markRelogin?: boolean },
): string {
  const returnUrl = new URL(window.location.href);
  if (opts?.markRelogin) {
    returnUrl.searchParams.set(RELOGIN_PARAM, "1");
  }
  return template.replaceAll(
    "{winnow_return_url}",
    encodeURIComponent(returnUrl.toString()),
  );
}

let redirecting = false;

/**
 * Handle a 401: send the user to the configured login URL — unless the
 * current URL shows we just came back from one, in which case signal a
 * login loop instead of bouncing forever. No-op when no login URL is
 * configured (auth handled elsewhere, e.g. basic auth) or a redirect is
 * already in flight.
 */
export async function redirectToLogin(): Promise<void> {
  if (redirecting) return;
  const config = await getUiConfig();
  if (!config.login_url) return;
  if (currentUrlHasReloginMarker()) {
    for (const listener of failureListeners) listener("login_loop");
    return;
  }
  redirecting = true;
  window.location.assign(resolveAuthUrl(config.login_url, { markRelogin: true }));
}

/** Retry from the login-loop error page: forget the failed round and go
 * through the login flow again. */
export async function retryLogin(): Promise<void> {
  clearReloginMarker();
  redirecting = false;
  await redirectToLogin();
}
