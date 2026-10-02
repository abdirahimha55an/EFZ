"use client";

/**
 * Commission on one order, from the commission rows the database recorded.
 *
 * Read only. Every earned amount is a stored commission row; the per-product
 * lines of a delivery are shown only when they reproduce that stored row
 * exactly. The forecast for balls not yet delivered is shown apart and is
 * always labelled EXPECTED.
 *
 * RLS decides what comes back: an officer gets only their own rows. On an order
 * whose commission belongs to another officer (a customer transferred to them)
 * they therefore see no amounts - only who the commission belongs to.
 */
import { useEffect, useState } from "react";
import { Loader2 } from "lucide-react";

import {
  type CommissionEvent,
  type CommissionPolicyView,
  type DeliveryWithLines,
  STATUS_HINT,
  deliveryBreakdown,
  displayStatus,
  eventDate,
  eventDescription,
  expectedForOrder,
  footballCounts,
  kindLabel,
  money,
  statusClass,
  summarize,
} from "@/lib/commission";
import { cn } from "@/lib/utils";
import { describeDbError, getDb } from "@/lib/supabase/db";
import type { AdminUser, Order } from "@/lib/types";

type Props = {
  order: Order;
  viewer: AdminUser;
  policy: CommissionPolicyView | null;
  footballIds: Set<string> | null;
};

function StatusChip({ row }: { row: CommissionEvent }) {
  const s = displayStatus(row);
  return (
    <span title={STATUS_HINT[s]} className={cn("inline-flex rounded-full border px-2 py-0.5 text-[9px] font-bold uppercase", statusClass(s))}>
      {s}
    </span>
  );
}

const fmtDate = (iso: string | null | undefined) =>
  iso ? new Date(iso).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }) : "—";

export function OrderCommissionPanel({ order, viewer, policy, footballIds }: Props) {
  const [rows, setRows] = useState<CommissionEvent[] | null>(null);
  const [deliveries, setDeliveries] = useState<DeliveryWithLines[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const db = getDb();
        const [nextRows, nextDeliveries] = await Promise.all([
          db.commissions.forOrder(order.id),
          db.orders.deliveries([order.id]),
        ]);
        if (cancelled) return;
        setRows(nextRows);
        setDeliveries(nextDeliveries);
      } catch (e) {
        if (!cancelled) setError(describeDbError(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [order.id]);

  if (error) return <p className="text-xs text-red-600">Could not load the commission: {error}</p>;
  if (!rows) {
    return (
      <div className="flex items-center gap-2 py-6 text-xs text-slate-400">
        <Loader2 className="h-4 w-4 animate-spin" /> Loading commission…
      </div>
    );
  }

  const isOwnOrder = order.marketingOfficerId === viewer.id;
  const isOfficer = viewer.role === "Marketing Officer";
  const counts = footballCounts(order, footballIds);
  const expected = isOwnOrder || !isOfficer ? expectedForOrder(order, policy, footballIds) : null;
  const ownerName = order.marketingOfficerName ?? "another officer";
  const totals = summarize(rows);
  const deliveryById = new Map(deliveries.map((d) => [d.id, d]));
  const perBall = order.commissionModel === "per_ball_v1";

  const deliveryRows = rows.filter((r) => r.kind === "delivery");
  const correctionRows = rows.filter((r) => r.kind === "correction");
  const bonusRows = rows.filter((r) => r.kind === "first_order_bonus");
  const legacyRows = rows.filter((r) => !r.kind || r.kind === "legacy");

  return (
    <div className="space-y-4 text-xs" data-testid="order-commission-panel">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <p className="font-bold text-slate-900">Order #{order.id}</p>
          <p className="text-slate-500">Customer: {order.customer}</p>
        </div>
        <div className="text-right">
          <p className="text-[10px] font-bold uppercase tracking-widest text-slate-400">Commission model</p>
          <p className="font-bold text-slate-700">
            {perBall
              ? `Per delivered Football (${money(policy?.perBallRate ?? rows.find((r) => r.per_ball_rate)?.per_ball_rate)})`
              : order.commissionModel === "legacy_percent"
                ? "Legacy (percentage)"
                : "Decided when the order is confirmed"}
          </p>
          <p className="text-[10px] text-slate-500">Commission owner: {order.marketingOfficerName ?? "—"}</p>
        </div>
      </div>

      {counts && (
        <p className="rounded-lg bg-slate-50 px-3 py-2 font-bold text-slate-700" data-testid="delivered-of-ordered">
          Delivered: {counts.delivered} / {counts.ordered} Football balls
        </p>
      )}

      {rows.length === 0 && (
        <p className="rounded-lg border border-dashed border-slate-200 px-3 py-3 text-slate-500" data-testid="no-commission-note">
          {isOfficer && !isOwnOrder
            ? `Commission on this order belongs to ${ownerName}. It was earned on the customer's earlier orders and stays with that officer.`
            : "No commission has been recorded on this order yet."}
        </p>
      )}

      {deliveryRows.length > 0 && (
        <div className="space-y-2">
          <p className="text-[10px] font-bold uppercase tracking-widest text-slate-400">Earned on deliveries</p>
          {deliveryRows.map((row) => {
            const delivery = row.delivery_id ? deliveryById.get(row.delivery_id) : undefined;
            const breakdown = deliveryBreakdown(row, delivery, order, footballIds);
            return (
              <div key={row.id} className="rounded-lg border border-slate-100 p-3" data-testid="delivery-commission">
                <div className="mb-1 flex items-center justify-between">
                  <span className="text-slate-500">Delivered {fmtDate(delivery?.delivered_at ?? eventDate(row))}</span>
                  <StatusChip row={row} />
                </div>
                {breakdown.consistent ? (
                  breakdown.lines.map((line, i) => (
                    <div key={i} className="flex justify-between">
                      <span>
                        {line.productName}: {line.quantity} delivered × {money(line.rate)}
                      </span>
                      <span className="font-mono">{money(line.amount)}</span>
                    </div>
                  ))
                ) : (
                  <div className="flex justify-between">
                    <span>{eventDescription(row)}</span>
                    <span className="font-mono">{money(row.amount)}</span>
                  </div>
                )}
                {breakdown.consistent && breakdown.lines.length > 1 && (
                  <div className="mt-1 flex justify-between border-t border-slate-100 pt-1 font-bold">
                    <span>This delivery ({row.units} × {money(row.per_ball_rate)})</span>
                    <span className="font-mono">{money(row.amount)}</span>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}

      {correctionRows.map((row) => (
        <div key={row.id} className="flex items-center justify-between rounded-lg border border-slate-100 p-3" data-testid="correction-commission">
          <span>{eventDescription(row)} <span className="text-slate-400">({fmtDate(eventDate(row))})</span></span>
          <span className="flex items-center gap-2"><span className="font-mono">{money(row.amount)}</span><StatusChip row={row} /></span>
        </div>
      ))}

      {bonusRows.map((row) => (
        <div key={row.id} className="flex items-center justify-between rounded-lg border border-violet-100 bg-violet-50/50 p-3" data-testid="bonus-commission">
          <span className="font-bold text-violet-800">First-order bonus <span className="font-normal text-violet-600">(earned {fmtDate(eventDate(row))})</span></span>
          <span className="flex items-center gap-2"><span className="font-mono font-bold">{money(row.amount)}</span><StatusChip row={row} /></span>
        </div>
      ))}

      {legacyRows.map((row) => (
        <div key={row.id} className="flex items-center justify-between rounded-lg border border-slate-100 p-3" data-testid="legacy-commission">
          <span>{kindLabel(row)}: {eventDescription(row)}</span>
          <span className="flex items-center gap-2"><span className="font-mono">{money(row.amount)}</span><StatusChip row={row} /></span>
        </div>
      ))}

      {rows.length > 0 && (
        <div className="grid grid-cols-2 gap-2 rounded-lg bg-slate-900 p-3 text-white sm:grid-cols-4" data-testid="order-commission-totals">
          <div><p className="text-[9px] uppercase opacity-60">Total earned</p><p className="font-mono text-sm font-bold">{money(totals.earned)}</p></div>
          <div><p className="text-[9px] uppercase opacity-60">Unpaid</p><p className="font-mono text-sm font-bold">{money(totals.unpaid)}</p></div>
          <div><p className="text-[9px] uppercase opacity-60">On hold</p><p className="font-mono text-sm font-bold">{money(totals.onHold)}</p></div>
          <div><p className="text-[9px] uppercase opacity-60">Paid</p><p className="font-mono text-sm font-bold">{money(totals.paid)}</p></div>
        </div>
      )}

      {expected && expected.balls > 0 && (
        <div className="rounded-lg border-2 border-dashed border-sky-200 bg-sky-50/50 p-3" data-testid="expected-commission">
          <div className="flex justify-between font-bold text-sky-800">
            <span>EXPECTED — not earned yet</span>
            <span className="font-mono">{money(expected.amount)}</span>
          </div>
          <p className="mt-1 text-[10px] text-sky-700">
            Forecast for the {expected.balls} Football ball{expected.balls === 1 ? "" : "s"} still to deliver at {money(policy?.perBallRate)} each.
            It is earned only when the balls are delivered. A first-order bonus is not forecast.
          </p>
        </div>
      )}
    </div>
  );
}
