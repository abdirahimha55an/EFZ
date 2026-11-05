// Bundled by run.mjs. Mounts the REAL /order page (only lib/supabase/db is stubbed) so jsdom can drive it.
import { createElement } from "react";
import { act } from "react";
import { createRoot } from "react-dom/client";
import OrderPage from "@/app/order/page";

export { act };

export function mount(container) {
  const root = createRoot(container);
  act(() => root.render(createElement(OrderPage)));
  return () => act(() => root.unmount());
}
