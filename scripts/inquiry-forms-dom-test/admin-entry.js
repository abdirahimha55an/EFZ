// Bundled by admin-run.mjs. Mounts the REAL InquiriesInbox (list, filters, detail, actions); only the data layer and next/navigation are stubbed.
import { createElement } from "react";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { InquiriesInbox } from "@/components/admin/inquiries/InquiriesInbox";
import { RequestSignalContext } from "@/components/admin/requests/RequestSignal";

export { act };

export function mount(container) {
  const root = createRoot(container);
  const value = { version: 0, openCount: null, refresh: () => { globalThis.__refreshed = (globalThis.__refreshed ?? 0) + 1; } };
  act(() => root.render(createElement(RequestSignalContext.Provider, { value }, createElement(InquiriesInbox))));
  return () => act(() => root.unmount());
}
