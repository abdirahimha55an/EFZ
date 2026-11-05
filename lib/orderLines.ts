/**
 * 32: the rules of the public order form's lines, kept out of the page so they can be tested (npm run test:hub).
 *
 * A line is a product, optionally a design of that product, and a quantity. A product that has active designs needs one chosen on its line;
 * a product with none is chosen alone. The same product may appear on several lines only with DIFFERENT designs (the database enforces the
 * same rule: a product + design pair may appear once). The price of a line is the product's price: a design has no price of its own.
 * Nothing here is authoritative: submit_order_request() re-checks everything, and EFZ confirms the final price when it converts the request.
 */
import type { Product, PublicDesign } from "@/lib/types";

export const MAX_LINES = 20;
export const MAX_QUANTITY = 100000;

export type OrderLine = { key: number; productId: string; designId: string; quantity: string };

export const newLine = (key: number): OrderLine => ({ key, productId: "", designId: "", quantity: "1" });

export const designsOf = (designs: PublicDesign[], productId: string): PublicDesign[] => designs.filter((d) => d.productId === productId);

/** A whole number from 1 to 100000, or null. Anything else (blank, 0, 2.5, 1e3, "12abc") is not a quantity. */
export function parseQuantity(raw: string): number | null {
  const t = raw.trim();
  if (!/^\d{1,6}$/.test(t)) return null;
  const n = Number(t);
  return n >= 1 && n <= MAX_QUANTITY ? n : null;
}

/** Is this product + design already chosen on another line? A product without a design is the pair (product, ""). */
export function pairTaken(lines: OrderLine[], exceptKey: number, productId: string, designId: string): boolean {
  return lines.some((l) => l.key !== exceptKey && l.productId === productId && l.designId === designId);
}

/** Can this product still be picked on this line: is at least one of its (design) choices free? */
export function productAvailable(lines: OrderLine[], exceptKey: number, productId: string, designs: PublicDesign[]): boolean {
  const ds = designsOf(designs, productId);
  return ds.length === 0 ? !pairTaken(lines, exceptKey, productId, "") : ds.some((d) => !pairTaken(lines, exceptKey, productId, d.id));
}

/** Can this design be picked on this line (not already used with this product elsewhere)? */
export const designAvailable = (lines: OrderLine[], exceptKey: number, productId: string, designId: string): boolean => !pairTaken(lines, exceptKey, productId, designId);

/** Changing the product clears the design: a design belongs to one product, and the customer must choose again. */
export const withProduct = (line: OrderLine, productId: string): OrderLine => ({ ...line, productId, designId: "" });

/** Why this line cannot be sent yet, in words for the customer, or null when it is fine. */
export function lineProblem(line: OrderLine, products: Product[], designs: PublicDesign[]): string | null {
  if (!line.productId) return "Choose a product";
  const product = products.find((p) => p.id === line.productId);
  if (!product) return "This product is no longer available";
  const ds = designsOf(designs, line.productId);
  if (ds.length > 0 && !line.designId) return "Choose a design";
  if (line.designId && !ds.some((d) => d.id === line.designId)) return "This design is no longer available";
  if (parseQuantity(line.quantity) === null) return `Quantity must be a whole number between 1 and ${MAX_QUANTITY}`;
  return null;
}

/**
 * The first problem across the whole form, as "Line 2: Choose a design", or null. Also refuses a repeated product + design pair.
 * `numbers` are the on-screen row numbers of the given lines (when blank rows were left out of `lines`); `numbered` forces or suppresses the "Line N:" prefix.
 */
export function formProblem(lines: OrderLine[], products: Product[], designs: PublicDesign[], opts: { numbers?: number[]; numbered?: boolean } = {}): string | null {
  const numbered = opts.numbered ?? lines.length > 1;
  const label = (i: number, text: string) => (numbered ? `Line ${opts.numbers?.[i] ?? i + 1}: ${text}` : text);
  const seen = new Set<string>();
  for (let i = 0; i < lines.length; i++) {
    const p = lineProblem(lines[i], products, designs);
    if (p) return label(i, p);
    const pair = `${lines[i].productId}|${lines[i].designId}`;
    if (seen.has(pair)) return label(i, "this product and design are already on another line; change that line's quantity instead");
    seen.add(pair);
  }
  return null;
}

const cents = (n: number) => Math.round(n * 100);

/** Unit price of a line in cents (the product's price; designs carry none), or null when no product is chosen. */
export function unitCents(line: OrderLine, products: Product[]): number | null {
  const p = products.find((x) => x.id === line.productId);
  return p ? cents(p.price) : null;
}

/** Quantity x unit price, in cents. 0 until both are valid. */
export function lineTotalCents(line: OrderLine, products: Product[]): number {
  const unit = unitCents(line, products);
  const qty = parseQuantity(line.quantity);
  return unit === null || qty === null ? 0 : unit * qty;
}

export const orderTotalCents = (lines: OrderLine[], products: Product[]): number => lines.reduce((sum, l) => sum + lineTotalCents(l, products), 0);

export const formatCents = (c: number): string => `$${(c / 100).toFixed(2)}`;

/** What is sent to submit_order_request: designId only when one is chosen. */
export function toRequestLines(lines: OrderLine[]): { productId: string; designId?: string; quantity: number }[] {
  return lines.map((l) => ({ productId: l.productId, ...(l.designId ? { designId: l.designId } : {}), quantity: parseQuantity(l.quantity) ?? 1 }));
}
