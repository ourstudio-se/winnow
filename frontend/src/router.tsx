import { createBrowserRouter } from "react-router";
import { Layout } from "@/layout";
import { ServiceMapView } from "@/views/service-map";
import { TracesView } from "@/views/traces";
import { TraceDetailView } from "@/views/trace-detail";
import { LogsView } from "@/views/logs";

export const router = createBrowserRouter([
  {
    element: <Layout />,
    children: [
      { index: true, element: <ServiceMapView /> },
      { path: "traces", element: <TracesView /> },
      { path: "traces/:traceId", element: <TraceDetailView /> },
      { path: "logs", element: <LogsView /> },
    ],
  },
]);
