import { useState } from "react";
import {
  DndContext,
  closestCenter,
  KeyboardSensor,
  PointerSensor,
  useSensor,
  useSensors,
  type DragEndEvent,
} from "@dnd-kit/core";
import {
  SortableContext,
  sortableKeyboardCoordinates,
  useSortable,
  verticalListSortingStrategy,
  arrayMove,
} from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import { GripVertical, X, Search } from "lucide-react";
import { type LogColumnDef, PSEUDO_COLUMNS } from "@/lib/logs";
import { cn } from "@/lib/utils";

interface ColumnSelectorProps {
  activeColumns: string[];
  availableData: LogColumnDef[];
  onColumnsChange: (columns: string[]) => void;
}

export function ColumnSelector({
  activeColumns,
  availableData,
  onColumnsChange,
}: ColumnSelectorProps) {
  const [fieldSearch, setFieldSearch] = useState("");

  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 4 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  );

  const activeSet = new Set(activeColumns);

  // Pseudo columns not currently active
  const availablePseudo = PSEUDO_COLUMNS.filter((c) => !activeSet.has(c.id));

  // Data columns not currently active, filtered by search
  const lowerSearch = fieldSearch.toLowerCase();
  const filteredData = availableData.filter(
    (c) => !activeSet.has(c.id) && (!lowerSearch || c.label.toLowerCase().includes(lowerSearch)),
  );

  function handleDragEnd(event: DragEndEvent) {
    const { active, over } = event;
    if (over && active.id !== over.id) {
      const oldIndex = activeColumns.indexOf(active.id as string);
      const newIndex = activeColumns.indexOf(over.id as string);
      onColumnsChange(arrayMove(activeColumns, oldIndex, newIndex));
    }
  }

  function addColumn(id: string) {
    onColumnsChange([...activeColumns, id]);
  }

  function removeColumn(id: string) {
    onColumnsChange(activeColumns.filter((c) => c !== id));
  }

  // Resolve label for an active column id
  function getLabel(id: string): string {
    const pseudo = PSEUDO_COLUMNS.find((c) => c.id === id);
    if (pseudo) return pseudo.label;
    const data = availableData.find((c) => c.id === id);
    if (data) return data.label;
    return id;
  }

  return (
    <div className="flex flex-col gap-3 text-xs">
      {/* Active columns */}
      <div>
        <div className="mb-1.5 font-medium text-muted-foreground">Columns</div>
        <DndContext
          sensors={sensors}
          collisionDetection={closestCenter}
          onDragEnd={handleDragEnd}
        >
          <SortableContext items={activeColumns} strategy={verticalListSortingStrategy}>
            <div className="flex flex-col gap-0.5">
              {activeColumns.map((id) => (
                <SortableColumn
                  key={id}
                  id={id}
                  label={getLabel(id)}
                  onRemove={() => removeColumn(id)}
                />
              ))}
            </div>
          </SortableContext>
        </DndContext>
      </div>

      {/* Available pseudo columns */}
      {availablePseudo.length > 0 && (
        <div>
          <div className="mb-1.5 font-medium text-muted-foreground">Display</div>
          <div className="flex flex-col gap-0.5">
            {availablePseudo.map((col) => (
              <button
                key={col.id}
                onClick={() => addColumn(col.id)}
                className="rounded px-2 py-1 text-left text-foreground/80 hover:bg-accent hover:text-accent-foreground"
              >
                {col.label}
              </button>
            ))}
          </div>
        </div>
      )}

      {/* Available data fields */}
      <div className="flex min-h-0 flex-col">
        <div className="mb-1.5 font-medium text-muted-foreground">Fields</div>
        <div className="relative mb-1.5">
          <Search className="absolute left-2 top-1/2 h-3 w-3 -translate-y-1/2 text-muted-foreground" />
          <input
            type="text"
            value={fieldSearch}
            onChange={(e) => setFieldSearch(e.target.value)}
            placeholder="Filter fields..."
            className="w-full rounded border border-border bg-background py-1 pl-7 pr-2 text-xs text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-1 focus:ring-ring"
          />
        </div>
        <div className="flex flex-col gap-0.5 overflow-y-auto">
          {filteredData.length === 0 ? (
            <div className="px-2 py-1 text-muted-foreground">
              {availableData.length === 0 ? "No data fields found" : "No matching fields"}
            </div>
          ) : (
            filteredData.map((col) => (
              <button
                key={col.id}
                onClick={() => addColumn(col.id)}
                className="truncate rounded px-2 py-1 text-left font-mono text-foreground/80 hover:bg-accent hover:text-accent-foreground"
                title={col.label}
              >
                {col.label}
              </button>
            ))
          )}
        </div>
      </div>
    </div>
  );
}

function SortableColumn({
  id,
  label,
  onRemove,
}: {
  id: string;
  label: string;
  onRemove: () => void;
}) {
  const {
    attributes,
    listeners,
    setNodeRef,
    transform,
    transition,
    isDragging,
  } = useSortable({ id });

  const style = {
    transform: CSS.Transform.toString(transform),
    transition,
  };

  return (
    <div
      ref={setNodeRef}
      style={style}
      className={cn(
        "flex items-center gap-1 rounded bg-accent/50 px-1.5 py-1",
        isDragging && "z-50 opacity-50",
      )}
    >
      <button
        className="cursor-grab touch-none text-muted-foreground hover:text-foreground"
        {...attributes}
        {...listeners}
      >
        <GripVertical className="h-3 w-3" />
      </button>
      <span className="flex-1 truncate">{label}</span>
      <button
        onClick={onRemove}
        className="text-muted-foreground hover:text-foreground"
      >
        <X className="h-3 w-3" />
      </button>
    </div>
  );
}
