"use client";

/**
 * My Commissions - the signed-in officer's own commission events, exactly as
 * the database recorded them, plus a separate list of EXPECTED (forecast)
 * commission on balls not yet delivered.
 *
 * Read only. Gated by view_commissions (the sidebar link and the layout's
 * access check). The query asks only for the caller's own rows; RLS
 * (commissions_select) would refuse anyone else's anyway.
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { AlertCircle, Loader2 } from "lucide-react";

import { Card, CardContent } from "@/components/ui/card";
import {
  type CommissionEvent,
  type CommissionPolicyView,
  STATUS_HINT,
  displayStatus,
  eventDate,
  eventDescription,
  expectedForOrder,
  footballIdsOf,
  kindLabel,
  money,
  statusClass,
  summarize,
} from "@/lib/commission";
import { cn } from "@/lib/utils";
import { describeDbError, getDb } from "@/lib/supabase/db";
import type { AdminUser, Order } from "@/lib/types";

type TypeFilter = "all" | "delivery" | "first_order_bonus" | "correction" | "legacy";
const STATUSES = ["all", "Pending", "Approved", "On hold", "Paid", "Void"] as const;

export default function MyCommissionsPage() {
  const [profile, setProfile] = useState<AdminUser | null>(null);
  const [rows, setRows] = useState<CommissionEvent[]>([]);
  const [orders, setOrders] = useState<Order[]>([]);
  const [policy, setPolicy] = useState<CommissionPolicyView | null>(null);
  const [footballIds, setFootballIds] = useState<Set<string> | null>(null);
  // 16: OFF = no commission on future deliveries / bonuses (recorded history unchanged).
  const [paused, setPaused] = useState<{ since: string | null } | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [typeFilter, setTypeFilter] = useState<TypeFilter>("all");
  const [statusFilter, setStatusFilter] = useState<(typeof STATUSES)[number]>("all");

  const load = useCallback(async () => {
    const db = getDb();
    const me = await db.auth.getProfile();
    setProfile(me);
    if (!me) return;
    const [mine, nextOrders, nextPolicy, eligibility] = await Promise.all([
      db.commissions.mine(me.id), db.orders.list(), db.commissions.policy(), db.commissions.eligibility(),
    ]);
    setRows(mine);
    setOrders(nextOrders);
    setPolicy(nextPolicy);
    const own = eligibility.find((e) => e.officer_id === me.id);
    setPaused(own && !own.eligible ? { since: own.since } : null);
    // Product categories decide which balls earn per-ball commission. If this
    // user may not read the catalogue, the forecast is simply not shown.
    try {
      setFootballIds(footballIdsOf(await db.products.list()));
    } catch {
      setFootballIds(null);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        setLoading(true);
        await load();
        if (!cancelled) setError(null);
      } catch (e) {
        if (!cancelled) setError(describeDbError(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [load]);

  const totals = useMemo(() => summarize(rows), [rows]);
  const expectedOrders = useMemo(
    () =>
      profile && !paused
        ? orders
            .filter((o) => o.marketingOfficerId === profile.id)
            .map((o) => ({ order: o, expected: expectedForOrder(o, policy, footballIds) }))
            .filter((x): x is { order: Order; expected: { balls: number; amount: number } } => Boolean(x.expected && x.expected.balls > 0))
        : [],
    [orders, policy, footballIds, profile, paused]
  );
  const expectedTotal = expectedOrders.reduce((s, x) => s + x.expected.amount, 0);

  const visibleRows = rows.filter(
    (r) =>
      (typeFilter === "all" || (r.kind ?? "legacy") === typeFilter) &&
      (statusFilter === "all" || displayStatus(r) === statusFilter)
  );

  if (loading) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-32 text-slate-400">
        <Loader2 className="h-6 w-6 animate-spin text-brand-blue" />
        <p className="text-xs font-medium">Loading your commissions…</p>
      </div>
    );
  }
  if (error || !profile) {
    return (
      <Card className="border-none shadow-sm">
        <CardContent className="flex flex-col items-center gap-3 py-16 text-center">
          <AlertCircle className="h-8 w-8 text-red-500" />
          <p className="text-xs text-slate-500">{error ?? "Your account is not linked to a staff profile."}</p>
        </CardContent>
      </Card>
    );
  }

  const cards = [
    { id: "earned", title: "Lifetime Earned", value: totals.earned, note: "All recorded commission (unpaid, on hold and paid)", cls: "bg-brand-blue text-white" },
    { id: "unpaid", title: "Commission Unpaid", value: totals.unpaid, note: totals.onHold > 0 ? `Plus ${money(totals.onHold)} on hold for review` : "Earned, waiting for payout by management", cls: "bg-white" },
    { id: "paid", title: "Commission Paid", value: totals.paid, note: "Already paid out to you", cls: "bg-white" },
  ];

  return (
    <div className="space-y-8 animate-in fade-in duration-500">
      <div>
        <h1 className="font-heading text-2xl font-bold tracking-tight text-slate-900">My Commissions</h1>
        <p className="mt-0.5 text-xs text-slate-500">
          Every commission recorded for you, where it came from, and whether it has been paid. Payouts are made by management.
        </p>
      </div>

      {paused && (
        <div className="rounded-xl border border-amber-200 bg-amber-50 p-4 text-xs text-amber-900" data-testid="commission-paused">
          <p className="font-bold">Commission earning is paused{paused.since ? ` since ${new Date(paused.since).toLocaleDateString()}` : ""}.</p>
          <p className="mt-0.5">
            New deliveries and first-order bonuses do not earn commission for you until management turns it back on.
            Commission already recorded below is unchanged and is still paid out as usual.
          </p>
        </div>
      )}

      <div className="grid grid-cols-1 gap-4 md:grid-cols-4">
        {cards.map((c) => (
          <Card key={c.id} className={cn("border-none shadow-sm", c.cls)} data-testid={`card-${c.id}`}>
            <CardContent className="p-4">
              <p className="text-[9px] font-bold uppercase tracking-widest opacity-70">{c.title}</p>
              <h3 className="mt-0.5 font-mono text-2xl font-bold">{money(c.value)}</h3>
              <p className="mt-1.5 text-[10px] opacity-70">{c.note}</p>
            </CardContent>
          </Card>
        ))}
        <Card className="border-2 border-dashed border-sky-200 bg-sky-50/40 shadow-none" data-testid="card-expected">
          <CardContent className="p-4">
            <p className="text-[9px] font-bold uppercase tracking-widest text-sky-700">Expected from Undelivered Balls</p>
            <h3 className="mt-0.5 font-mono text-2xl font-bold text-sky-800">{paused ? money(0) : footballIds ? money(expectedTotal) : "—"}</h3>
            <p className="mt-1.5 text-[10px] font-bold text-sky-700">{paused ? "PAUSED · no commission on new deliveries" : "FORECAST · not earned yet"}</p>
          </CardContent>
        </Card>
      </div>

      <Card className="border-none shadow-sm">
        <CardContent className="p-0">
          <div className="flex flex-wrap items-center justify-between gap-3 border-b border-slate-100 p-4">
            <h2 className="text-sm font-bold text-slate-900">Commission events</h2>
            <div className="flex gap-2 text-xs">
              <select aria-label="Commission type" value={typeFilter} onChange={(e) => setTypeFilter(e.target.value as TypeFilter)} className="rounded-md border border-slate-200 px-2 py-1">
                <option value="all">All types</option>
                <option value="delivery">Delivery</option>
                <option value="first_order_bonus">First-order bonus</option>
                <option value="correction">Correction</option>
                <option value="legacy">Legacy commission</option>
              </select>
              <select aria-label="Commission status" value={statusFilter} onChange={(e) => setStatusFilter(e.target.value as (typeof STATUSES)[number])} className="rounded-md border border-slate-200 px-2 py-1">
                {STATUSES.map((s) => <option key={s} value={s}>{s === "all" ? "All statuses" : s}</option>)}
              </select>
            </div>
          </div>
          <div className="overflow-x-auto">
            <table className="w-full text-left text-xs" data-testid="commission-ledger">
              <thead className="bg-slate-50 text-[9px] font-bold uppercase tracking-widest text-slate-400">
                <tr>
                  <th className="px-4 py-3">Date</th>
                  <th className="px-4 py-3">Order</th>
                  <th className="px-4 py-3">Customer</th>
                  <th className="px-4 py-3">Type</th>
                  <th className="px-4 py-3">Description</th>
                  <th className="px-4 py-3 text-right">Delivered qty</th>
                  <th className="px-4 py-3 text-right">Rate</th>
                  <th className="px-4 py-3 text-right">Amount</th>
                  <th className="px-4 py-3">Status</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-50">
                {visibleRows.length === 0 && (
                  <tr><td colSpan={9} className="px-4 py-10 text-center text-slate-400">No commission events.</td></tr>
                )}
                {visibleRows.map((r) => {
                  const s = displayStatus(r);
                  const perBall = r.kind === "delivery" || r.kind === "correction";
                  return (
                    <tr key={r.id} data-testid="ledger-row" data-kind={r.kind ?? "legacy"}>
                      <td className="whitespace-nowrap px-4 py-3">{new Date(eventDate(r)).toLocaleDateString()}</td>
                      <td className="px-4 py-3 font-mono">{r.order_id}</td>
                      <td className="px-4 py-3">{r.orders?.customer_name ?? <span className="text-slate-400" title="This customer has since been transferred to another officer. The commission stays yours.">Customer transferred</span>}</td>
                      <td className="px-4 py-3 font-bold">{kindLabel(r)}</td>
                      <td className="px-4 py-3">{eventDescription(r)}</td>
                      <td className="px-4 py-3 text-right">{perBall ? r.units : "—"}</td>
                      <td className="px-4 py-3 text-right">{perBall ? money(r.per_ball_rate) : r.kind === "first_order_bonus" ? "—" : `${Number(r.rate)}%`}</td>
                      <td className="px-4 py-3 text-right font-mono font-bold">{money(r.amount)}</td>
                      <td className="px-4 py-3">
                        <span title={STATUS_HINT[s]} className={cn("inline-flex rounded-full border px-2 py-0.5 text-[9px] font-bold uppercase", statusClass(s))}>{s}</span>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </CardContent>
      </Card>

      <Card className="border-2 border-dashed border-sky-200 bg-sky-50/30 shadow-none">
        <CardContent className="p-0">
          <div className="border-b border-sky-100 p-4">
            <h2 className="text-sm font-bold text-sky-900">Expected — not earned yet</h2>
            <p className="text-[10px] text-sky-700">
              Forecast for Football balls still to deliver on your orders, at {money(policy?.perBallRate)} each. Status: <b>Expected</b>. It becomes earned commission only when the balls are delivered.
            </p>
          </div>
          <table className="w-full text-left text-xs" data-testid="expected-ledger">
            <thead className="text-[9px] font-bold uppercase tracking-widest text-sky-700/70">
              <tr><th className="px-4 py-2">Order</th><th className="px-4 py-2">Customer</th><th className="px-4 py-2">Order status</th><th className="px-4 py-2 text-right">Balls to deliver</th><th className="px-4 py-2 text-right">Expected</th><th className="px-4 py-2">Status</th></tr>
            </thead>
            <tbody>
              {expectedOrders.length === 0 && (<tr><td colSpan={6} className="px-4 py-6 text-center text-sky-700/60">{footballIds ? "Nothing expected right now." : "Not available (product categories are not visible to you)."}</td></tr>)}
              {expectedOrders.map(({ order, expected }) => (
                <tr key={order.id} data-testid="expected-row">
                  <td className="px-4 py-2 font-mono">{order.id}</td>
                  <td className="px-4 py-2">{order.customer}</td>
                  <td className="px-4 py-2">{order.status.replace("_", " ")}</td>
                  <td className="px-4 py-2 text-right">{expected.balls}</td>
                  <td className="px-4 py-2 text-right font-mono">{money(expected.amount)}</td>
                  <td className="px-4 py-2"><span className="inline-flex rounded-full border border-sky-200 bg-white px-2 py-0.5 text-[9px] font-bold uppercase text-sky-700">Expected</span></td>
                </tr>
              ))}
            </tbody>
          </table>
        </CardContent>
      </Card>
    </div>
  );
}
