import { useCallback, useEffect, useState } from "react";
import { Outlet } from "react-router";
import { SidebarNav } from "@/components/sidebar-nav";
import logoExpanded from "@/assets/winnow_logo_dark_expanded.png";
import logoCollapsed from "@/assets/winnow_logo_dark_collapsed.png";

function readCollapsed(): boolean {
  try {
    return localStorage.getItem("winnow-sidebar-collapsed") === "true";
  } catch {
    return false;
  }
}

export function Layout() {
  const [collapsed, setCollapsed] = useState(readCollapsed);

  const toggle = useCallback(() => {
    setCollapsed((prev) => {
      const next = !prev;
      try {
        localStorage.setItem("winnow-sidebar-collapsed", String(next));
      } catch {
        // ignore
      }
      return next;
    });
  }, []);

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "b") {
        e.preventDefault();
        toggle();
      }
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [toggle]);

  return (
    <div className="flex h-screen">
      <aside
        className={`flex shrink-0 flex-col overflow-hidden border-r bg-card transition-[width] duration-200 ${collapsed ? "w-12" : "w-56"}`}
      >
        <button
          onClick={toggle}
          className="relative h-14 shrink-0 border-b border-border overflow-hidden cursor-pointer"
        >
          <img
            src={logoExpanded}
            alt="Winnow"
            className={`absolute inset-0 m-auto h-9 object-contain transition-opacity duration-200 ${collapsed ? "opacity-0" : "opacity-100"}`}
          />
          <img
            src={logoCollapsed}
            alt="Winnow"
            className={`absolute inset-0 m-auto h-6 object-contain transition-opacity duration-200 ${collapsed ? "opacity-100" : "opacity-0"}`}
          />
        </button>
        <div className={`flex flex-1 flex-col overflow-hidden py-3 ${collapsed ? "items-center" : "px-2"}`}>
          <SidebarNav collapsed={collapsed} />
        </div>
      </aside>
      <main className="flex flex-1 flex-col overflow-hidden">
        <Outlet />
      </main>
    </div>
  );
}
