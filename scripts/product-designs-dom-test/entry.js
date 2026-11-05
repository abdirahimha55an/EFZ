// Bundled by run.mjs. Mounts the REAL /admin/product-designs page (only lib/supabase/db is stubbed) so jsdom can drive it.
import { createElement } from "react";
import { act } from "react";
import { createRoot } from "react-dom/client";
import Page from "@/app/admin/product-designs/page";

export { act };

export function mount(container) {
  const root = createRoot(container);
  act(() => root.render(createElement(Page)));
  return () => act(() => root.unmount());
}
