"use client";

/**
 * "Customers to collect" - an operational work list for a Marketing Officer:
 * which of the orders they can see still have money owed, oldest delivered
 * first. Not an accounting report: no business totals, no cost, no margin.
 *
 * The rows are the orders RLS returned to this user (an officer: the customers
 * currently assigned to them), unpaid or partly paid, not cancelled, and not
 * belonging to an archived customer. Amounts come from the order's own
 * amount_paid / outstanding_balance, which the database maintains from the payments.
 */
import { cn } from "@/lib/utils";
import { daysSince, money } from "@/lib/commission";
import type { Customer, Order } from "@/lib/types";

export type CollectionRow = {
  order: Order;
  customerName: string;
  total: number;
  collected: number;
  outstanding: number;
  daysOutstanding: number | null;
  delivered: boolean;
};

/**
 * Orders still owed money, oldest delivered first, then undelivered by order date.
 * Only orders of a customer in `customers` that is not archived count: callers
 * that load active customers only (the dashboard) and callers that also load
 * archived ones (the Customers page) get the same list.
 */
export function collectionRows(orders: Order[], customers: Customer[]): CollectionRow[] {
  const current = new Set(customers.filter((c) => c.status !== "archived" && !c.isArchived).map((c) => c.id));
  return orders
    .filter((o) => o.status !== "cancelled" && Boolean(o.customerId) && current.has(o.customerId as string))
    .map((order) => {
      const total = Number(order.total || 0);
      const collected = Number(order.amountPaid ?? 0);
      const outstanding = Number(order.outstandingBalance ?? Math.max(0, total - collected));
      const customer = customers.find((c) => c.id === order.customerId);
      const delivered = Boolean(order.deliveredAt) || order.status === "delivered";
      return {
        order,
        customerName: customer?.name ?? order.customer,
        total,
        collected,
        outstanding,
        delivered,
        daysOutstanding: delivered ? daysSince(order.deliveredAt ?? order.date) : null,
      };
    })
    .filter((r) => r.outstanding > 0)
    .sort((a, b) => {
      if (a.delivered !== b.delivered) return a.delivered ? -1 : 1;
      if (a.delivered) return (b.daysOutstanding ?? 0) - (a.daysOutstanding ?? 0);
      return new Date(a.order.date).getTime() - new Date(b.order.date).getTime();
    });
}

type Props = {
  rows: CollectionRow[];
  /** Shown only when the user may record a payment (create_orders or edit_orders). */
  onRecordPayment?: (orderId: string) => void;
  /** Limit the list (dashboard preview). */
  limit?: number;
};

export function CustomersToCollect({ rows, onRecordPayment, limit }: Props) {
  const shown = typeof limit === "number" ? rows.slice(0, limit) : rows;
  return (
    <div className="overflow-x-auto" data-testid="customers-to-collect">
      <table className="w-full text-left text-xs">
        <thead className="bg-slate-50 text-[9px] uppercase tracking-widest text-slate-400">
          <tr>
            <th className="px-4 py-3">Customer</th>
            <th className="px-4 py-3">Order</th>
            <th className="px-4 py-3">Order date</th>
            <th className="px-4 py-3">Delivered</th>
            <th className="px-4 py-3 text-right">Amount due</th>
            <th className="px-4 py-3 text-right">Collected</th>
            <th className="px-4 py-3 text-right">Outstanding</th>
            <th className="px-4 py-3 text-right">Days outstanding</th>
            <th className="px-4 py-3 text-center">Status</th>
            {onRecordPayment && <th className="px-4 py-3" />}
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100">
          {shown.length === 0 && (
            <tr>
              <td colSpan={onRecordPayment ? 10 : 9} className="px-4 py-10 text-center text-slate-400">Nothing to collect right now.</td>
            </tr>
          )}
          {shown.map((r) => {
            const partial = r.collected > 0;
            return (
              <tr key={r.order.id} className="hover:bg-slate-50/80" data-testid="collect-row">
                <td className="px-4 py-3 font-bold text-slate-900">{r.customerName}</td>
                <td className="px-4 py-3 font-mono">{r.order.id}</td>
                <td className="px-4 py-3 text-slate-600">{r.order.date}</td>
                <td className="px-4 py-3 text-slate-600">{r.order.deliveredAt ? new Date(r.order.deliveredAt).toLocaleDateString() : r.delivered ? "Delivered" : "Not yet delivered"}</td>
                <td className="px-4 py-3 text-right font-mono">{money(r.total)}</td>
                <td className="px-4 py-3 text-right font-mono text-brand-blue">{money(r.collected)}</td>
                <td className="px-4 py-3 text-right font-mono font-bold text-slate-900">{money(r.outstanding)}</td>
                <td className="px-4 py-3 text-right">{r.daysOutstanding === null ? "—" : `${r.daysOutstanding} d`}</td>
                <td className="px-4 py-3 text-center">
                  <span className={cn("inline-flex rounded-full px-2 py-1 text-[9px] font-bold uppercase", partial ? "bg-amber-100 text-amber-700" : "bg-red-100 text-red-700")}>
                    {partial ? "Partially paid" : "Unpaid"}
                  </span>
                </td>
                {onRecordPayment && (
                  <td className="px-4 py-3 text-right">
                    <button
                      type="button"
                      onClick={() => onRecordPayment(r.order.id)}
                      className="rounded-md border border-slate-200 bg-white px-2 py-1.5 text-[9px] font-bold uppercase tracking-wide text-slate-700 hover:bg-blue-50 hover:text-blue-700"
                    >
                      Record Payment
                    </button>
                  </td>
                )}
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
