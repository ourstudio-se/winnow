import { Outlet } from "react-router";
import { Separator } from "@/components/ui/separator";
import { SidebarNav } from "@/components/sidebar-nav";
import { SidebarPanelProvider, useSidebarPanel } from "@/lib/sidebar-context";

export function Layout() {
  return (
    <SidebarPanelProvider>
      <div className="flex h-screen">
        <Sidebar />
        {/* Main content */}
        <main className="flex flex-1 flex-col overflow-hidden">
          <Outlet />
        </main>
      </div>
    </SidebarPanelProvider>
  );
}

function Sidebar() {
  const { panelContent } = useSidebarPanel();
  return (
    <aside className="flex w-56 shrink-0 flex-col border-r bg-card">
      <div className="flex h-14 shrink-0 items-center border-b border-border px-4">
        <span className="text-lg font-bold tracking-tight">Winnow</span>
      </div>
      <div className="flex flex-col overflow-y-auto px-3 py-3">
        <SidebarNav />
      </div>
      {panelContent && (
        <>
          <Separator />
          <div className="flex flex-1 flex-col overflow-y-auto px-3 py-3">
            {panelContent}
          </div>
        </>
      )}
    </aside>
  );
}
