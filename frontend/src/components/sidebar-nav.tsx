import { NavLink } from "react-router";
import { Map, ListTree, FileText } from "lucide-react";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";

const navItems = [
  { to: "/", icon: Map, label: "Service Map" },
  { to: "/traces", icon: ListTree, label: "Traces" },
  { to: "/logs", icon: FileText, label: "Logs" },
] as const;

export function SidebarNav() {
  return (
    <nav className="flex flex-col gap-1">
      {navItems.map((item) => (
        <Tooltip key={item.to}>
          <TooltipTrigger asChild>
            <NavLink
              to={item.to}
              end={item.to === "/"}
              className={({ isActive }) =>
                cn(
                  "flex items-center gap-2 rounded-md px-3 py-1.5 text-sm font-medium transition-colors",
                  "hover:bg-accent hover:text-accent-foreground",
                  isActive
                    ? "bg-accent text-accent-foreground"
                    : "text-muted-foreground",
                )
              }
            >
              <item.icon className="h-4 w-4 shrink-0" />
              <span>{item.label}</span>
            </NavLink>
          </TooltipTrigger>
          <TooltipContent side="right">{item.label}</TooltipContent>
        </Tooltip>
      ))}
    </nav>
  );
}
