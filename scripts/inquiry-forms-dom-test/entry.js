// Bundled by run.mjs. Mounts the REAL ContactForm / WholesaleForm (only lib/supabase/db is stubbed) so jsdom can drive them.
import { createElement } from "react";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { ContactForm } from "@/components/public/ContactForm";
import { WholesaleForm } from "@/components/public/WholesaleForm";

export { act };

export function mount(kind, container) {
  const root = createRoot(container);
  const form = kind === "contact" ? ContactForm : WholesaleForm;
  act(() => root.render(createElement(form, { whatsappUrl: "https://wa.me/252614129991?text=hi" })));
  return () => act(() => root.unmount());
}
