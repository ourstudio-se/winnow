import { Outlet } from "react-router";
import { Separator } from "@/components/ui/separator";
import { SidebarNav } from "@/components/sidebar-nav";

export function Layout() {
  return (
    <div className="flex h-screen">
      {/* Sidebar */}
      <aside className="flex w-56 shrink-0 flex-col border-r bg-card">
        <div className="flex h-14 items-center px-4">
          <span className="text-lg font-bold tracking-tight">Winnow</span>
        </div>
        <Separator />
        <div className="flex-1 overflow-y-auto px-3 py-3">
          <SidebarNav />
        </div>
      </aside>

      {/* Main content */}
      <main className="flex flex-1 flex-col overflow-hidden">
        <Outlet />
      </main>
    </div>
  );
}
