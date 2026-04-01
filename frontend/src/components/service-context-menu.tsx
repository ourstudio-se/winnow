import { useEffect, useRef } from "react";
import { useNavigate } from "react-router";
import { FileText, Activity, ChevronRight, AlertTriangle } from "lucide-react";
import type { ServiceKind } from "@/lib/service-graph";

interface ServiceContextMenuProps {
  serviceName: string;
  x: number;
  y: number;
  hasErrors: boolean;
  isImplicit: boolean;
  serviceKind: ServiceKind;
  onClose: () => void;
  onDrilldown: (errorsOnly: boolean) => void;
}

/** Build a Tantivy query to find PRODUCER/CONSUMER spans for a messaging topic. */
function messagingTopicQuery(nodeName: string): string {
  // Extract topic from "system/topic" or use as-is
  const topic = nodeName.includes("/")
    ? nodeName.slice(nodeName.indexOf("/") + 1)
    : nodeName;
  // Search across common attribute keys (OTel semconv + bare kafka.*)
  const topicClauses = [
    `span_attributes.messaging.destination.name:"${topic}"`,
    `span_attributes.messaging.destination:"${topic}"`,
    `span_attributes.messaging.kafka.topic:"${topic}"`,
    `span_attributes.kafka.topic:"${topic}"`,
  ].join(" OR ");
  return `(span_kind:4 OR span_kind:5) AND (${topicClauses})`;
}

export function ServiceContextMenu({
  serviceName,
  x,
  y,
  hasErrors,
  isImplicit,
  serviceKind,
  onClose,
  onDrilldown,
}: ServiceContextMenuProps) {
  const navigate = useNavigate();
  const menuRef = useRef<HTMLDivElement>(null);

  // Clamp position to keep menu within viewport
  const clampedPos = useRef({ x, y });
  useEffect(() => {
    const el = menuRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    const cx = Math.min(x, window.innerWidth - rect.width - 8);
    const cy = Math.min(y, window.innerHeight - rect.height - 8);
    clampedPos.current = { x: Math.max(8, cx), y: Math.max(8, cy) };
    el.style.left = `${clampedPos.current.x}px`;
    el.style.top = `${clampedPos.current.y}px`;
  }, [x, y]);

  // Close on outside click
  useEffect(() => {
    function handleClick(e: MouseEvent) {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        onClose();
      }
    }
    // Delay to avoid catching the click that opened the menu
    const id = requestAnimationFrame(() => {
      document.addEventListener("mousedown", handleClick);
    });
    return () => {
      cancelAnimationFrame(id);
      document.removeEventListener("mousedown", handleClick);
    };
  }, [onClose]);

  // Close on Escape
  useEffect(() => {
    function handleKey(e: KeyboardEvent) {
      if (e.key === "Escape") onClose();
    }
    document.addEventListener("keydown", handleKey);
    return () => document.removeEventListener("keydown", handleKey);
  }, [onClose]);

  return (
    <div
      ref={menuRef}
      className="fixed z-50 min-w-[200px] rounded-lg bg-popover p-1 shadow-md ring-1 ring-foreground/10"
      style={{ left: x, top: y }}
    >
      <div className="px-2 py-1.5 text-xs font-medium text-muted-foreground">
        {serviceName}
      </div>
      {!isImplicit && (
        <MenuItem
          icon={<FileText className="h-4 w-4" />}
          label="Show logs"
          onClick={() => {
            onClose();
            navigate(`/logs?f=${encodeURIComponent(`service_name:${serviceName}`)}`);
          }}
        />
      )}
      <MenuItem
        icon={<Activity className="h-4 w-4" />}
        label="Show traces"
        onClick={() => {
          onClose();
          if (serviceKind === "messaging") {
            navigate(`/traces?q=${encodeURIComponent(messagingTopicQuery(serviceName))}`);
          } else if (isImplicit) {
            navigate(`/traces?q=${encodeURIComponent(`span_attributes.peer.service:"${serviceName}" OR span_attributes.db.system:"${serviceName}"`)}`);
          } else {
            navigate(`/traces?f=${encodeURIComponent(`service_name:${serviceName}`)}`);
          }
        }}
      />
      <div className="mx-1 my-1 border-t border-border" />
      <MenuItem
        icon={<ChevronRight className="h-4 w-4" />}
        label="Operations overview"
        onClick={() => {
          onClose();
          onDrilldown(false);
        }}
      />
      {hasErrors && (
        <MenuItem
          icon={<AlertTriangle className="h-4 w-4" />}
          label="Operations — errors only"
          onClick={() => {
            onClose();
            onDrilldown(true);
          }}
        />
      )}
    </div>
  );
}

function MenuItem({
  icon,
  label,
  onClick,
}: {
  icon: React.ReactNode;
  label: string;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-sm text-foreground hover:bg-muted"
    >
      <span className="text-muted-foreground">{icon}</span>
      {label}
    </button>
  );
}
