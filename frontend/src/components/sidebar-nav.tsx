import { NavLink } from "react-router";
import { Map, ListTree, FileText } from "lucide-react";
import { cn } from "@/lib/utils";
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip";

const navItems = [
  { to: "/", icon: Map, label: "Service Map" },
  { to: "/traces", icon: ListTree, label: "Traces" },
  { to: "/logs", icon: FileText, label: "Logs" },
] as const;

export function SidebarNav({ collapsed }: { collapsed: boolean }) {
  return (
    <TooltipProvider>
      <nav className="flex flex-col gap-1">
        {navItems.map((item) =>
          collapsed ? (
            <Tooltip key={item.to}>
              <TooltipTrigger asChild>
                <NavLink
                  to={item.to}
                  end={item.to === "/"}
                  className={({ isActive }) =>
                    cn(
                      "mx-auto flex h-8 w-8 shrink-0 items-center justify-center rounded-md transition-colors",
                      isActive
                        ? "bg-accent text-accent-foreground"
                        : "text-muted-foreground hover:bg-accent/60 hover:text-accent-foreground",
                    )
                  }
                >
                  <item.icon className="h-4 w-4" />
                </NavLink>
              </TooltipTrigger>
              <TooltipContent side="right" sideOffset={8}>
                {item.label}
              </TooltipContent>
            </Tooltip>
          ) : (
            <NavLink
              key={item.to}
              to={item.to}
              end={item.to === "/"}
              className={({ isActive }) =>
                cn(
                  "flex items-center gap-2 rounded-md px-3 py-1.5 text-sm font-medium transition-colors",
                  isActive
                    ? "bg-accent text-accent-foreground"
                    : "text-muted-foreground hover:bg-accent hover:text-accent-foreground",
                )
              }
            >
              <item.icon className="h-4 w-4 shrink-0" />
              <span>{item.label}</span>
            </NavLink>
          ),
        )}
      </nav>
    </TooltipProvider>
  );
}
