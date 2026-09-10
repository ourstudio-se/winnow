import { ShieldOff, RotateCcw, LogOut } from "lucide-react";
import { Button } from "@/components/ui/button";
import { retryLogin, resolveAuthUrl, type AuthFailure } from "@/lib/auth";
import { useUiConfig } from "@/lib/config";

const copy: Record<AuthFailure, { title: string; body: string }> = {
  forbidden: {
    title: "You do not have permission to view telemetry",
    body:
      "Your account is signed in, but it lacks access to this Winnow " +
      "workspace. Contact your administrator, or sign in with a " +
      "different account.",
  },
  login_loop: {
    title: "Signing in didn't stick",
    body:
      "The login flow completed, but Winnow is still not receiving valid " +
      "credentials. This usually means the login server did not set the " +
      "expected session cookie. Fix the login setup, then retry.",
  },
};

/**
 * Full-screen page for auth failures: 403 (forbidden) or a detected
 * login loop (401 straight after returning from the login flow).
 */
export function AuthErrorView({
  kind,
  onRetry,
}: {
  kind: AuthFailure;
  onRetry: () => void;
}) {
  const config = useUiConfig();

  const retry =
    kind === "login_loop" ? () => void retryLogin() : onRetry;

  return (
    <div className="flex h-screen flex-col items-center justify-center gap-6 bg-background px-6 text-center">
      <div className="flex h-20 w-20 items-center justify-center rounded-full bg-muted">
        <ShieldOff className="h-10 w-10 text-muted-foreground" />
      </div>
      <div className="flex max-w-md flex-col gap-2">
        <h1 className="text-2xl font-semibold tracking-tight">
          {copy[kind].title}
        </h1>
        <p className="text-sm text-muted-foreground">{copy[kind].body}</p>
      </div>
      <div className="flex gap-3">
        <Button onClick={retry}>
          <RotateCcw className="h-4 w-4" />
          Retry
        </Button>
        {config?.logout_url && (
          <Button asChild variant="outline">
            <a href={resolveAuthUrl(config.logout_url)}>
              <LogOut className="h-4 w-4" />
              Log out
            </a>
          </Button>
        )}
      </div>
    </div>
  );
}
