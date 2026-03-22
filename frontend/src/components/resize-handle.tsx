import { useCallback, type MouseEvent as ReactMouseEvent } from "react";

const MIN_COL_WIDTH = 60;

export function ResizeHandle({
  width,
  onResize,
  onResizeEnd,
}: {
  width: number;
  onResize: (w: number) => void;
  onResizeEnd: (w: number) => void;
}) {
  const handleMouseDown = useCallback(
    (e: ReactMouseEvent) => {
      e.preventDefault();
      e.stopPropagation();
      const startX = e.clientX;
      const startWidth = width;

      const onMouseMove = (ev: globalThis.MouseEvent) => {
        const newW = Math.max(MIN_COL_WIDTH, startWidth + (ev.clientX - startX));
        onResize(newW);
      };

      const onMouseUp = (ev: globalThis.MouseEvent) => {
        document.removeEventListener("mousemove", onMouseMove);
        document.removeEventListener("mouseup", onMouseUp);
        const finalW = Math.max(
          MIN_COL_WIDTH,
          startWidth + (ev.clientX - startX),
        );
        onResizeEnd(finalW);
      };

      document.addEventListener("mousemove", onMouseMove);
      document.addEventListener("mouseup", onMouseUp);
    },
    [width, onResize, onResizeEnd],
  );

  return (
    <div
      onMouseDown={handleMouseDown}
      className="absolute right-0 top-0 h-full w-1.5 cursor-col-resize hover:bg-border"
    />
  );
}
