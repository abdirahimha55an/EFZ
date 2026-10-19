/**
 * 28: the pure rules of the Convert-to-Order dialog, kept out of the component so they can be tested (npm run test:hub).
 *
 * The database decides the price. A line is sent WITHOUT a price unless staff deliberately changed it, so convert_website_request() hands the line to
 * create_order(), which applies the customer's design agreement, else the product agreement, else the list price, as of the day of conversion. A price that is
 * sent and differs from an agreed price is a documented override: it needs priceOverrideReason (10+ characters) and is audited by create_order().
 *
 * Fail safe: when the customer's price cannot be looked up (or the answer is not usable) the line is BLOCKED. A displayed price is never sent as a fallback,
 * because a price that differs from an agreement the page could not see would silently become an override.
 */
import type { ConvertRequestInput } from "@/lib/supabase/queries";

/** What resolve_order_price() answered for a customer, product and design. */
export type PriceInfo = { source: "agreement" | "list" | "review"; price: number | null; listPrice: number | null; reason: string | null };

export type ConversionLine = {
  productId: string;
  quantity: string;
  /** The design carried from the request (empty for a line without one). */
  designId?: string;
  designName?: string;
  /** What the price box shows: the resolved price until staff type their own. Empty while unknown. */
  price: string;
  /** True once staff typed in the price box. */
  priceEdited: boolean;
  /** undefined = not asked yet; null = the lookup failed or its answer was not usable (the line is blocked until a retry succeeds). */
  info: PriceInfo | null | undefined;
};

/** The same minimum create_order() enforces on priceOverrideReason. */
export const OVERRIDE_REASON_MIN = 10;

/** Shown for a line whose price could not be looked up. */
export const PRICE_LOOKUP_FAILED = "We could not check this customer's price for this product. Nothing was assumed - press Retry.";

const cents = (n: number) => Math.round(n * 100);
const isMoney = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v) && v >= 0;

/**
 * Validates what resolve_order_price() returned. Anything that is not exactly the documented shape is "no answer" (null), never a guess:
 * an agreement or list answer must carry a usable price; a review answer carries none.
 */
export function parsePriceInfo(raw: unknown): PriceInfo | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  if (r.source !== "agreement" && r.source !== "list" && r.source !== "review") return null;
  const listPrice = r.listPrice === null || r.listPrice === undefined ? null : isMoney(r.listPrice) ? r.listPrice : undefined;
  if (listPrice === undefined) return null;
  const reason = typeof r.reason === "string" ? r.reason : null;
  if (r.source === "review") return { source: "review", price: null, listPrice, reason };
  if (!isMoney(r.price)) return null;
  return { source: r.source, price: r.price, listPrice, reason };
}

/** The price shown/charged for the line, or null when there is none yet. */
export function linePrice(l: ConversionLine): number | null {
  if (l.price.trim() === "") return null;
  const n = Number(l.price);
  return Number.isFinite(n) ? n : null;
}

/** Why the line cannot be converted right now (null = it can). */
export function lineBlock(l: ConversionLine): string | null {
  if (l.info === null) return PRICE_LOOKUP_FAILED;
  // A price waiting for confirmation is never replaced by a typed one: the path is Customer Prices.
  if (l.info?.source === "review") return `The customer's price for this product needs to be confirmed first (${l.info.reason ?? "see Customer Prices"}).`;
  return null;
}

/** Staff typed a price that differs from the one the database would apply. Only meaningful once the price is known. */
export function isPriceChanged(l: ConversionLine): boolean {
  const applied = l.info?.price;
  if (!l.priceEdited || applied == null) return false;
  const typed = linePrice(l);
  return typed !== null && cents(typed) !== cents(applied);
}

/** The line is charged exactly the agreed price (any below-cost approval was given when the agreement was verified, so no below-cost reason is asked). */
export function isAgreedPrice(l: ConversionLine): boolean {
  return l.info?.source === "agreement" && !isPriceChanged(l);
}

/** A changed price for a customer who has an agreement: needs a documented reason. */
export function isAgreementOverride(l: ConversionLine): boolean {
  return l.info?.source === "agreement" && isPriceChanged(l);
}

/** True when the order-level reason is required and not yet long enough. */
export function overrideReasonMissing(lines: ConversionLine[], reason: string): boolean {
  return lines.some(isAgreementOverride) && reason.trim().length < OVERRIDE_REASON_MIN;
}

export type OverrideRow = { productId: string; designName: string; quantity: number; agreed: number; proposed: number; perUnit: number; total: number };

/** What the confirmation box shows: each overridden line with the agreed price, the proposed price and what the difference comes to. */
export function overrideSummary(lines: ConversionLine[]): OverrideRow[] {
  return lines.filter(isAgreementOverride).map((l) => {
    const agreed = l.info?.price as number;
    const proposed = linePrice(l) as number;
    const quantity = Math.round(Number(l.quantity));
    const qty = Number.isFinite(quantity) ? quantity : 0;
    return { productId: l.productId, designName: l.designName ?? "", quantity: qty, agreed, proposed, perUnit: (cents(proposed) - cents(agreed)) / 100, total: ((cents(proposed) - cents(agreed)) * qty) / 100 };
  });
}

/** One product may appear on several lines only with different designs. */
export function lineKey(l: Pick<ConversionLine, "productId" | "designId" | "designName">): string {
  return `${l.productId}|${(l.designId ?? "").toLowerCase()}|${(l.designName ?? "").trim().toLowerCase()}`;
}

export function hasDuplicateLines(lines: ConversionLine[]): boolean {
  return new Set(lines.map(lineKey)).size !== lines.length;
}

/**
 * The line as sent to convert_website_request(). The price is included ONLY when staff deliberately changed it from a price the page could see.
 * Never a displayed price as a fallback: a line without a usable lookup is blocked (lineBlock) and is never submitted.
 */
export function toPayloadLine(l: ConversionLine): ConvertRequestInput["lines"][number] {
  const qty = Math.round(Number(l.quantity));
  const out: ConvertRequestInput["lines"][number] = { productId: l.productId, quantity: qty };
  const price = linePrice(l);
  if (price !== null && isPriceChanged(l)) out.actualUnitPrice = price;
  if (l.designId) out.designId = l.designId;
  else if (l.designName?.trim()) out.designName = l.designName.trim();
  return out;
}
