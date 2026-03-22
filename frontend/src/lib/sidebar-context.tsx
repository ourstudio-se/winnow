import { createContext, useContext, useState, type ReactNode } from "react";

interface SidebarPanelContextValue {
  panelContent: ReactNode;
  setPanelContent: (content: ReactNode) => void;
}

const SidebarPanelContext = createContext<SidebarPanelContextValue | null>(null);

export function SidebarPanelProvider({ children }: { children: ReactNode }) {
  const [panelContent, setPanelContent] = useState<ReactNode>(null);
  return (
    <SidebarPanelContext.Provider value={{ panelContent, setPanelContent }}>
      {children}
    </SidebarPanelContext.Provider>
  );
}

export function useSidebarPanel() {
  const ctx = useContext(SidebarPanelContext);
  if (!ctx) throw new Error("useSidebarPanel must be used within SidebarPanelProvider");
  return ctx;
}
