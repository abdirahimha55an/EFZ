/**
 * 32: the pure rules behind the Product Designs screen, kept out of the page so they can be tested (npm run test:hub).
 * They mirror what the database enforces (guard_product_design() and the table's checks) only to give staff a clear sentence before the round trip;
 * the database is the authority and refuses the same things whichever screen is used.
 */
import type { Product, ProductDesign } from "@/lib/types";

export const NAME_MAX = 120;
export const IMAGE_MAX = 500;
export const ORDER_MAX = 100000;

export type DesignDraft = { productId: string; name: string; imageUrl: string; sortOrder: string };
export const EMPTY_DRAFT: DesignDraft = { productId: "", name: "", imageUrl: "", sortOrder: "0" };

export type DesignErrors = Partial<Record<"productId" | "name" | "imageUrl" | "sortOrder", string>>;

/** The image link must be empty or an https:// address without spaces, at most 500 characters. */
export function imageProblem(raw: string): string | null {
  const v = raw.trim();
  if (v === "") return null;
  if (v.length > IMAGE_MAX) return `The image link is too long (at most ${IMAGE_MAX} characters)`;
  if (!/^https:\/\/[^\s]+$/.test(v)) return "The image link must start with https:// and contain no spaces";
  return null;
}

/** Same name on the same product, ignoring case and surrounding spaces (the database has a unique index on exactly this). */
export function nameTaken(designs: ProductDesign[], productId: string, name: string, exceptId?: string): boolean {
  const want = name.trim().toLowerCase();
  return want !== "" && designs.some((d) => d.productId === productId && d.id !== exceptId && d.name.trim().toLowerCase() === want);
}

export function validateDraft(draft: DesignDraft, designs: ProductDesign[], opts: { editingId?: string } = {}): { ok: true; value: { productId: string; name: string; imageUrl: string; sortOrder: number } } | { ok: false; errors: DesignErrors } {
  const errors: DesignErrors = {};
  const name = draft.name.trim();
  if (!draft.productId) errors.productId = "Choose the product this design belongs to";
  if (name === "") errors.name = "Enter the design name";
  else if (name.length > NAME_MAX) errors.name = `The name is too long (at most ${NAME_MAX} characters)`;
  else if (draft.productId && nameTaken(designs, draft.productId, name, opts.editingId)) errors.name = "This product already has a design with that name";
  const img = imageProblem(draft.imageUrl);
  if (img) errors.imageUrl = img;
  const rawOrder = draft.sortOrder.trim() === "" ? "0" : draft.sortOrder.trim();
  const order = /^\d{1,6}$/.test(rawOrder) ? Number(rawOrder) : NaN;
  if (!Number.isInteger(order) || order < 0 || order > ORDER_MAX) errors.sortOrder = `The display order must be a whole number from 0 to ${ORDER_MAX}`;
  if (Object.keys(errors).length) return { ok: false, errors };
  return { ok: true, value: { productId: draft.productId, name, imageUrl: draft.imageUrl.trim(), sortOrder: order } };
}

export type DesignFilter = { productId: string; status: "all" | "active" | "inactive"; search: string };

export function filterDesigns(designs: ProductDesign[], f: DesignFilter): ProductDesign[] {
  const q = f.search.trim().toLowerCase();
  return designs.filter((d) => (!f.productId || d.productId === f.productId)
    && (f.status === "all" || (f.status === "active") === d.isActive)
    && (q === "" || d.name.toLowerCase().includes(q)));
}

/** Designs grouped by product name, products with none left out; display order, then name, within a group. */
export function groupByProduct(designs: ProductDesign[], products: Pick<Product, "id" | "name">[]): { productId: string; productName: string; designs: ProductDesign[] }[] {
  const nameOf = new Map(products.map((p) => [p.id, p.name]));
  const groups = new Map<string, ProductDesign[]>();
  for (const d of designs) (groups.get(d.productId) ?? groups.set(d.productId, []).get(d.productId)!).push(d);
  return [...groups.entries()]
    .map(([productId, ds]) => ({ productId, productName: nameOf.get(productId) ?? productId, designs: [...ds].sort((a, b) => a.sortOrder - b.sortOrder || a.name.localeCompare(b.name)) }))
    .sort((a, b) => a.productName.localeCompare(b.productName));
}

/** How many designs of each product are visible on the order form (active ones). */
export const activeCount = (designs: ProductDesign[], productId: string): number => designs.filter((d) => d.productId === productId && d.isActive).length;
