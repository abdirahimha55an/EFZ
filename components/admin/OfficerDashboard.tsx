"use client";

/**
 * "My Dashboard" - the Overview page as a Marketing Officer sees it.
 *
 * Two scopes, deliberately kept apart (business rule D7):
 *   - MY PERFORMANCE / MY COMMISSIONS / ORDERS IN PROGRESS commission columns:
 *     orders whose commission is this officer's (orders.marketing_officer_id,
 *     never moved by a transfer) and the officer's own commission rows.
 *   - MY CUSTOMERS / CUSTOMER COLLECTIONS: the customers CURRENTLY assigned to
 *     the officer - exactly what RLS returns - including their earlier orders
 *     after a transfer (collecting what they owe is now this officer's job).
 *
 * Read only. Earned figures are the commission rows the database recorded;
 * the expected figure is a forecast and is labelled as such.
 */
import { useEffect, useMemo, useState } from "react";
import Link from "next/link";

import { Card, CardContent } from "@/components/ui/card";
import { CustomersToCollect, collectionRows } from "@/components/admin/CustomersToCollect";
import {
  type CommissionEvent,
  type CommissionPolicyView,
  type DeliveryWithLines,
  expectedForOrder,
  footballCounts,
  footballIdsOf,
  money,
  summarize,
} from "@/lib/commission";
import { efzToday } from "@/lib/dates";
import { activeCustomers, collectedFromMyCustomers } from "@/lib/officerMetrics";
import { cn } from "@/lib/utils";
import { getDb } from "@/lib/supabase/db";
import type { PermissionFlags } from "@/lib/permissions";
import type { AdminUser, Customer, Order, Product } from "@/lib/types";

type Props = {
  profile: AdminUser;
  perms: PermissionFlags;
  orders: Order[];
  customers: Customer[];
  products: Product[];
};

const IN_PROGRESS = ["pending", "confirmed", "processing", "partially_delivered"] as const;

function Stat({ id, title, value, note, dashed }: { id: string; title: string; value: string; note?: string; dashed?: boolean }) {
  return (
  <Card className={cn("shadow-sm", dashed ? "border-2 border-dashed border-sky-200 bg-sky-50/40 shadow-none" : "border-none")} data-testid={`officer-${id}`}>
    <CardContent className="p-4">
      <p className={cn("text-[9px] font-bold uppercase tracking-widest", dashed ? "text-sky-700" : "text-slate-400")}>{title}</p>
      <h3 className={cn("mt-1 font-mono text-xl font-bold", dashed ? "text-sky-800" : "text-slate-900")}>{value}</h3>
      {note && <p className={cn("mt-1 text-[10px]", dashed ? "font-bold text-sky-700" : "text-slate-500")}>{note}</p>}
    </CardContent>
  </Card>
  );
}

function Section({ title, children, action }: { title: string; children: React.ReactNode; action?: React.ReactNode }) {
  return (
  <section className="space-y-3">
    <div className="flex items-center justify-between">
      <h2 className="text-[11px] font-bold uppercase tracking-[0.2em] text-slate-500">{title}</h2>
      {action}
    </div>
    {children}
  </section>
  );
}

export function OfficerDashboard({ profile, perms, orders, customers, products }: Props) {
  const [events, setEvents] = useState<CommissionEvent[]>([]);
  const [policy, setPolicy] = useState<CommissionPolicyView | null>(null);
  const [deliveries, setDeliveries] = useState<DeliveryWithLines[]>([]);
  // Commission cards show "—" until the officer's own rows and the policy have loaded,
  // never a momentary $0.00.
  const [commissionLoaded, setCommissionLoaded] = useState(false);
  // "Collected by Me" comes from the database (my_collected_payments, migration 13):
  // it must include payments on orders this officer can no longer see. Null = "—".
  const [byMe, setByMe] = useState<{ total: number; thisMonth: number; payments: number } | null>(null);
  // 16: commission eligibility OFF = no commission on new deliveries / bonuses.
  const [paused, setPaused] = useState(false);

  useEffect(() => {
    let cancelled = false;
    getDb()
      .analytics.collectedByMe()
      .then((value) => { if (!cancelled) setByMe(value); })
      .catch(() => { if (!cancelled) setByMe(null); });
    return () => {
      cancelled = true;
    };
  }, [profile.id]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const db = getDb();
      try {
        const [mine, nextPolicy, nextDeliveries, eligibility] = await Promise.all([
          perms.viewCommissions ? db.commissions.mine(profile.id) : Promise.resolve([]),
          db.commissions.policy(),
          db.orders.deliveries(orders.map((o) => o.id)),
          db.commissions.eligibility().catch(() => []),
        ]);
        if (cancelled) return;
        setPaused(eligibility.some((e) => e.officer_id === profile.id && !e.eligible));
        setEvents(mine);
        setPolicy(nextPolicy);
        setDeliveries(nextDeliveries);
        setCommissionLoaded(true);
      } catch {
        // The cards below fall back to "—" rather than inventing numbers.
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [profile.id, perms.viewCommissions, orders]);

  const footballIds = useMemo(() => footballIdsOf(products), [products]);
  const today = efzToday(); // Mogadishu calendar date
  const month = today.slice(0, 7);

  // --- commission-owned orders (performance) ---
  const myOrders = orders.filter((o) => o.marketingOfficerId === profile.id && o.status !== "cancelled");
  const ballsDelivered = myOrders.reduce((s, o) => s + (footballCounts(o, footballIds)?.delivered ?? 0), 0);
  const revenue = myOrders.reduce((s, o) => s + Number(o.total || 0), 0);

  // --- current customers ---
  const myCustomers = customers.filter((c) => c.marketingOfficerId === profile.id && c.status !== "archived" && !c.isArchived);
  const newCustomers = myCustomers.filter((c) => (c.date ?? "").startsWith(month));
  // Active = an order placed within the last 90 days (lib/officerMetrics.ts).
  const active = activeCustomers(myCustomers, orders, today);

  // --- commissions ---
  const totals = summarize(events);
  const expected = paused
    ? 0
    : footballIds && policy && commissionLoaded
      ? myOrders.reduce((s, o) => s + (expectedForOrder(o, policy, footballIds)?.amount ?? 0), 0)
      : null;
  const earnedOn = (orderId: string) =>
    summarize(events.filter((e) => e.order_id === orderId)).earned;

  // --- collections (current customers' orders, as RLS returns them) ---
  const toCollect = collectionRows(orders, customers);
  // Two different questions, kept apart (lib/officerMetrics.ts):
  const fromMyCustomers = collectedFromMyCustomers(orders, myCustomers, month); // current customers, any recorder
  const outstandingToCollect = toCollect.reduce((s, r) => s + r.outstanding, 0);
  const unpaidOrders = toCollect.filter((r) => r.collected <= 0).length;
  const partialOrders = toCollect.filter((r) => r.collected > 0).length;

  // --- orders in progress ---
  const inProgress = orders
    .filter((o) => (IN_PROGRESS as readonly string[]).includes(o.status))
    .sort((a, b) => a.date.localeCompare(b.date));
  const statusCount = (s: string) => inProgress.filter((o) => o.status === s).length;

  // --- recent activity ---
  type Activity = { at: string; kind: string; text: string };
  const activity: Activity[] = [
    ...myCustomers.map((c) => ({ at: c.date, kind: "New customer", text: c.name })),
    ...orders.filter((o) => o.marketingOfficerId === profile.id).map((o) => ({ at: o.createdAt ?? o.date, kind: "New order", text: `#${o.id} · ${o.customer} · ${money(o.total)}` })),
    ...deliveries
      .filter((d) => d.source === "delivery" && d.delivered_at)
      .map((d) => {
        const o = orders.find((x) => x.id === d.order_id);
        const qty = d.lines.reduce((s, l) => s + l.quantity, 0);
        return { at: d.delivered_at as string, kind: "Delivery", text: `#${d.order_id} · ${o?.customer ?? ""} · ${qty} ball${qty === 1 ? "" : "s"}` };
      }),
    ...orders.flatMap((o) =>
      (o.payments ?? []).map((p) => ({ at: p.createdAt ?? p.paymentDate, kind: "Payment", text: `#${o.id} · ${o.customer} · ${money(p.amount)}` }))
    ),
    ...events
      .filter((e) => e.status !== "void" && (e.kind === "delivery" || e.kind === "first_order_bonus" || e.kind === "correction"))
      .map((e) => ({
        at: e.earned_at ?? e.created_at,
        kind: "Commission earned",
        text: `#${e.order_id} · ${e.kind === "first_order_bonus" ? "First-order bonus" : `${e.units} ball${e.units === 1 ? "" : "s"}`} · ${money(e.amount)}`,
      })),
  ]
    .filter((a) => a.at)
    .sort((a, b) => new Date(b.at).getTime() - new Date(a.at).getTime())
    .slice(0, 10);


  return (
    <div className="space-y-10 animate-in fade-in duration-500" data-testid="officer-dashboard">
      <div>
        <h1 className="font-heading text-2xl font-bold tracking-tight text-slate-900">My Dashboard</h1>
        <p className="mt-0.5 text-xs text-slate-500">Your customers, orders, collections and commission.</p>
      </div>

      <Section title="My performance">
        <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
          <Stat id="total-orders" title="Total Orders" value={String(myOrders.length)} note="Orders whose commission is yours" />
          <Stat id="balls-delivered" title="Balls Delivered" value={footballIds ? String(ballsDelivered) : "—"} />
          <Stat id="revenue" title="Revenue Generated" value={money(revenue)} note="Your orders, excluding cancelled" />
          <Stat id="new-customers" title="New Customers" value={String(newCustomers.length)} note="This month" />
        </div>
      </Section>

      {perms.viewCommissions && (
        <Section title="My commissions" action={<Link href="/admin/commissions" className="text-[10px] font-bold uppercase text-brand-blue">See every commission →</Link>}>
          <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
            <Stat id="earned-unpaid" title="Earned · Unpaid" value={commissionLoaded ? money(totals.unpaid) : "—"} note="Awaiting payout by management" />
            <Stat id="paid" title="Paid" value={commissionLoaded ? money(totals.paid) : "—"} note="Paid out to you" />
            <Stat id="on-hold" title="On Hold" value={commissionLoaded ? money(totals.onHold) : "—"} note="Flagged for review" />
            <Stat id="expected" title="Expected from Undelivered Balls" value={expected === null ? "—" : money(expected)} note={paused ? "PAUSED · no commission on new deliveries" : "FORECAST · not earned yet"} dashed />
          </div>
          {paused && (
            <p className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-xs text-amber-900" data-testid="commission-paused">
              Commission earning is paused: new deliveries and first-order bonuses do not earn commission for you until
              management turns it back on. Commission already recorded is unchanged.
            </p>
          )}
        </Section>
      )}

      <Section title="My customers">
        <div className="grid grid-cols-3 gap-4">
          <Stat id="total-customers" title="Total Customers" value={String(myCustomers.length)} note="Currently assigned to you" />
          <Stat id="new-customers-2" title="New Customers" value={String(newCustomers.length)} note="Registered this month" />
          <Stat id="active-customers" title="Active Customers" value={String(active.length)} note="Placed an order in the last 90 days (order date; cancelled orders excluded)" />
        </div>
      </Section>

      <Section
        title="Customer collections"
        action={perms.accessCustomerModule ? <Link href="/admin/customers" className="text-[10px] font-bold uppercase text-brand-blue">Record a payment →</Link> : undefined}
      >
        <div className="grid grid-cols-2 gap-4 md:grid-cols-3 xl:grid-cols-5">
          <Stat
            id="collected-by-me"
            title="Collected by Me"
            value={byMe ? money(byMe.total) : "—"}
            note={byMe ? `Payments you recorded yourself · this month ${money(byMe.thisMonth)}` : "Payments you recorded yourself"}
          />
          <Stat
            id="collected-from-my-customers"
            title="Collected from My Customers"
            value={money(fromMyCustomers.total)}
            note={`All payments from customers now assigned to you, whoever recorded them · this month ${money(fromMyCustomers.thisMonth)}`}
          />
          <Stat id="to-collect" title="Outstanding to Collect" value={money(outstandingToCollect)} />
          <Stat id="unpaid-orders" title="Unpaid Orders" value={String(unpaidOrders)} />
          <Stat id="partial-orders" title="Partially Paid Orders" value={String(partialOrders)} />
        </div>
        <Card className="border-none shadow-sm">
          <CardContent className="p-0">
            <CustomersToCollect rows={toCollect} limit={5} />
          </CardContent>
        </Card>
      </Section>

      <Section title="Orders in progress">
        <div className="flex flex-wrap gap-2 text-[10px] font-bold uppercase">
          {IN_PROGRESS.map((s) => (
            <span key={s} className="rounded-full bg-slate-100 px-3 py-1 text-slate-600" data-testid={`in-progress-${s}`}>
              {s.replace("_", " ")}: {statusCount(s)}
            </span>
          ))}
        </div>
        <Card className="border-none shadow-sm">
          <CardContent className="overflow-x-auto p-0">
            <table className="w-full text-left text-xs" data-testid="orders-in-progress">
              <thead className="bg-slate-50 text-[9px] uppercase tracking-widest text-slate-400">
                <tr>
                  <th className="px-4 py-3">Customer</th>
                  <th className="px-4 py-3">Order</th>
                  <th className="px-4 py-3 text-right">Amount</th>
                  <th className="px-4 py-3">Delivery status</th>
                  <th className="px-4 py-3 text-right">Balls delivered / ordered</th>
                  <th className="px-4 py-3 text-right">Commission earned</th>
                  <th className="px-4 py-3 text-right">Expected (forecast)</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-50">
                {inProgress.length === 0 && (
                  <tr><td colSpan={7} className="px-4 py-8 text-center text-slate-400">No orders in progress.</td></tr>
                )}
                {inProgress.map((o) => {
                  const counts = footballCounts(o, footballIds);
                  const mine = o.marketingOfficerId === profile.id;
                  const exp = mine && !paused ? expectedForOrder(o, policy, footballIds) : null;
                  return (
                    <tr key={o.id}>
                      <td className="px-4 py-3 font-bold">{o.customer}</td>
                      <td className="px-4 py-3 font-mono">{o.id}</td>
                      <td className="px-4 py-3 text-right font-mono">{money(o.total)}</td>
                      <td className="px-4 py-3">{o.status.replace("_", " ")}</td>
                      <td className="px-4 py-3 text-right">{counts ? `${counts.delivered} / ${counts.ordered}` : "—"}</td>
                      <td className="px-4 py-3 text-right font-mono">{mine ? (commissionLoaded ? money(earnedOn(o.id)) : "—") : <span className="text-slate-400" title="Commission on this earlier order belongs to the previous officer">other officer</span>}</td>
                      <td className="px-4 py-3 text-right font-mono text-sky-700">{exp ? money(exp.amount) : "—"}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </CardContent>
        </Card>
      </Section>

      <Section title="Recent activity">
        <Card className="border-none shadow-sm">
          <CardContent className="divide-y divide-slate-50 p-0 text-xs" data-testid="recent-activity">
            {activity.length === 0 && <p className="px-4 py-6 text-center text-slate-400">No recent activity.</p>}
            {activity.map((a, i) => (
              <div key={i} className="flex items-center justify-between px-4 py-2">
                <span><span className="mr-2 inline-flex rounded bg-slate-100 px-1.5 py-0.5 text-[9px] font-bold uppercase text-slate-600">{a.kind}</span>{a.text}</span>
                <span className="whitespace-nowrap text-[10px] text-slate-400">{new Date(a.at).toLocaleDateString()}</span>
              </div>
            ))}
          </CardContent>
        </Card>
      </Section>
    </div>
  );
}
