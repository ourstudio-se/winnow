import { LogOut } from "lucide-react";
import { useLocation } from "react-router";
import { cn } from "@/lib/utils";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { resolveAuthUrl } from "@/lib/auth";
import { useUiConfig } from "@/lib/config";

/**
 * Sidebar logout link. Rendered only when the winnow config declares a
 * logout URL for the api authorizer.
 */
export function LogoutButton({ collapsed }: { collapsed: boolean }) {
  const config = useUiConfig();
  // Subscribe to route changes so a {winnow_return_url} placeholder in the
  // logout URL is re-resolved against the page the user is actually on.
  useLocation();

  if (!config?.logout_url) return null;

  const link = (
    <a
      href={resolveAuthUrl(config.logout_url)}
      className={cn(
        "flex items-center rounded-md text-muted-foreground transition-colors hover:bg-accent/60 hover:text-accent-foreground",
        collapsed
          ? "mx-auto h-8 w-8 shrink-0 justify-center"
          : "gap-2 px-2 py-1.5 text-sm",
      )}
    >
      <LogOut className="h-4 w-4 shrink-0" />
      {!collapsed && <span>Log out</span>}
    </a>
  );

  if (!collapsed) return link;

  return (
    <Tooltip>
      <TooltipTrigger asChild>{link}</TooltipTrigger>
      <TooltipContent side="right">Log out</TooltipContent>
    </Tooltip>
  );
}
