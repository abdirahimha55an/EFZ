/**
 * The status menu of an order: what a signed-in user may pick, and which picks are Super Admin overrides. Pure, so it is tested (npm run test:hub); the Orders page
 * only renders it. The database (update_order_status) still decides: this mirrors its rules so the page offers what the database will accept.
 *   - A normal user sees the CURRENT status plus the valid next steps for it (ORDER_STATUS_TRANSITIONS), none of them labelled override.
 *   - Cancelling an order with payments or paid commission is a Super Admin action, so it is not offered to others.
 *   - Once balls are delivered the status follows the deliveries: only "deliver the rest" remains.
 *   - A Super Admin (canOverride) is also offered every other status; each of those is an OVERRIDE (needs a written reason, audited by the database).
 */
import { ORDER_STATUS_TRANSITIONS, SELECTABLE_ORDER_STATUSES, type OrderStatus } from "./types";

export type MenuOption = { status: OrderStatus; current: boolean; override: boolean };
export type MenuInput = { status: OrderStatus; deliveredBalls: number; canEdit: boolean; canOverride: boolean; financiallyLocked: boolean };

export function statusMenu(o: MenuInput): MenuOption[] {
  const normal = ORDER_STATUS_TRANSITIONS[o.status] ?? [];
  const opt = (status: OrderStatus): MenuOption => ({ status, current: status === o.status, override: status !== o.status && !normal.includes(status) });
  if (!o.canEdit) return [opt(o.status)];
  if (o.deliveredBalls > 0) return o.status === "delivered" ? [opt(o.status)] : [opt(o.status), opt("delivered")];
  return SELECTABLE_ORDER_STATUSES.filter((s) => {
    if (s === o.status) return true;
    if (o.canOverride) return true;
    if (!normal.includes(s)) return false;
    return !(s === "cancelled" && o.financiallyLocked);
  }).map(opt);
}
