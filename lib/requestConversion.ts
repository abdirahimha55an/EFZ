/**
 * 28: the pure rules of the Convert-to-Order dialog, kept out of the component so they can be tested (npm run test:hub).
 *
 * The database decides the price. A line is sent WITHOUT a price unless staff deliberately changed it, so convert_website_request() hands the line to
 * create_order(), which applies the customer's design agreement, else the product agreement, else the list price, as of the day of conversion. A price that is
 * sent and differs from an agreed price is a documented override: it needs priceOverrideReason (10+ characters) and is audited by create_order().
 */
import type { ConvertRequestInput } from "@/lib/supabase/queries";

/** What resolve_order_price() answered for a customer, product and design. null = the answer could not be had (the call failed); undefined = not asked yet. */
export type PriceInfo = { source: "agreement" | "list" | "review"; price: number | null; listPrice: number | null; reason: string | null };

export type ConversionLine = {
  productId: string;
  quantity: string;
  /** The design carried from the request (empty for a line without one). */
  designId?: string;
  designName?: string;
  /** What the price box shows: the resolved price until staff type their own. */
  price: string;
  /** True once staff typed in the price box. */
  priceEdited: boolean;
  info: PriceInfo | null | undefined;
};

/** The same minimum create_order() enforces on priceOverrideReason. */
export const OVERRIDE_REASON_MIN = 10;

const cents = (n: number) => Math.round(n * 100);

/** The price shown/charged for the line, or null when there is none yet. */
export function linePrice(l: ConversionLine): number | null {
  if (l.price.trim() === "") return null;
  const n = Number(l.price);
  return Number.isFinite(n) ? n : null;
}

/** Why the line cannot be converted at all (null = it can). A price waiting for confirmation is never replaced by a typed one: the path is Customer Prices. */
export function lineBlock(l: ConversionLine): string | null {
  if (l.info?.source === "review") return `The customer's price for this product needs to be confirmed first (${l.info.reason ?? "see Customer Prices"}).`;
  return null;
}

/** Staff typed a price that differs from the one the database would apply. */
export function isPriceChanged(l: ConversionLine): boolean {
  if (!l.priceEdited) return false;
  const typed = linePrice(l);
  if (typed === null) return false;
  if (l.info && l.info.price !== null) return cents(typed) !== cents(l.info.price);
  return true;
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

/** One product may appear on several lines only with different designs. */
export function lineKey(l: Pick<ConversionLine, "productId" | "designId" | "designName">): string {
  return `${l.productId}|${(l.designId ?? "").toLowerCase()}|${(l.designName ?? "").trim().toLowerCase()}`;
}

export function hasDuplicateLines(lines: ConversionLine[]): boolean {
  return new Set(lines.map(lineKey)).size !== lines.length;
}

/**
 * The line as sent to convert_website_request(). The price is included only when it must be: a typed price that differs from the resolved one, or when the
 * resolved price could not be fetched at all (info === null: the behaviour before migration 28, where the price shown is sent).
 */
export function toPayloadLine(l: ConversionLine): ConvertRequestInput["lines"][number] {
  const qty = Math.round(Number(l.quantity));
  const out: ConvertRequestInput["lines"][number] = { productId: l.productId, quantity: qty };
  const price = linePrice(l);
  if (price !== null && (l.info === null || isPriceChanged(l))) out.actualUnitPrice = price;
  if (l.designId) out.designId = l.designId;
  else if (l.designName?.trim()) out.designName = l.designName.trim();
  return out;
}
