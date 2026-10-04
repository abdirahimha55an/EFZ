/**
 * Sales by Marketing Officer: a breakdown of who generated the sales.
 *
 * There are no targets, quotas or achievement percentages in EFZ, and none are
 * implied here. Attribution is orders.marketing_officer_id (the officer on the
 * order); orders without one are shown as "Unassigned".
 */

import { UNASSIGNED_OFFICER, select, type Dataset, type SalesFilters } from "./dataset";
import type { DateRange } from "./period";
import { totalsOf } from "./sales";

export type OfficerRow = {
  officerId: string;
  name: string;
  orders: number;
  bookedCents: number;
  deliveredCents: number;
  bookedUnits: number;
  deliveredUnits: number;
  customers: number;
};

export function officerBreakdown(ds: Dataset, f: SalesFilters, range: DateRange): OfficerRow[] {
  const map = new Map<string, OfficerRow & { _customers: Set<string> }>();
  for (const s of select(ds, f, range)) {
    const id = s.order.officerId ?? UNASSIGNED_OFFICER;
    let r = map.get(id);
    if (!r) {
      r = {
        officerId: id,
        name: s.order.officerId ? s.order.officerName || "Unnamed officer" : "Unassigned",
        orders: 0, bookedCents: 0, deliveredCents: 0, bookedUnits: 0, deliveredUnits: 0, customers: 0,
        _customers: new Set(),
      };
      map.set(id, r);
    }
    const t = totalsOf([s]);
    r.orders += 1;
    r.bookedCents += t.bookedCents;
    r.deliveredCents += t.deliveredCents;
    r.bookedUnits += t.bookedUnits;
    r.deliveredUnits += t.deliveredUnits;
    if (s.order.customerId) r._customers.add(s.order.customerId);
  }
  return [...map.values()]
    .map(({ _customers, ...r }) => ({ ...r, customers: _customers.size }))
    .sort((a, b) => b.deliveredCents - a.deliveredCents || b.bookedCents - a.bookedCents || a.name.localeCompare(b.name));
}

/** Officers seen on any visible order (for the filter menu), by name. */
export function officersOnOrders(ds: Dataset): { id: string; name: string }[] {
  const m = new Map<string, string>();
  let unassigned = false;
  for (const o of ds.orders) {
    if (o.officerId) m.set(o.officerId, o.officerName || "Unnamed officer");
    else unassigned = true;
  }
  const list = [...m.entries()].map(([id, name]) => ({ id, name })).sort((a, b) => a.name.localeCompare(b.name));
  return unassigned ? [...list, { id: UNASSIGNED_OFFICER, name: "Unassigned" }] : list;
}
